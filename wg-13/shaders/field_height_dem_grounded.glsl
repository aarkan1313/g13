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

layout(set = 0, binding = 6, std430) restrict readonly buffer DemKernel {
    // x enabled, y square kernel size, z review footprint in metres, w source relief.
    vec4 dem_meta0;
    // x height contribution in metres, remaining channels reserved.
    vec4 dem_meta1;
    float dem_values[];
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

float dem_kernel_texel(int size, int x, int y) {
    x = clamp(x, 0, size - 1);
    y = clamp(y, 0, size - 1);
    return dem_values[y * size + x];
}

float dem_kernel_lookup(int size, vec2 uv) {
    uv = clamp(uv, vec2(0.0), vec2(1.0));
    vec2 p = uv * float(size - 1);
    ivec2 i0 = ivec2(floor(p));
    ivec2 i1 = min(i0 + ivec2(1), ivec2(size - 1));
    vec2 f = fract(p);
    float a = dem_kernel_texel(size, i0.x, i0.y);
    float b = dem_kernel_texel(size, i1.x, i0.y);
    float c = dem_kernel_texel(size, i0.x, i1.y);
    float d = dem_kernel_texel(size, i1.x, i1.y);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float dem_kernel_cell_sample(vec2 world_xz, ivec2 cell, uint seed, int size, float footprint) {
    float angle = hash2(cell + ivec2(101, 203), seed ^ 0x44454d21u) * 6.2831853;
    float scale = mix(0.82, 1.28, hash2(cell + ivec2(41, 83), seed ^ 0x5343414cu));
    mat2 rot = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    vec2 centre = (vec2(cell) + vec2(0.5)) * footprint;
    vec2 uv = (rot * (world_xz - centre)) / (footprint * scale) + vec2(0.5);

    // Soft apron prevents hard atlas edges without requiring tileable DEM patches.
    vec2 lo = smoothstep(vec2(-0.08), vec2(0.12), uv);
    vec2 hi = smoothstep(vec2(-0.08), vec2(0.12), vec2(1.0) - uv);
    float apron = lo.x * lo.y * hi.x * hi.y;
    return dem_kernel_lookup(size, uv) * apron;
}

float dem_kernel_sample(vec2 world_xz, uint seed) {
    if (dem_meta0.x < 0.5) {
        return 0.0;
    }
    int size = max(2, int(dem_meta0.y + 0.5));
    float footprint = max(dem_meta0.z, 1.0);
    vec2 g = world_xz / footprint;
    ivec2 base = ivec2(floor(g));
    vec2 f = vec2(fade(fract(g.x)), fade(fract(g.y)));

    float a = dem_kernel_cell_sample(world_xz, base, seed, size, footprint);
    float b = dem_kernel_cell_sample(world_xz, base + ivec2(1, 0), seed, size, footprint);
    float c = dem_kernel_cell_sample(world_xz, base + ivec2(0, 1), seed, size, footprint);
    float d = dem_kernel_cell_sample(world_xz, base + ivec2(1, 1), seed, size, footprint);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
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

float segment_distance(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - (a + ab * t));
}

vec2 cell_rand2(ivec2 cell, uint seed, uint salt) {
    return vec2(
        hash2(cell + ivec2(17, 29), seed ^ salt),
        hash2(cell + ivec2(71, 43), seed ^ (salt + 0x9e3779b9u))
    );
}

// Bounded deterministic feature query. This is the runtime stand-in for
// DEM-extracted ridge/valley/drainage structure: each macro cell owns a few
// ridge/channel segments, and pages query neighbor cells so the answer is
// independent of page boundaries.
vec2 ridge_drainage_graph(vec2 world_xz, uint seed) {
    const float CELL = 5200.0;
    ivec2 base_cell = ivec2(floor(world_xz / CELL));
    float ridge = 0.0;
    float channel = 0.0;

    for (int oz = -1; oz <= 1; oz++) {
        for (int ox = -1; ox <= 1; ox++) {
            ivec2 c = base_cell + ivec2(ox, oz);
            vec2 origin = vec2(c) * CELL;

            vec2 rr = cell_rand2(c, seed, 0x52494447u); // "RIDG"
            float angle = rr.x * 6.2831853;
            float len = mix(0.65, 1.45, rr.y) * CELL;
            vec2 centre = origin + (cell_rand2(c, seed, 0x43454e54u) * 0.7 + 0.15) * CELL;
            vec2 dir = vec2(cos(angle), sin(angle));
            float r_width = mix(180.0, 420.0, hash2(c + ivec2(5, 11), seed ^ 0x57494454u));
            float r_amp = mix(0.35, 1.0, hash2(c + ivec2(9, 31), seed ^ 0x52414d50u));
            float rd = segment_distance(world_xz, centre - dir * len, centre + dir * len);
            float crest = exp(-pow(rd / r_width, 2.0));
            float shoulder = 0.38 * exp(-pow(rd / (r_width * 3.4), 2.0));
            ridge = max(ridge, (crest + shoulder) * r_amp);

            vec2 cr = cell_rand2(c, seed, 0x4348414eu); // "CHAN"
            float c_angle = angle + mix(0.9, 1.7, cr.x);
            vec2 cdir = vec2(cos(c_angle), sin(c_angle));
            vec2 ccentre = origin + (cell_rand2(c, seed, 0x464c4f57u) * 0.82 + 0.09) * CELL;
            float c_len = mix(0.85, 1.65, cr.y) * CELL;
            float c_width = mix(150.0, 520.0, hash2(c + ivec2(19, 7), seed ^ 0x43574944u));
            float order = mix(0.7, 1.55, hash2(c + ivec2(23, 37), seed ^ 0x4f524452u));
            float cd = segment_distance(world_xz, ccentre - cdir * c_len, ccentre + cdir * c_len);
            float floor = exp(-pow(cd / c_width, 2.0));
            float valley = 0.55 * exp(-pow(cd / (c_width * 4.0), 2.0));
            channel = max(channel, (floor + valley) * order);
        }
    }

    return vec2(clamp(ridge, 0.0, 1.35), clamp(channel, 0.0, 1.55));
}

float dem_like_residual(vec2 world_xz, uint seed, float high_mask, float channel) {
    float relief = clamp(high_mask + channel * 0.25, 0.0, 1.0);
    float aligned = ridged_fbm(domain_warp(world_xz, seed ^ 0x52455331u, 480.0, 0.00038) * 0.0018,
                               seed ^ 0x52455332u, 4u, 2.04, 0.50);
    float rough = value_fbm(world_xz * 0.0019, seed ^ 0x524f5547u, 4u, 2.0, 0.50) - 0.5;
    float gully = ridged_fbm(world_xz * 0.0030 + vec2(channel * 0.7, high_mask * 0.4),
                             seed ^ 0x47554c4cu, 3u, 2.0, 0.48);
    float detail = (aligned - 0.45) * 72.0 + rough * 58.0 + (gully - 0.52) * channel * 78.0;
    return detail * mix(0.18, 0.95, relief);
}

// Review candidate: keep M2.3's infinite world scaffold, but make the compact
// DEM kernel the dominant highland morphology. The procedural scaffold decides
// where mountain provinces, basins, and drainage live; the DEM kernel supplies
// the measured ridge/valley texture without loading raw DEMs at runtime.
float composition_height(vec2 world_xz, uint seed) {
    const float WARP_AMOUNT = 2300.0;
    const float WARP_FREQ   = 0.000040;
    const float UPLIFT_FREQ = 0.000024;

    vec2 warp = domain_warp(world_xz, seed, WARP_AMOUNT, WARP_FREQ);
    float uplift = uplift_field(warp, seed, UPLIFT_FREQ, 0.45, 0.70);

    float regional = (value_fbm(world_xz * 0.000085, seed ^ 0x42415345u, 4u, 2.0, 0.5) - 0.44) * 420.0;
    float rolling = (value_fbm(world_xz * 0.00033, seed ^ 0x524f4c4cu, 3u, 2.0, 0.5) - 0.5) * 125.0;

    float primary = ridged_fbm(warp * 0.00030, seed ^ 0x5052494du, 5u, 2.03, 0.55);
    vec2 detail_warp = domain_warp(world_xz, seed ^ 0x4445544cu, 950.0, 0.000075);
    float secondary = ridged_fbm(detail_warp * 0.00105, seed ^ 0x5345434eu, 4u, 2.06, 0.50);
    float range_body = smoothstep(0.28, 0.80, primary);
    float high_mask = clamp(uplift * range_body, 0.0, 1.0);

    float massif = smoothstep(0.36, 0.78,
        value_fbm(warp * 0.00017 + vec2(13.0, 29.0), seed ^ 0x4d415353u, 3u, 2.0, 0.52));
    float range_mass = uplift * (60.0 + 170.0 * massif + 125.0 * range_body);
    float ridge_relief = high_mask * (primary * 85.0 + pow(secondary, 1.25) * 70.0);
    float lowland_carve = valley_carve(uplift, 340.0);

    float dem_form = dem_kernel_sample(warp, seed);
    float dem_gain = dem_meta1.x;
    float dem_context = smoothstep(0.0, 0.64, uplift);
    float dem_peak = max(dem_form, 0.0);
    float dem_valley = max(-dem_form, 0.0);
    float dem_signed = sign(dem_form) * pow(abs(dem_form), 0.86);
    float dem_height = dem_context * dem_gain * (dem_signed * 0.72 + pow(dem_peak, 1.35) * 0.14);
    float dem_step = max(dem_meta0.z / max(dem_meta0.y, 2.0), 1.0) * 1.65;
    float dem_e = dem_kernel_sample(warp + vec2(dem_step, 0.0), seed);
    float dem_w = dem_kernel_sample(warp - vec2(dem_step, 0.0), seed);
    float dem_n = dem_kernel_sample(warp + vec2(0.0, dem_step), seed);
    float dem_s = dem_kernel_sample(warp - vec2(0.0, dem_step), seed);
    float dem_curvature = dem_form - (dem_e + dem_w + dem_n + dem_s) * 0.25;
    float dem_fine = dem_kernel_sample(warp * 1.82 + vec2(7300.0, -4100.0), seed ^ 0x46494e45u);
    float dem_fine_detail = sign(dem_fine) * pow(abs(dem_fine), 1.15) * dem_gain * dem_context * 0.08;
    float dem_texture = dem_curvature * dem_gain * dem_context * 0.42 + dem_fine_detail;

    vec2 graph = ridge_drainage_graph(world_xz, seed);
    float graph_ridge = graph.x * high_mask;
    float graph_channel = graph.y;

    // Wide, smooth synthetic drainage: this should read as connected valley
    // organization from altitude, not as pasted linework or rectangular DEM seams.
    vec2 drain_warp = domain_warp(world_xz, seed ^ 0x464c4f57u, 1700.0, 0.000050);
    float drain_raw = ridged_fbm(drain_warp * 0.00021 + vec2(19.0, 7.0),
                                 seed ^ 0x4348414eu, 4u, 2.08, 0.53);
    float channel = smoothstep(0.58, 0.90, drain_raw);
    float valley_context = smoothstep(0.10, 0.74, uplift) * (1.0 - smoothstep(0.68, 1.0, range_body));
    float channel_carve = (channel + graph_channel * 0.42) * valley_context * mix(100.0, 340.0, uplift);
    float dem_carve = dem_valley * dem_gain * mix(0.10, 0.34, dem_context);

    float residual = dem_like_residual(world_xz, seed, high_mask, channel * valley_context) * 0.45;

    return regional + rolling + range_mass + ridge_relief + graph_ridge * 190.0 + dem_height + dem_texture
           - lowland_carve - channel_carve - dem_carve + residual;
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
