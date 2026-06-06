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
// M2.4: each biome row is 4 vec4 (BIOME_STRIDE=16 floats):
//   row[0] = (temp_c, moist_c, alt_c, slope_p95)
//   row[1] = spectrum[0..4)   row[2] = spectrum[4..8)   row[3] = pad
// Spectrum = the biome archetype's MEASURED radial amplitude spectrum (M2.3),
// coarse band 0 -> fine band 7, summing ~1.0. slope_p95 = real steepness ceiling.
layout(set = 0, binding = 2, std430) restrict readonly buffer BiomeTable {
    vec4 biome_row[];
};
vec3  biome_centroid(uint b) { return biome_row[b * 4u].xyz; }
float biome_slope(uint b)    { return biome_row[b * 4u].w; }
float biome_spec(uint b, uint o) {
    // o in [0,8): row[1] holds 0..3, row[2] holds 4..7.
    vec4 r = (o < 4u) ? biome_row[b * 4u + 1u] : biome_row[b * 4u + 2u];
    uint k = o & 3u;
    return (k == 0u) ? r.x : (k == 1u) ? r.y : (k == 2u) ? r.z : r.w;
}

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

    // Altitude cooling: higher REGIONAL ground is colder. `height` here is the
    // regional altitude proxy alt*amplitude (~[0,amplitude]); normalize over that
    // span so low land gets ~0 cooling and the highest regions get full lapse.
    float alt_norm = clamp(height / max(amplitude, 1.0), 0.0, 1.0);
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

// M2.4 spectral synthesis. Domain-warped octave sum where octave o's amplitude is
// the biome archetype's MEASURED spectrum weight (M2.3 fingerprint), not a generic
// 0.5^o. This makes each biome carry real-Earth structure (mountains ridged +
// macro-heavy, plains fine-and-flat). 8 octaves from base_freq. The per-octave
// weight is also slope-bounded by the biome's measured slope_p95 so synthesis
// can't produce near-vertical cliffs (M2.4 Task 6).
vec2 warp2(vec2 p, uint seed) {
    return vec2(value_noise(p, seed), value_noise(p, seed ^ 0x9e3779b9u)) - 0.5;
}

const uint SPEC_OCTAVES = 8u;
float spectral_height(vec2 world_xz, uint seed, uint biome) {
    // Domain warp the low frequencies for organic shapes (warp amount scales with
    // amplitude so it bends features, not pixels).
    vec2 wp = world_xz + (amplitude * 0.6) * warp2(world_xz * (base_freq * 0.5), seed ^ 0x57415250u);
    float freq = base_freq;
    float sum = 0.0;
    float slope_ceiling = biome_slope(biome);    // rise/run, from the DEM
    for (uint o = 0u; o < SPEC_OCTAVES; o++) {
        // Low octaves warped (organic), high octaves plain (crisp + cheap).
        vec2 p = (o < 2u) ? wp : world_xz;
        float n = value_noise(p * freq, seed + o * 0x68bc21ebu);
        float w = biome_spec(biome, o);          // amplitude = measured spectrum weight
        // Cap this octave's weight so its worst-case per-cell slope can't exceed
        // the measured ceiling (×1.5 margin -> steep but not vertical-walled).
        float oct_slope = w * 2.0 * (spacing * freq);
        float cap = (slope_ceiling * 1.5) / max(oct_slope, 1e-6);
        if (cap < 1.0) w *= cap;
        sum += w * n;
        freq *= 2.0;
    }
    // spectrum sums ~1.0, so sum is ~[0,1]; scale to world height units.
    return sum * amplitude;
}

void main() {
    uvec2 cell = gl_GlobalInvocationID.xy;
    if (cell.x >= page_res || cell.y >= page_res) {
        return;
    }
    // absolute world position of this cell (00 §5)
    vec2 world_xz = vec2(origin_x, origin_z) + vec2(cell) * spacing;
    uint useed = uint(seed);

    // Biome + climate from the biome-INDEPENDENT macro altitude (no circularity,
    // 00 §5): height never feeds back into biome selection.
    float alt = macro_altitude(world_xz, useed);
    vec2 c = climate(world_xz, alt * amplitude, useed);
    float bid = biome_id(c.x, c.y, alt);
    uint b = uint(bid + 0.5);

    // M2.4: height = shared continental base (biome-independent, continuous across
    // borders) + this biome's SPECTRAL relief (octave amplitudes from the DEM
    // fingerprint). Different biomes carry different real-Earth structure; the
    // shared base keeps borders continuous (a relief-character step, not a cliff).
    float base_h = alt * amplitude * 0.5;
    float relief = spectral_height(world_xz, useed, b);
    float h = base_h + relief;

    // Interleaved [height, temp, moisture, biome_id] per cell (Rust deinterleaves).
    uint o = (cell.y * page_res + cell.x) * 4u;
    field[o + 0u] = h;
    field[o + 1u] = c.x;
    field[o + 2u] = c.y;
    field[o + 3u] = bid;
}
