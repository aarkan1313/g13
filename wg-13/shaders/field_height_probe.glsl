#[compute]
#version 450

// WG13 field producer — THE WORLD MATH, source of truth (00_ARCHITECTURE §2.1).
//
// Fills one page of surface data from the page's world-space origin + seed.
// Sampled in ABSOLUTE WORLD COORDINATES (00 §5): cell (x,z) maps to world
// (origin + cell*spacing), never page-local — that is what makes adjacent pages
// seamless. This shader knows nothing about rings, pools, or rendering.
//
// M1.2 produced height only (value-noise fBM). M2.1 ADDS climate — temperature
// and moisture — produced in the SAME dispatch (one source of truth, 00 §2.1):
// the page now carries 3 floats per cell, interleaved [height, temp, moisture].
// Climate is Earth-like and deterministic (M2_DESIGN): temperature ~ a smooth
// latitude gradient (world-Z) minus altitude plus low-frequency noise; moisture
// ~ independent low-frequency noise. Both in world coords, so adjacent pages and
// every session agree to the bit. Mountains/biomes (M2.2+) read these values.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Output: PAGE_RES * PAGE_RES cells, 6 floats per cell, interleaved row-major:
//   field[(z*PAGE_RES + x)*6 + 0] = height (world Y, what M1 produced)
//   field[(z*PAGE_RES + x)*6 + 1] = temperature  (normalized ~[0,1], M2.1)
//   field[(z*PAGE_RES + x)*6 + 2] = moisture     (normalized ~[0,1], M2.1)
//   field[(z*PAGE_RES + x)*6 + 3] = biome id      (float-encoded int, M2.2)
//   field[(z*PAGE_RES + x)*6 + 4] = normal_x  (analytic gradient -(hr-hl), M2.4)
//   field[(z*PAGE_RES + x)*6 + 5] = normal_z  (analytic gradient -(hu-hd), M2.4)
// Rust deinterleaves channel 0 to keep the M1.7 height-array/R32F-texture
// contract intact (collision still reads height-only), packs temp+moisture into
// one RG32F texture, the biome id into an R32F texture, and the normal gradient
// (channels 4-5) into an RG32F texture for the display shader (seam-free normals).
// OUTPUT — selected by RENDER_MODE (M2.6). The Rust RENDER producer prepends
// `#define RENDER_MODE` so the SAME field math (below) writes to GPU storage
// IMAGES sampled directly by the display shader (GPU-resident, no readback). The
// buffer path (no define) is the original M1.7 collision/oracle output, byte-
// identical. One file, one copy of the world math (00 §2.1 source of truth).
#ifdef RENDER_MODE
// binding 0 = height (R32F), 3 = climate (RG32F: temp,moist), 4 = biome (R32F),
// 5 = normal (RG32F: nx,nz). Storage images written via imageStore.
layout(set = 0, binding = 0, r32f)   restrict writeonly uniform image2D out_height;
layout(set = 0, binding = 3, rg32f)  restrict writeonly uniform image2D out_climate;
layout(set = 0, binding = 4, r32f)   restrict writeonly uniform image2D out_biome;
layout(set = 0, binding = 5, rg32f)  restrict writeonly uniform image2D out_normal;
#else
layout(set = 0, binding = 0, std430) restrict writeonly buffer FieldBuffer {
    float field[];
};
#endif

// M2.2 biome table: nearest-centroid Whittaker classifier. Flat array of
// `biome_count` centroids, 4 floats each [temp_c, moist_c, alt_c, _pad] (vec4
// stride keeps std430 happy). DATA pushed from Rust (00 §6) — adding a biome is
// a row here, never a code branch. The field outputs only the id; the display
// shader owns the debug color table.
layout(set = 0, binding = 2, std430) restrict readonly buffer BiomeTable {
    vec4 biome_centroid[];   // .xyz = (temp_c, moist_c, alt_c), .w unused
};

// Params pushed from Rust. Kept as a UBO-style block for clarity; bound as a
// small storage/uniform buffer.
layout(set = 0, binding = 1, std430) restrict readonly buffer Params {
    float origin_x;   // world X of cell (0,0)
    float origin_z;   // world Z of cell (0,0)
    float spacing;    // world units between adjacent cells
    float seed;       // world seed (passed as float; integer seed hashed below via uint cast)
    uint  page_res;   // cells per side
    uint  octaves;    // fBM octaves
    float base_freq;  // base frequency (1/world-units)
    float amplitude;  // base amplitude (world height units)
    // --- M2.1 climate params (world-space, low-freq, deterministic) ---
    float climate_lat_scale;   // world-Z units over half a pole->equator swing (latitude band size)
    float climate_temp_freq;   // low frequency of the temperature wobble noise (1/world-units)
    float climate_temp_noise;  // amplitude of that wobble in normalized temp units (0..~0.3)
    float climate_lapse;       // temperature drop per amplitude unit of altitude (altitude coupling)
    float climate_moist_freq;  // low frequency of the moisture noise (1/world-units)
    // --- M2.2 biome classifier params ---
    uint  biome_count;         // number of centroids in BiomeTable
    float biome_w_temp;        // axis weight: temperature
    float biome_w_moist;       // axis weight: moisture
    float biome_w_alt;         // axis weight: altitude (>1 so elevation dominates)
    // Macro-altitude frequency: the biome altitude axis is a SEPARATE continental
    // low-frequency landform (macro_altitude), sampled at this freq (~1/tens-of-km,
    // like the climate noises) so biomes stay contiguous at every LOD instead of
    // inheriting the detailed height's much-higher frequency (which fragments them).
    float biome_alt_freq;      // 1/world-units; low (continental landmass scale)
    float _biome_pad0;         // pad block to 20 floats (80 bytes)
    float _biome_pad1;
};

// --- deterministic hash-based value noise (no textures, no state) ---------

uint hash_u(uint x) {
    // integer hash (Wang-style), deterministic on any GPU.
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    x ^= x >> 16;
    return x;
}

// hash a 2D integer lattice point + seed -> float in [0,1)
float hash2(ivec2 p, uint seed) {
    uint h = hash_u(uint(p.x) * 0x9e3779b9u ^ hash_u(uint(p.y) * 0x85ebca6bu ^ hash_u(seed)));
    return float(h) * (1.0 / 4294967296.0);
}

// smooth interpolation
float fade(float t) { return t * t * (3.0 - 2.0 * t); }

// value noise at world position p, given seed
float value_noise(vec2 p, uint seed) {
    ivec2 i = ivec2(floor(p));
    vec2 f = fract(p);
    float a = hash2(i + ivec2(0, 0), seed);
    float b = hash2(i + ivec2(1, 0), seed);
    float c = hash2(i + ivec2(0, 1), seed);
    float d = hash2(i + ivec2(1, 1), seed);
    vec2 u = vec2(fade(f.x), fade(f.y));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// --- M2.3 composition machine: shared terrain primitives --------------------
// Layered composition: relief is PLACED by a low-frequency UPLIFT field (where
// terrain stands up into hills/ranges vs stays flat lowland), carrying ridge
// texture, with inter-range basins carved down. This is what a global octave-sum
// cannot do (no "a range stands HERE") -> it makes uniform texture. World-space,
// deterministic (00 §5). Character constants are hand-set here; DEM-tuned in M2.4.

// Smooth fBM normalized to ~[0,1] (rolling undulation / continental base).
float value_fbm(vec2 p, uint seed, uint oct, float lacunarity, float gain) {
    float sum = 0.0, amp = 1.0, norm = 0.0, freq = 1.0;
    for (uint o = 0u; o < oct; o++) {
        sum  += amp * value_noise(p * freq, seed + o * 0x68bc21ebu);
        norm += amp; amp *= gain; freq *= lacunarity;
    }
    return sum / max(norm, 1e-6);
}

// Ridged fBM: ridgelines via 1-|2n-1|, crest ROUNDED (smoothstep) so ridges have
// body (not pinched tent-poles), with prev-octave weighting so detail rides the
// ridges. Returns ~[0,1].
float ridged_fbm(vec2 p, uint seed, uint oct, float lacunarity, float gain) {
    float sum = 0.0, amp = 0.5, norm = 0.0, freq = 1.0, prev = 1.0;
    for (uint o = 0u; o < oct; o++) {
        float n = value_noise(p * freq, seed + o * 0x9e3779b9u);
        float r = 1.0 - abs(2.0 * n - 1.0);
        r = smoothstep(0.0, 1.0, r);    // round the crest -> ridgelines with body
        r *= prev; prev = clamp(r, 0.0, 1.0);
        sum  += amp * r; norm += amp; amp *= gain; freq *= lacunarity;
    }
    return sum / max(norm, 1e-6);
}

// Domain warp: bend coords by low-freq noise so landforms are organic, not grid.
vec2 domain_warp(vec2 p, uint seed, float amount, float freq) {
    float wx = value_noise(p * freq, seed ^ 0x57415250u) - 0.5;
    float wz = value_noise(p * freq + vec2(31.4, 17.0), seed ^ 0x70726177u) - 0.5;
    return p + amount * 2.0 * vec2(wx, wz);
}

// Uplift field: a blurred LOW-frequency mask in [0,1] — WHERE terrain stands up
// (ranges/uplands) vs stays low (lowlands). Two low octaves (big regions + sub-
// regions). smoothstep with a window so MOST of the world is lowland (real worlds
// are mostly flat) and uplift rises in bands. This is the STRUCTURE PLACER.
float uplift_field(vec2 p, uint seed, float freq, float lo, float hi) {
    float a0 = value_noise(p * freq, seed ^ 0x55504c54u);        // "UPLT"
    float a1 = value_noise(p * freq * 2.03, seed ^ 0x73756272u); // "subr"
    float u = clamp(a0 * 0.7 + a1 * 0.3, 0.0, 1.0);
    return smoothstep(lo, hi, u);
}

// Valley carve: press DOWN inter-range lowlands. Where uplift is low, subtract up
// to depth; on a range (uplift high) subtract nothing. (1-uplift)^2 keeps range
// flanks from being over-carved.
float valley_carve(float uplift, float depth) {
    float v = 1.0 - uplift;
    return depth * v * v;
}

// ============================================================================
// M2.5b PROBE — REGIONAL-ARCHETYPE terrain (throwaway, judged by vista capture).
// The world is a JOURNEY through distinct regions, each with its own landform
// character (plains / forest hills / alpine range / swamp / mesa / highlands),
// plus rare one-off landmark peaks. Region character is chosen from MACRO climate
// (macro_altitude + macro temp/moisture) -> NOT from detailed height, so no cycle.
// ============================================================================

float macro_altitude(vec2 world_xz, uint seed);   // forward decl (defined below)

// Macro climate from MACRO altitude (smooth, continental) -> safe to drive terrain.
vec2 macro_climate(vec2 world_xz, uint seed, float macro_alt) {
    uint temp_seed  = hash_u(seed ^ 0x54454d50u);
    uint moist_seed = hash_u(seed ^ 0x4d4f4953u);
    float lat = abs(fract(world_xz.y / (2.0 * climate_lat_scale)) * 2.0 - 1.0);
    float lat_temp = mix(0.30, 1.0, smoothstep(0.0, 1.0, lat));
    float wobble = (value_noise(world_xz * climate_temp_freq, temp_seed) - 0.5) * 2.0 * climate_temp_noise;
    float temp  = clamp(lat_temp + wobble - macro_alt * 0.5, 0.0, 1.0);
    float moist = clamp(value_noise(world_xz * climate_moist_freq, moist_seed), 0.0, 1.0);
    return vec2(temp, moist);
}

// --- ARCHETYPE SHAPE RECIPES (each returns world-height meters) ---------------
float arch_plains(vec2 p, uint seed) {
    return value_fbm(p * 0.00015, seed ^ 0x504c4149u, 2u, 2.0, 0.5) * 120.0;
}
float arch_forest_hills(vec2 p, uint seed) {
    float h = value_fbm(p * 0.00045, seed ^ 0x464f5253u, 4u, 2.0, 0.5) * 520.0;
    return h + value_fbm(p * 0.0016, seed ^ 0x68696c6cu, 3u, 2.0, 0.5) * 70.0;
}
float arch_alpine(vec2 p, uint seed) {
    vec2 w = domain_warp(p, seed, 1800.0, 0.00005);
    float ridges = ridged_fbm(w * 0.00045, seed ^ 0x414c5049u, 6u, 2.03, 0.55);
    float massif = value_fbm(p * 0.00009, seed ^ 0x6d617373u, 2u, 2.0, 0.5);
    return ridges * mix(900.0, 2600.0, massif) + value_fbm(p*0.0018, seed^0x64746c21u,3u,2.0,0.5)*80.0;
}
float arch_swamp(vec2 p, uint seed) {
    float bumps = (value_fbm(p * 0.0009, seed ^ 0x53574d50u, 3u, 2.0, 0.5) - 0.5) * 2.0 * 45.0;
    return -120.0 + bumps;
}
float arch_mesa(vec2 p, uint seed) {
    float b = value_fbm(p * 0.00035, seed ^ 0x4d455341u, 4u, 2.0, 0.5);
    float stepped = floor(b * 5.0) / 5.0;
    float smooth_t = mix(stepped, b, 0.35);
    return smooth_t * 900.0 + value_fbm(p*0.002, seed^0x62616421u,2u,2.0,0.5)*40.0;
}
float arch_highlands(vec2 p, uint seed) {
    float roll = value_fbm(p * 0.0003, seed ^ 0x48494748u, 4u, 2.0, 0.5) * 700.0;
    float rock = ridged_fbm(p * 0.0009, seed ^ 0x726f636bu, 4u, 2.03, 0.5) * 260.0;
    return roll + rock;
}
float band(float x, float center, float width) {
    float d = (x - center) / width;
    return exp(-d * d);
}
// Sparse LONE-PEAK landmarks (deterministic rare giant cones, climate-independent).
float lone_peaks(vec2 p, uint seed) {
    const float TILE = 22000.0;
    vec2 cell = floor(p / TILE);
    float h = 0.0;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        vec2 c = cell + vec2(float(dx), float(dy));
        uint hsd = hash_u(uint(int(c.x)) * 0x9e3779b9u ^ hash_u(uint(int(c.y)) ^ seed));
        float present = float(hsd & 0xffu) / 255.0;
        if (present > 0.82) {
            float jx = float((hsd >> 8) & 0xffu) / 255.0;
            float jy = float((hsd >> 16) & 0xffu) / 255.0;
            vec2 center = (c + vec2(jx, jy)) * TILE;
            float dist = length(p - center);
            float radius = mix(3500.0, 7000.0, float((hsd >> 24) & 0xffu) / 255.0);
            float peak = mix(1800.0, 3400.0, jx);
            float cone = max(0.0, 1.0 - dist / radius);
            cone = cone * cone * (3.0 - 2.0 * cone);
            float rough = ridged_fbm(p * 0.0008, seed ^ 0x70656b21u, 4u, 2.03, 0.5);
            h = max(h, cone * peak * mix(0.7, 1.0, rough));
        }
    }
    return h;
}

// M2.5b composition: blend archetypes by MACRO climate, add lone-peak landmarks.
float composition_height(vec2 world_xz, uint seed) {
    vec2 rp = domain_warp(world_xz, seed ^ 0x52454749u, 3000.0, 0.00003);
    float macro_alt = macro_altitude(rp, seed);
    vec2  mc = macro_climate(rp, seed, macro_alt);
    float temp = mc.x, moist = mc.y;

    float macro_base = (macro_alt - 0.35) * 1400.0;

    float w_alpine   = band(macro_alt, 0.85, 0.16);
    float w_highland = band(macro_alt, 0.62, 0.14);
    float w_forest   = band(macro_alt, 0.45, 0.16) * band(moist, 0.6, 0.35);
    float w_mesa     = band(macro_alt, 0.5, 0.2) * band(moist, 0.15, 0.18) * band(temp, 0.8, 0.3);
    float w_swamp    = band(macro_alt, 0.28, 0.12) * band(moist, 0.85, 0.25);
    float w_plains   = band(macro_alt, 0.32, 0.18);
    float wsum = w_alpine + w_highland + w_forest + w_mesa + w_swamp + w_plains + 1e-4;

    float h = macro_base + (
          w_alpine   * arch_alpine(world_xz, seed)
        + w_highland * arch_highlands(world_xz, seed)
        + w_forest   * arch_forest_hills(world_xz, seed)
        + w_mesa     * arch_mesa(world_xz, seed)
        + w_swamp    * arch_swamp(world_xz, seed)
        + w_plains   * arch_plains(world_xz, seed)
    ) / wsum;

    h += lone_peaks(world_xz, seed);
    return h;
}

// --- M2.1 climate (world-space, low-frequency, deterministic) ----------------
// Per-feature seeds are DERIVED by hashing the master seed (00 §5), never by
// incrementing a shared counter, so temp/moisture are decorrelated from height
// and from each other but reproducible. Returns NORMALIZED climate in ~[0,1]:
//   temperature: hot near the "equator" (a smooth latitude band on world-Z),
//                cooled by altitude (high = cold) and nudged by gentle noise.
//   moisture:    independent low-frequency noise (wet vs dry regions).
// Low frequency => large contiguous bands (the anti-"Perlin confetti" rule,
// MILESTONE_2 §2). Smoothstep keeps the latitude term continuous, no banding.
vec2 climate(vec2 world_xz, float height, uint seed) {
    uint temp_seed  = hash_u(seed ^ 0x54454d50u);   // "TEMP"
    uint moist_seed = hash_u(seed ^ 0x4d4f4953u);    // "MOIS"

    // Latitude band: a smooth triangle wave over world-Z with a half-period of
    // climate_lat_scale, mapped to [0,1] (1 = equator/warm, 0 = pole/cold).
    // Keep a warm FLOOR (lat doesn't reach pure 0) so the equatorial half stays
    // genuinely hot and the whole world isn't dragged cold — the band spans a
    // temperate [floor..1] range, then altitude carves the cold high ground.
    float lat = abs(fract(world_xz.y / (2.0 * climate_lat_scale)) * 2.0 - 1.0);
    float lat_temp = mix(0.30, 1.0, smoothstep(0.0, 1.0, lat));

    // Gentle low-frequency wobble so the latitude bands aren't perfect stripes.
    float wobble = (value_noise(world_xz * climate_temp_freq, temp_seed) - 0.5)
                   * 2.0 * climate_temp_noise;

    // Altitude cooling: only ground ABOVE the lowlands cools (else the fBM's high
    // mean would subtract from everywhere and clamp half the world to 0). Normalize
    // height over [lowland..peak] so lowlands get ~0 cooling, peaks get full lapse.
    float alt_norm = clamp((height - 150.0) / 200.0, 0.0, 1.0);
    float alt_cool = alt_norm * climate_lapse;

    float temp = clamp(lat_temp + wobble - alt_cool, 0.0, 1.0);

    // Moisture: independent low-frequency noise, already in [0,1].
    float moist = clamp(value_noise(world_xz * climate_moist_freq, moist_seed), 0.0, 1.0);

    return vec2(temp, moist);
}

// M2.2 macro altitude: a CONTINENTAL-SCALE low-frequency landform signal used as
// the biome altitude axis instead of the detailed height. *Why:* biomes are a
// macro feature — they follow the regional landform (a whole range = alpine), not
// every small bump. The detailed height runs at base_freq (~period 670 m), which
// fragments biomes into confetti when sampled at coarse LOD cell spacing. So we
// sample a SEPARATE low-frequency landform at biome_alt_freq (continental, like
// the climate noises) — low-frequency by construction, hence contiguous at EVERY
// LOD with no neighborhood blur or page-edge issues. Returns a normalized [0,1]
// "how high is this region" independent of the render height's fine detail.
float macro_altitude(vec2 world_xz, uint seed) {
    uint alt_seed = hash_u(seed ^ 0x414c5421u);   // "ALT!"
    // Two octaves at the continental frequency: big landmasses + sub-regions,
    // still far below any LOD cell spacing. Normalized to ~[0,1].
    float a0 = value_noise(world_xz * biome_alt_freq, alt_seed);
    float a1 = value_noise(world_xz * biome_alt_freq * 2.0, alt_seed + 0x68bc21ebu);
    return clamp(a0 * 0.67 + a1 * 0.33, 0.0, 1.0);
}

// --- M2.2 biome classifier: nearest centroid in weighted climate space --------
// Returns the index of the biome whose centroid (temp_c, moist_c, alt_c) is
// nearest to this cell's (temp, moist, alt), under per-axis weights. Gapless and
// overlap-free by construction (every point gets exactly one biome). DATA-driven:
// the centroids are the pushed BiomeTable rows (00 §6). alt is normalized height.
float biome_id(float temp, float moist, float alt) {
    if (biome_count == 0u) {
        return 0.0;   // no table -> single default; never NaN
    }
    vec3 w = vec3(biome_w_temp, biome_w_moist, biome_w_alt);
    vec3 p = vec3(temp, moist, alt);
    uint best = 0u;
    float best_d = 1e30;
    for (uint b = 0u; b < biome_count; b++) {
        vec3 d = (p - biome_centroid[b].xyz) * w;
        float dist2 = dot(d, d);
        if (dist2 < best_d) {
            best_d = dist2;
            best = b;
        }
    }
    return float(best);
}

void main() {
    uvec2 cell = gl_GlobalInvocationID.xy;
    if (cell.x >= page_res || cell.y >= page_res) {
        return;
    }
    // absolute world position of this cell (00 §5)
    vec2 world_xz = vec2(origin_x, origin_z) + vec2(cell) * spacing;
    // M2.3: general terrain from the composition machine (uplift places structure,
    // hand-set character). Replaces the flat M1 fbm. Climate/biome unchanged below
    // (height never feeds biome — biome uses macro_altitude; no circularity).
    float h = composition_height(world_xz, uint(seed));
    vec2 c = climate(world_xz, h, uint(seed));

    // M2.2: altitude axis = MACRO continental landform (already normalized [0,1]).
    // Low-frequency by construction -> biomes contiguous at every LOD (full height
    // would fragment them into confetti at coarse cell spacing).
    float alt = macro_altitude(world_xz, uint(seed));
    float bid = biome_id(c.x, c.y, alt);

    // Analytic surface normal from the CONTINUOUS height function, evaluated at the
    // true world neighbors (+/- spacing). Because composition_height is pure world
    // math (no texture, no clamp), an edge cell of THIS page and the matching edge
    // cell of the adjacent page compute the SAME neighbor heights -> identical
    // normals across the shared boundary -> the per-page-edge shading seam is gone
    // BY CONSTRUCTION. (The old display-side finite difference clamped UV at page
    // borders, going one-sided, which created the seam.) We store the gradient as
    // (nx, nz); the display reconstructs ny (surface always faces +Y). Central
    // difference matches the old normal's slope convention: dh/dx = (hr-hl)/(2*sp).
    float hl = composition_height(world_xz - vec2(spacing, 0.0), uint(seed));
    float hr = composition_height(world_xz + vec2(spacing, 0.0), uint(seed));
    float hd = composition_height(world_xz - vec2(0.0, spacing), uint(seed));
    float hu = composition_height(world_xz + vec2(0.0, spacing), uint(seed));
    // Match the display shader's normal = normalize(vec3(-(hr-hl), 2*spacing, -(hu-hd))).
    // Store the raw -(slope) components; display normalizes with the 2*spacing term.
    float nx = -(hr - hl);
    float nz = -(hu - hd);

#ifdef RENDER_MODE
    // GPU-resident render path (M2.6): write the same values to storage images the
    // display shader samples directly (no readback). height -> R; climate -> RG
    // (temp,moist); biome -> R; normal -> RG (nx,nz).
    ivec2 px = ivec2(cell);
    imageStore(out_height,  px, vec4(h, 0.0, 0.0, 0.0));
    imageStore(out_climate, px, vec4(c.x, c.y, 0.0, 0.0));
    imageStore(out_biome,   px, vec4(bid, 0.0, 0.0, 0.0));
    imageStore(out_normal,  px, vec4(nx, nz, 0.0, 0.0));
#else
    // Interleaved [height, temp, moisture, biome_id, normal_x, normal_z] per cell
    // (Rust deinterleaves). Channels 0-3 are byte-identical to before (M1.7 height
    // contract intact); 4-5 are the new analytic-normal gradient.
    uint base = (cell.y * page_res + cell.x) * 6u;
    field[base + 0u] = h;
    field[base + 1u] = c.x;
    field[base + 2u] = c.y;
    field[base + 3u] = bid;
    field[base + 4u] = nx;
    field[base + 5u] = nz;
#endif
}
