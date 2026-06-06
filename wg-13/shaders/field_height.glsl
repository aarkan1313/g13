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

// M2.2/M2.3 biome table: nearest-centroid Whittaker classifier (M2.2) + per-biome
// height shaping params (M2.3). Flat vec4 array, TWO vec4 per biome (BIOME_STRIDE
// = 8 floats), std430-aligned:
//   biome_row[b*2 + 0] = (temp_c, moist_c, alt_c, detail_amp)
//   biome_row[b*2 + 1] = (detail_rough, _, _, _)
// DATA pushed from Rust (00 §6) — adding a biome is a row here, never a code
// branch. The field outputs only the id; the display shader owns the color table.
layout(set = 0, binding = 2, std430) restrict readonly buffer BiomeTable {
    vec4 biome_row[];        // 2 vec4 per biome (centroid+amp, rough+pad)
};

// Accessors so the rest of the shader reads biome data by meaning, not index math.
vec3  biome_centroid(uint b)    { return biome_row[b * 2u].xyz; }
float biome_detail_amp(uint b)  { return biome_row[b * 2u].w; }
float biome_detail_rough(uint b){ return biome_row[b * 2u + 1u].x; }

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

float fbm(vec2 world_xz, uint seed) {
    float freq = base_freq;
    float amp = amplitude;
    float sum = 0.0;
    for (uint o = 0u; o < octaves; o++) {
        // vary the seed per octave so octaves are decorrelated but deterministic
        sum += amp * value_noise(world_xz * freq, seed + o * 0x68bc21ebu);
        freq *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

// --- M2.3 per-biome height shaping --------------------------------------------
// The full height is split into a SHARED base landform (the low octaves, the same
// everywhere -> continuous across biome borders, no cliffs) plus per-biome DETAIL
// (the high octaves, scaled by the biome's detail_amp/detail_rough). Biome is
// chosen from the macro-altitude landform (00 §5: NOT from this shaped height), so
// there's no circular dependency. Mountains = big rough detail; plains = ~0 detail.
const uint BASE_OCTAVES = 2u;   // low octaves shared by all biomes (the macro shape)

// Shared base landform: the first BASE_OCTAVES of the fBM. Identical on both sides
// of any biome border, so the surface stays continuous (only detail intensity
// steps across a border — a roughness change, never an elevation jump).
float base_landform(vec2 world_xz, uint seed) {
    float freq = base_freq;
    float amp = amplitude;
    float sum = 0.0;
    uint oc = min(BASE_OCTAVES, octaves);
    for (uint o = 0u; o < oc; o++) {
        sum += amp * value_noise(world_xz * freq, seed + o * 0x68bc21ebu);
        freq *= 2.0;
        amp *= 0.5;
    }
    return sum;
}

// Per-biome detail: the high octaves (above BASE_OCTAVES), with the octave count
// extended by `rough` (more octaves = more fine ruggedness) and scaled outside by
// the caller's detail_amp. Returns detail in the SAME amplitude units as the base
// (the per-octave amp continues the base's geometric falloff), so detail_amp ~1
// reproduces M1's character and detail_amp 0 gives a flat (base-only) surface.
float detail_landform(vec2 world_xz, uint seed, float rough) {
    // Start where the base left off (continue the geometric series).
    float freq = base_freq * exp2(float(BASE_OCTAVES));
    float amp = amplitude * exp2(-float(BASE_OCTAVES));
    float sum = 0.0;
    // Total detail octaves = the configured high octaves, plus up to a few extra
    // from `rough` for rugged biomes. Clamp so it stays bounded/deterministic.
    uint base_detail = octaves > BASE_OCTAVES ? octaves - BASE_OCTAVES : 0u;
    uint extra = uint(clamp(rough, 0.0, 4.0) + 0.5);
    uint oc = base_detail + extra;
    for (uint o = 0u; o < oc; o++) {
        sum += amp * value_noise(world_xz * freq, seed + (BASE_OCTAVES + o) * 0x68bc21ebu);
        freq *= 2.0;
        amp *= 0.5;
    }
    return sum;
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
        vec3 d = (p - biome_centroid(b)) * w;
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
    uint useed = uint(seed);

    // Shared base landform (low octaves) — continuous across biome borders.
    float base_h = base_landform(world_xz, useed);

    // Climate from the BASE elevation (not the biome-shaped detail), so climate
    // and biome selection never depend on per-biome shaping -> no circularity.
    vec2 c = climate(world_xz, base_h, useed);

    // M2.2: biome from the MACRO continental landform (independent of shaped
    // height). Low-frequency -> contiguous at every LOD.
    float alt = macro_altitude(world_xz, useed);
    float bid = biome_id(c.x, c.y, alt);
    uint b = uint(bid + 0.5);

    // M2.3: per-biome DETAIL on the shared base. Mountains: high amp + rough;
    // plains: ~0 amp (flat). Border = a roughness step on a continuous base, no
    // cliff (M2.4 will blend detail_amp/rough across borders).
    float detail = biome_detail_amp(b) * detail_landform(world_xz, useed, biome_detail_rough(b));
    float h = base_h + detail;

    // Interleaved [height, temp, moisture, biome_id] per cell (Rust deinterleaves).
    uint o = (cell.y * page_res + cell.x) * 4u;
    field[o + 0u] = h;
    field[o + 1u] = c.x;
    field[o + 2u] = c.y;
    field[o + 3u] = bid;
}
