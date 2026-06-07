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

// Output: PAGE_RES * PAGE_RES cells, 4 floats per cell, interleaved row-major:
//   field[(z*PAGE_RES + x)*4 + 0] = height (world Y, what M1 produced)
//   field[(z*PAGE_RES + x)*4 + 1] = temperature  (normalized ~[0,1], M2.1)
//   field[(z*PAGE_RES + x)*4 + 2] = moisture     (normalized ~[0,1], M2.1)
//   field[(z*PAGE_RES + x)*4 + 3] = biome id      (float-encoded int, M2.2)
// Rust deinterleaves channel 0 to keep the M1.7 height-array/R32F-texture
// contract intact (collision still reads height-only), packs temp+moisture into
// one RG32F texture and the biome id into an R32F texture for the display shader.
layout(set = 0, binding = 0, std430) restrict writeonly buffer FieldBuffer {
    float field[];
};

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

// --- M2.4 DEM character tuning ----------------------------------------------
// Runtime does NOT open DEM files. These constants are distilled from the
// committed offline fingerprints in wg-13/data/dem_fingerprints.json, sorted by
// slope_p95 from gentle -> steep. vec4 = (slope_p95, ridge_character,
// spectrum_centroid, fine_spectrum_energy). This table tunes the existing M2.3
// composition machine; it does not place structure and does not involve biomes.
vec4 dem_character_row(int i) {
    if (i <= 0)  return vec4(0.16025463, 0.009426956, 5.577, 0.628); // wetland
    if (i == 1)  return vec4(0.18104625, 0.002419439, 4.881, 0.425); // grassland
    if (i == 2)  return vec4(0.30440970, 0.004737892, 4.952, 0.461); // desert
    if (i == 3)  return vec4(0.36732940, 0.004590686, 4.289, 0.348); // tundra
    if (i == 4)  return vec4(0.39517573, 0.000854868, 4.167, 0.308); // volcanic
    if (i == 5)  return vec4(0.43120566, 0.013333080, 5.120, 0.492); // rainforest
    if (i == 6)  return vec4(0.51419055, 0.002554115, 4.631, 0.381); // coast
    if (i == 7)  return vec4(0.53216090, 0.002983702, 4.876, 0.421); // karst
    if (i == 8)  return vec4(0.66659200, 0.001534401, 4.424, 0.318); // badlands
    if (i == 9)  return vec4(0.68599486, 0.003067266, 4.024, 0.240); // temperate
    if (i == 10) return vec4(0.73545390, 0.001075893, 4.148, 0.242); // glacial
    return vec4(0.88756890, 0.001333152, 4.218, 0.251);              // mountain
}

vec4 dem_character_sample(float t) {
    float x = clamp(t, 0.0, 1.0) * 11.0;
    int i = int(floor(x));
    float f = smoothstep(0.0, 1.0, fract(x));
    return mix(dem_character_row(i), dem_character_row(i + 1), f);
}

vec4 terrain_character(vec2 p, float uplift, uint seed) {
    float region = value_fbm(p * 0.000018, seed ^ 0x43484152u, 3u, 2.07, 0.55); // "CHAR"
    float local = value_noise(p * 0.00009 + vec2(11.0, 29.0), seed ^ 0x64656d21u); // "dem!"
    float t = clamp(0.72 * uplift + 0.20 * region + 0.08 * local, 0.0, 1.0);
    return dem_character_sample(t);
}

float dem_slope_norm(vec4 ch) {
    return clamp((ch.x - 0.16025463) / (0.88756890 - 0.16025463), 0.0, 1.0);
}

float dem_ridge_norm(vec4 ch) {
    return clamp(ch.y / 0.01333308, 0.0, 1.0);
}

float dem_fine_norm(vec4 ch) {
    return clamp((ch.w - 0.240) / (0.628 - 0.240), 0.0, 1.0);
}

// M2.3/M2.4 general terrain: ONE composition machine for the whole world.
// Structure comes from uplift; local character is now DEM-tuned from the table
// above. Most of the world is gentle lowland; ranges stand where uplift is high.
float composition_height(vec2 world_xz, uint seed) {
    // --- structure knobs (still hand-set; DEM tunes character below) ---
    const float WARP_AMOUNT  = 2200.0;   // world units of coord bend
    const float WARP_FREQ    = 0.00004;  // warp's own low freq (~25 km)
    const float UPLIFT_FREQ  = 0.000025; // range placement (~40 km regions)
    const float UPLIFT_LO    = 0.45;     // below -> lowland (uplift 0)
    const float UPLIFT_HI    = 0.70;     // above -> full range (uplift 1); wide gap -> mostly lowland
    const uint  RIDGE_OCT    = 6u;
    const float RIDGE_LAC    = 2.03;
    const float BASE_FREQ    = 0.00012;  // continental base undulation (~8 km)
    const uint  BASE_OCT     = 3u;
    const float DETAIL_FREQ  = 0.0016;
    const uint  DETAIL_OCT   = 4u;

    vec2 warp    = domain_warp(world_xz, seed, WARP_AMOUNT, WARP_FREQ);
    float uplift = uplift_field(warp, seed, UPLIFT_FREQ, UPLIFT_LO, UPLIFT_HI);
    vec4 ch = terrain_character(warp, uplift, seed);
    float slope_n = dem_slope_norm(ch);
    float ridge_n = dem_ridge_norm(ch);
    float fine_n = dem_fine_norm(ch);

    float base_amp = mix(220.0, 140.0, slope_n);
    float ridge_scale = mix(0.00030, 0.00068, fine_n);
    float ridge_gain = mix(0.48, 0.66, clamp(0.65 * slope_n + 0.35 * ridge_n, 0.0, 1.0));
    float relief_amp = mix(1050.0, 1850.0, slope_n);
    float carve_depth = mix(0.26, 0.56, slope_n);
    float detail_amp = mix(45.0, 125.0, clamp(0.65 * fine_n + 0.35 * ridge_n, 0.0, 1.0));

    float base   = value_fbm(world_xz * BASE_FREQ, seed ^ 0x42415345u, BASE_OCT, 2.0, 0.5) * base_amp;
    float ridges = ridged_fbm(warp * ridge_scale, seed, RIDGE_OCT, RIDGE_LAC, ridge_gain);
    float relief = uplift * ridges * relief_amp;
    float carve  = valley_carve(uplift, carve_depth * relief_amp);
    float detail = (value_fbm(world_xz * DETAIL_FREQ, seed ^ 0x44455421u, DETAIL_OCT, 2.0, 0.5) - 0.5)
                   * 2.0 * detail_amp;
    return base + relief - carve + detail;
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
    // M2.4: general terrain from the composition machine. Uplift places structure;
    // DEM-derived character tunes relief/ridges/detail. Climate/biome unchanged
    // below (height never feeds biome; biome uses macro_altitude; no circularity).
    float h = composition_height(world_xz, uint(seed));
    vec2 c = climate(world_xz, h, uint(seed));

    // M2.2: altitude axis = MACRO continental landform (already normalized [0,1]).
    // Low-frequency by construction -> biomes contiguous at every LOD (full height
    // would fragment them into confetti at coarse cell spacing).
    float alt = macro_altitude(world_xz, uint(seed));
    float bid = biome_id(c.x, c.y, alt);

    // Interleaved [height, temp, moisture, biome_id] per cell (Rust deinterleaves).
    uint base = (cell.y * page_res + cell.x) * 4u;
    field[base + 0u] = h;
    field[base + 1u] = c.x;
    field[base + 2u] = c.y;
    field[base + 3u] = bid;
}
