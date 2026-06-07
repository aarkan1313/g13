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
    uint  terrain_mode;        // M2.4b: 0 = REFERENCE (composition), 1 = SCAFFOLD_CANDIDATE (oracle)
    float scaffold_seed;       // M2.4b: oracle seed (defaults to seed)
    float macro_origin_x;   // M2.4c: world X of macro region-slot (0,0)
    float macro_origin_z;   // M2.4c: world Z of macro region-slot (0,0)
    float macro_core_span;  // M2.4c: world span of one macro region core
    uint  macro_present_mask; // M2.4c: bit (dz*2+dx) set if slot (dx,dz) resident
};

// M2.4c: the page's 2x2 macro region neighborhood (slot (dx,dz), dx,dz in {0,1}).
// Bound by dispatch_page; READ in Task 4 (macro_sample). Declared here so the
// uniform set matches the binding layout even before mode 2 reads them.
layout(set = 0, binding = 3)  uniform sampler2D macro_h_00;
layout(set = 0, binding = 4)  uniform sampler2D macro_r_00;
layout(set = 0, binding = 5)  uniform sampler2D macro_c_00;
layout(set = 0, binding = 6)  uniform sampler2D macro_h_10;
layout(set = 0, binding = 7)  uniform sampler2D macro_r_10;
layout(set = 0, binding = 8)  uniform sampler2D macro_c_10;
layout(set = 0, binding = 9)  uniform sampler2D macro_h_01;
layout(set = 0, binding = 10) uniform sampler2D macro_r_01;
layout(set = 0, binding = 11) uniform sampler2D macro_c_01;
layout(set = 0, binding = 12) uniform sampler2D macro_h_11;
layout(set = 0, binding = 13) uniform sampler2D macro_r_11;
layout(set = 0, binding = 14) uniform sampler2D macro_c_11;

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

// M2.3 general terrain: ONE composition machine for the whole world. Structure
// from uplift; character HAND-SET here (DEM-tuned in M2.4). Most of the world is
// gentle lowland (base + small detail); ranges stand where uplift is high.
float composition_height(vec2 world_xz, uint seed) {
    // --- hand-set character knobs (M2.3 tuning; DEM-driven in M2.4) ---
    const float WARP_AMOUNT  = 2200.0;   // world units of coord bend
    const float WARP_FREQ    = 0.00004;  // warp's own low freq (~25 km)
    const float UPLIFT_FREQ  = 0.000025; // range placement (~40 km regions)
    const float UPLIFT_LO    = 0.45;     // below -> lowland (uplift 0)
    const float UPLIFT_HI    = 0.70;     // above -> full range (uplift 1); wide gap -> mostly lowland
    const uint  RIDGE_OCT    = 6u;
    const float RIDGE_LAC    = 2.03;
    const float RIDGE_GAIN   = 0.55;
    const float RIDGE_SCALE  = 0.0004;   // ridgeline scale (~2.5 km)
    const float RELIEF_AMP   = 1600.0;   // peak range relief (m)
    const float CARVE_DEPTH  = 0.4;      // fraction of relief pressed into valleys
    const float BASE_FREQ    = 0.00012;  // continental base undulation (~8 km)
    const uint  BASE_OCT     = 3u;
    const float BASE_AMP     = 180.0;    // gentle lowland relief everywhere
    const float DETAIL_FREQ  = 0.0016;
    const uint  DETAIL_OCT   = 4u;
    const float DETAIL_AMP   = 70.0;     // fine surface roughness

    vec2 warp    = domain_warp(world_xz, seed, WARP_AMOUNT, WARP_FREQ);
    float uplift = uplift_field(warp, seed, UPLIFT_FREQ, UPLIFT_LO, UPLIFT_HI);
    float base   = value_fbm(world_xz * BASE_FREQ, seed ^ 0x42415345u, BASE_OCT, 2.0, 0.5) * BASE_AMP;
    float ridges = ridged_fbm(warp * RIDGE_SCALE, seed, RIDGE_OCT, RIDGE_LAC, RIDGE_GAIN);
    float relief = uplift * ridges * RELIEF_AMP;
    float carve  = valley_carve(uplift, CARVE_DEPTH * RELIEF_AMP);
    float detail = (value_fbm(world_xz * DETAIL_FREQ, seed ^ 0x44455421u, DETAIL_OCT, 2.0, 0.5) - 0.5)
                   * 2.0 * DETAIL_AMP;
    return base + relief - carve + detail;
}

// --- M2.4b oracle (per-cell scaffold) ---------------------------------------
// Faithful GLSL port of structural_scaffold::synthesize_cell + helpers. Same
// structure, constants, frequencies, octaves, and 4 style families as the
// reviewed Rust oracle. Uses a 32-bit hash (osc_*) adapted from the shader's
// hash_u family — NOT a bit-exact 64-bit splitmix emulation (GLSL has no verified
// int64 here; the reviewed sheet was inconclusive so a pixel-match buys nothing).
// So live mode-1 terrain is a STATISTICAL TWIN of the reviewed oracle: same range
// spacing / valley structure / character, different exact noise. Pure fn of
// (world coords, seed): no neighbors, no apron, no blur — this is what fits a
// per-cell GPU field. See docs/superpowers/plans/2026-06-06-m2-4b-oracle-port-map.md.

const float OSC_TAU = 6.28318530717958647692;

float osc_smootherstep(float x) {
    float t = clamp(x, 0.0, 1.0);
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

// Deterministic [0,1) from a lattice point + seed + salt (mirrors rand01_i's role).
float osc_rand01(int x, int z, uint seed, uint salt) {
    uint h = hash_u(uint(x) * 0x9e3779b9u
        ^ hash_u(uint(z) * 0x85ebca6bu
        ^ hash_u(seed ^ (salt * 0x68bc21ebu))));
    return float(h) * (1.0 / 4294967296.0);
}

// Value noise at world position p (scaled by freq), smootherstep-interpolated.
float osc_value_noise(vec2 p, float freq, uint seed, uint salt) {
    vec2 s = p * freq;
    int x0 = int(floor(s.x));
    int z0 = int(floor(s.y));
    float fx = s.x - float(x0);
    float fz = s.y - float(z0);
    float ux = osc_smootherstep(fx);
    float uz = osc_smootherstep(fz);
    float n00 = osc_rand01(x0, z0, seed, salt);
    float n10 = osc_rand01(x0 + 1, z0, seed, salt);
    float n01 = osc_rand01(x0, z0 + 1, seed, salt);
    float n11 = osc_rand01(x0 + 1, z0 + 1, seed, salt);
    float nx0 = mix(n00, n10, ux);
    float nx1 = mix(n01, n11, ux);
    return mix(nx0, nx1, uz);
}

float osc_fbm(vec2 p, float freq, int oct, float lac, float gain, uint seed, uint salt) {
    float sum = 0.0, amp = 1.0, norm = 0.0, f = freq;
    for (int o = 0; o < oct; o++) {
        sum  += osc_value_noise(p, f, seed, salt ^ (uint(o + 1) * 0x9e3779b9u)) * amp;
        norm += amp; amp *= gain; f *= lac;
    }
    return sum / max(norm, 1e-6);
}

float osc_ridged_fbm(vec2 p, float freq, int oct, uint seed, uint salt) {
    float sum = 0.0, amp = 0.55, norm = 0.0, f = freq, prev = 1.0;
    for (int o = 0; o < oct; o++) {
        float n = osc_value_noise(p, f, seed, salt ^ (uint(o + 3) * 0x68bc21ebu));
        float r = 1.0 - abs(2.0 * n - 1.0);
        float rounded = smoothstep(0.08, 0.92, r);
        float weighted = rounded * (0.58 + prev * 0.42);
        sum += weighted * amp; norm += amp; prev = rounded; amp *= 0.52; f *= 2.04;
    }
    return sum / max(norm, 1e-6);
}

vec2 osc_rotate2(vec2 p, float angle) {
    float ca = cos(angle), sa = sin(angle);
    return vec2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);
}

float osc_point_seg_dist(vec2 p, vec2 a, vec2 b) {
    vec2 v = b - a;
    vec2 w = p - a;
    float denom = dot(v, v);
    if (denom <= 1e-12) return length(p - a);
    float t = clamp(dot(w, v) / denom, 0.0, 1.0);
    return length(p - (a + v * t));
}

struct OscStyleParams {
    float range_cell_m; float range_width_m; float ridge_width_m;
    float range_len_min; float range_len_max; float relief_m;
    float primary_spacing_m; float primary_width_m; float primary_amp_m;
    float tributary_width_m; float tributary_len_m; float detail_amp_m; float detail_freq;
};

struct OscRangeField { float envelope; float massif; float ridge_axis; float ridge_distance_m; };
struct OscSegment { float ax; float az; float bx; float bz; float weight; };

// style id 0..3 in .x, weight in .y (mirrors style_at).
vec2 osc_style_at(vec2 p, uint seed) {
    float signal = osc_fbm(p, 1.0 / 140000.0, 3, 2.0, 0.55, seed ^ 0xa53c1f2du, 0u);
    float scaled = clamp(signal * 4.0, 0.0, 3.999);
    float id = floor(scaled);
    float center = id + 0.5;
    return vec2(id, clamp(1.0 - abs(scaled - center) * 2.0, 0.0, 1.0));
}

OscStyleParams osc_style_params(int style) {
    OscStyleParams s;
    if (style == 0) {        // AlpineBranching
        s = OscStyleParams(20000.0, 5600.0, 1850.0, 17000.0, 31000.0, 1280.0,
                           12500.0, 1550.0, 3250.0, 900.0, 8000.0, 145.0, 1.0 / 5800.0);
    } else if (style == 1) { // SierraBlock
        s = OscStyleParams(28000.0, 7200.0, 2300.0, 24000.0, 42000.0, 1080.0,
                           14000.0, 1750.0, 2300.0, 1050.0, 10500.0, 115.0, 1.0 / 7200.0);
    } else if (style == 2) { // PamirChain
        s = OscStyleParams(24000.0, 5900.0, 1650.0, 28000.0, 48000.0, 1360.0,
                           10500.0, 1450.0, 2100.0, 820.0, 9500.0, 135.0, 1.0 / 5200.0);
    } else {                 // DissectedHighlands
        s = OscStyleParams(18500.0, 4800.0, 1450.0, 12500.0, 25000.0, 950.0,
                           11500.0, 1420.0, 2900.0, 760.0, 7200.0, 160.0, 1.0 / 4700.0);
    }
    return s;
}

vec2 osc_domain_warp(vec2 p, int style, uint seed) {
    float amount = (style == 1) ? 2200.0 : (style == 2) ? 1450.0 : (style == 0) ? 3200.0 : 3650.0;
    float dx = (osc_fbm(p, 1.0 / 58000.0, 3, 2.0, 0.55, seed ^ 0x1515a11au, 0u) - 0.5) * amount;
    float dz = (osc_fbm(p, 1.0 / 61000.0, 3, 2.0, 0.55, seed ^ 0x2d33cafeu, 0u) - 0.5) * amount;
    return p + vec2(dx, dz);
}

OscSegment osc_range_segment(int style, OscStyleParams params, int gx, int gz, int lane, uint seed) {
    float cell_size = params.range_cell_m;
    uint slane = uint(lane);
    float center_x = (float(gx) + 0.12 + osc_rand01(gx, gz, seed, 11u + slane) * 0.76) * cell_size;
    float center_z = (float(gz) + 0.12 + osc_rand01(gx, gz, seed, 31u + slane) * 0.76) * cell_size;
    float coh = osc_value_noise(vec2(center_x, center_z), 1.0 / 150000.0, seed ^ 0x7311cafeu, 0u);
    float local = osc_rand01(gx, gz, seed, 53u + slane);
    float style_bias = ((style == 0) ? 0.16 : (style == 1) ? 0.08 : (style == 2) ? 0.28 : 0.20) * OSC_TAU;
    float angle = style_bias + (coh * 0.70 + local * 0.30) * OSC_TAU;
    float length_m = params.range_len_min
        + osc_rand01(gx, gz, seed, 71u + slane) * (params.range_len_max - params.range_len_min);
    float dx = cos(angle) * length_m * 0.5;
    float dz = sin(angle) * length_m * 0.5;
    OscSegment seg;
    seg.ax = center_x - dx; seg.az = center_z - dz;
    seg.bx = center_x + dx; seg.bz = center_z + dz;
    seg.weight = 0.68 + osc_rand01(gx, gz, seed, 97u + slane) * 0.32;
    return seg;
}

OscRangeField osc_range_field(int style, OscStyleParams params, vec2 p, uint seed) {
    float cell_size = params.range_cell_m;
    int cx = int(floor(p.x / cell_size));
    int cz = int(floor(p.y / cell_size));
    float best_dist = 1e30;
    float best_score = 0.0;
    float best_ridge = 0.0;
    int lane_count = (style == 0 || style == 3) ? 3 : 2;
    for (int dz = -2; dz <= 2; dz++) {
        for (int dx = -2; dx <= 2; dx++) {
            int gx = cx + dx;
            int gz = cz + dz;
            for (int lane = 0; lane < lane_count; lane++) {
                OscSegment seg = osc_range_segment(style, params, gx, gz, lane, seed);
                float dist = osc_point_seg_dist(p, vec2(seg.ax, seg.az), vec2(seg.bx, seg.bz));
                float e = exp(-pow(dist / params.range_width_m, 2.0)) * seg.weight;
                float r = exp(-pow(dist / params.ridge_width_m, 2.0)) * seg.weight;
                best_dist = min(best_dist, dist);
                best_score = max(best_score, e);
                best_ridge = max(best_ridge, r);
            }
        }
    }
    float regional = osc_fbm(p, 1.0 / 92000.0, 4, 2.03, 0.52, seed ^ 0x6d2b79f5u, 0u);
    float envelope = smoothstep(0.22, 0.78, best_score * 0.90 + regional * 0.22);
    float massif_noise = osc_fbm(p, 1.0 / 18000.0, 3, 2.0, 0.52, seed ^ 0x61e72cadu, 0u);
    OscRangeField rf;
    rf.envelope = envelope;
    rf.massif = clamp(envelope * (0.48 + massif_noise * 0.52), 0.0, 1.0);
    rf.ridge_axis = clamp(best_ridge * envelope, 0.0, 1.0);
    rf.ridge_distance_m = best_dist;
    return rf;
}

float osc_primary_channel_dist(int style, OscStyleParams params, vec2 p, uint seed) {
    float angle = ((style == 0) ? 0.36 : (style == 1) ? 0.72 : (style == 2) ? 1.42 : 0.98)
        + (osc_rand01(0, 0, seed ^ 0xabc17133u, uint(style)) - 0.5) * 0.38;
    vec2 uv = osc_rotate2(p, angle);
    float u = uv.x;
    float v = uv.y;
    float spacing = params.primary_spacing_m;
    int k0 = int(floor(v / spacing));
    float best = 1e30;
    for (int k = k0 - 2; k <= k0 + 2; k++) {
        float phase = osc_rand01(k, style, seed ^ 0xabc17133u, 17u) * OSC_TAU;
        float offset = (osc_rand01(k, style, seed ^ 0xabc17133u, 19u) - 0.5) * spacing * 0.35;
        float curve = float(k) * spacing
            + offset
            + params.primary_amp_m * sin(u / 17000.0 + phase)
            + params.primary_amp_m * 0.34 * sin(u / 8500.0 + phase * 1.7);
        best = min(best, abs(v - curve));
    }
    return best;
}

float osc_tributary_channel_dist(int style, OscStyleParams params, vec2 p, uint seed) {
    float cell_size = params.tributary_len_m * 1.45;
    int cx = int(floor(p.x / cell_size));
    int cz = int(floor(p.y / cell_size));
    float best = 1e30;
    for (int dz = -2; dz <= 2; dz++) {
        for (int dx = -2; dx <= 2; dx++) {
            int gx = cx + dx;
            int gz = cz + dz;
            float center_x = (float(gx) + 0.12 + osc_rand01(gx, gz, seed ^ 0x93ab41e9u, 23u) * 0.76) * cell_size;
            float center_z = (float(gz) + 0.12 + osc_rand01(gx, gz, seed ^ 0x93ab41e9u, 29u) * 0.76) * cell_size;
            float coh = osc_value_noise(vec2(center_x, center_z), 1.0 / 74000.0, seed ^ 0x44c291afu, 0u);
            float local = osc_rand01(gx, gz, seed ^ 0x93ab41e9u, 31u);
            float style_turn = (style == 0) ? 0.35 : (style == 1) ? 0.18 : (style == 2) ? 0.50 : 0.72;
            float angle = (coh * (1.0 - style_turn) + local * style_turn) * OSC_TAU;
            float length_m = params.tributary_len_m * (0.55 + osc_rand01(gx, gz, seed ^ 0x93ab41e9u, 37u) * 0.85);
            float ax = center_x - cos(angle) * length_m * 0.5;
            float az = center_z - sin(angle) * length_m * 0.5;
            float bx = center_x + cos(angle) * length_m * 0.5;
            float bz = center_z + sin(angle) * length_m * 0.5;
            best = min(best, osc_point_seg_dist(p, vec2(ax, az), vec2(bx, bz)));
        }
    }
    return best;
}

// Per-cell oracle height — mirrors synthesize_cell's preview_height_m assembly.
float oracle_height(vec2 world_xz, uint seed) {
    vec2 sa = osc_style_at(world_xz, seed);
    int style = int(sa.x);
    OscStyleParams params = osc_style_params(style);
    vec2 w = osc_domain_warp(world_xz, style, seed);
    OscRangeField range = osc_range_field(style, params, w, seed);

    float primary_distance = osc_primary_channel_dist(style, params, world_xz, seed);
    float tributary_distance = osc_tributary_channel_dist(style, params, w, seed);

    float primary_mask = 1.0 - smoothstep(0.0, params.primary_width_m, primary_distance);
    float tributary_mask = (1.0 - smoothstep(0.0, params.tributary_width_m, tributary_distance)) * range.envelope;
    float carve_mask = clamp(max(primary_mask, tributary_mask * 0.34), 0.0, 1.0);
    float pass_floor = clamp(primary_mask * range.envelope * (1.0 - range.ridge_axis * 0.35), 0.0, 1.0);

    float base = (osc_fbm(w, 1.0 / 120000.0, 4, 2.0, 0.55, seed ^ 0x5198f00du, 0u) - 0.42) * 340.0;
    float regional_lift = smoothstep(0.36, 0.78,
        osc_fbm(w, 1.0 / 84000.0, 3, 2.1, 0.50, seed ^ 0xf137d00du, 0u));
    float ridge_texture = osc_ridged_fbm(w, params.detail_freq * 0.72, 5, seed ^ 0x88ac4e21u, 0u);
    float near_detail = (osc_fbm(w, params.detail_freq * 1.8, 4, 2.04, 0.48, seed ^ 0x1c69b3f1u, 0u) - 0.5)
        * params.detail_amp_m;
    float ridge_micro = (osc_ridged_fbm(w + vec2(913.0, -421.0), params.detail_freq * 3.1, 5, seed ^ 0xa17e55edu, 0u) - 0.45)
        * params.relief_m * 0.20 * range.envelope;
    float branch_detail = (osc_fbm(w + vec2(-701.0, 1303.0), params.detail_freq * 4.4, 4, 2.08, 0.46, seed ^ 0x5eaf1075u, 0u) - 0.5)
        * params.detail_amp_m * 0.75 * range.envelope;

    float massif_height = range.massif * params.relief_m * (0.55 + regional_lift * 0.45);
    float ridge_height = range.envelope
        * (0.35 + range.ridge_axis * 0.65)
        * (0.45 + ridge_texture * 0.55)
        * params.relief_m * 0.72;
    float carve = carve_mask * (115.0 + range.envelope * params.relief_m * 0.22);
    float pass_cut = pass_floor * (90.0 + params.relief_m * 0.08);
    float lowland_smooth = (1.0 - range.envelope) * 70.0;

    return 140.0 + base + massif_height + ridge_height + ridge_micro + branch_detail + near_detail
        - carve - pass_cut + lowland_smooth;
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
    float h;
    if (terrain_mode == 1u) {
        h = oracle_height(world_xz, uint(scaffold_seed));
    } else {
        h = composition_height(world_xz, uint(seed));
    }

    // M2.4c keep-alive: reference all 12 macro samplers so SPIR-V retains their
    // binding layout even though mode 0/1 never read them (Task 4 adds the real
    // read and DELETES this whole block). The branch can never run (the runtime
    // mask only ever sets the low 4 bits, never 0xFFFFFFFF), so output is
    // bit-identical. What keeps this SAFE is that macro_present_mask is a
    // NON-CONSTANT uniform: the compiler can't fold the branch away, so it must
    // keep the branch (and thus the texture() calls / bindings) live. The
    // `* 0.0` alone would NOT be a reliable optimizer barrier. Do not strip the
    // mask guard.
    if (macro_present_mask == 0xFFFFFFFFu) {
        float keep = texture(macro_h_00, vec2(0.5)).r + texture(macro_r_00, vec2(0.5)).r + texture(macro_c_00, vec2(0.5)).r
                   + texture(macro_h_10, vec2(0.5)).r + texture(macro_r_10, vec2(0.5)).r + texture(macro_c_10, vec2(0.5)).r
                   + texture(macro_h_01, vec2(0.5)).r + texture(macro_r_01, vec2(0.5)).r + texture(macro_c_01, vec2(0.5)).r
                   + texture(macro_h_11, vec2(0.5)).r + texture(macro_r_11, vec2(0.5)).r + texture(macro_c_11, vec2(0.5)).r;
        h += keep * 0.0;
    }

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
