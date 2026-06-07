# M2.4b Oracle -> GLSL Port Map

Translation source of truth for porting `structural_scaffold::synthesize_cell`
(`rust/structural_scaffold/src/lib.rs`) into `wg-13/shaders/field_height.glsl`
as `oracle_height()`. Every ported fn is `osc_`-prefixed to avoid colliding with
the M2.3 / climate / biome functions already in the shader.

## KEY DECISION: hash strategy (32-bit, not bit-exact 64-bit)

The Rust oracle uses `u64` seeds + a 64-bit splitmix `mix64`. GLSL 450 in Godot's
Vulkan path has NO verified 64-bit int support (no existing int64 use in any
shader; relying on GL_ARB_gpu_shader_int64 is unverified, and uvec2 emulation is
error-prone).

DECISION (pillars: build-it-right-once, don't over-engineer): port the oracle's
STRUCTURE faithfully (all segment/range/channel/fbm logic, ALL constants,
frequencies, octaves, style params) but seed it with a clean 32-bit hash adapted
to GLSL (the shader's proven `hash_u` family), NOT a bit-exact `mix64` emulation.

WHY this is correct, not a shortcut:
- The reviewed static sheet was INCONCLUSIVE; we integrate to get a walk-test,
  which is the real gate. A pixel-exact match to an inconclusive artifact buys
  nothing.
- The hash is only the noise SOURCE. Same algorithm + same constants + an
  equally-uniform hash => a statistical twin of the reviewed oracle (same range
  spacing, valley structure, character), which is exactly what we need to walk.
- The Task 6 gate therefore asserts mode-1 is deterministic + finite + non-flat +
  distinct-from-mode-0, NOT GLSL==Rust bit-equality (that was the plan's
  documented fallback; we adopt it as primary, recorded here).

CONSEQUENCE: the live oracle terrain is a close cousin of, not identical to,
`m2_4b_scaffold_oracle_3d.json`. Acceptable and expected.

## Hash primitives to add (32-bit)

Reuse the shader's existing `hash_u(uint)` (splitmix-ish, line 75). Add:

- `osc_hash2(ivec2 p, uint seed) -> uint` : like the shader's existing `hash2`
  but returns the raw uint (we need a few salted variants).
- `osc_rand01(int x, int z, uint seed, uint salt) -> float` : mirror `rand01_i`'s
  ROLE (deterministic [0,1) from lattice point + seed + salt). Impl:
  `uint h = hash_u(uint(x)*0x9e3779b9u ^ hash_u(uint(z)*0x85ebca6bu ^ hash_u(seed ^ salt*0x68bc21ebu))); return float(h)*(1.0/4294967296.0);`
- `osc_value_noise(vec2 p, float freq, uint seed, uint salt) -> float` : scale p by
  freq, floor to lattice, smootherstep-interp 4 `osc_rand01` corners (salt threaded
  to all 4). Mirror Rust `value_noise` (salt 0 there; we thread a salt so different
  callers decorrelate, matching how Rust XORs different seeds per caller).

NOTE: Rust threads decorrelation via `seed ^ CONST` per call (u64). In GLSL we fold
that CONST into `seed` the same way (`seed ^ CONSTu`), truncated to 32-bit. The
CONSTs (e.g. 0x5198f00d, 0xf137d00d) are already 32-bit in the Rust source, so the
XOR truncation is lossless for the constant; only the base `seed` is 32-bit-folded.

## Functions to port (Rust lib.rs -> GLSL osc_*)

For each: same body, same constants, GLSL syntax, `osc_` prefix, 32-bit seed.

1. `mix64` -> NOT ported (replaced by hash_u, per decision above).
2. `rand01_i(seed,x,z,salt)` -> `osc_rand01(x,z,seed,salt)` (32-bit, above).
3. `value_noise(seed,x,z,freq)` -> `osc_value_noise(p,freq,seed,salt)`.
4. `fbm(seed,x,z,freq,oct,lac,gain)` -> `osc_fbm(p,freq,oct,lac,gain,seed,salt)`:
   loop oct: `sum += osc_value_noise(p, f, seed, salt ^ (octave+1)*0x9e3779b9u) * amp;
   norm += amp; amp *= gain; f *= lac;` return `sum/max(norm,1e-6)`. (Rust XORs
   `(octave+1)*K` into seed; we XOR into salt — equivalent decorrelation.)
5. `ridged_fbm(seed,x,z,freq,oct)` -> `osc_ridged_fbm(p,freq,oct,seed,salt)`:
   amp=0.55, f=freq, prev=1.0; loop: `n=osc_value_noise(...salt^((oct+3)*0x68bc21eb));
   r=1-abs(2n-1); rounded=smoothstep(0.08,0.92,r); weighted=rounded*(0.58+prev*0.42);
   sum+=weighted*amp; norm+=amp; prev=rounded; amp*=0.52; f*=2.04;` return sum/max(norm,1e-6).
6. `rotate2(x,z,angle)` -> `osc_rotate2(vec2,float) -> vec2` (cos/sin matrix).
7. `point_segment_distance(px,pz,ax,az,bx,bz)` -> `osc_point_seg_dist(vec2 p, vec2 a, vec2 b) -> float` (clamp-t projection).
8. `smoothstep(e0,e1,x)` -> GLSL builtin `smoothstep` (identical formula). USE BUILTIN.
9. `smootherstep(x)` -> `osc_smootherstep(float)` (t*t*t*(t*(t*6-15)+10), clamp first).
10. `lerp` -> GLSL `mix`. USE BUILTIN.
11. `style_at(seed,x,z) -> (StyleId,weight)` -> `osc_style_at(vec2,uint) -> vec2`
    (.x = style id 0..3 as float, .y = weight). signal = osc_fbm(p, 1/140000, 3, 2.0, 0.55);
    scaled = clamp(signal*4, 0, 3.999); id = floor(scaled); center=id+0.5;
    weight = clamp(1 - abs(scaled-center)*2, 0, 1).
12. `style_params(style)` -> `osc_style_params(int) -> StyleParams` GLSL struct holding
    the 13 f32 fields. Port all 4 rows EXACTLY (AlpineBranching/SierraBlock/PamirChain/
    DissectedHighlands constants from lib.rs 463-526).
13. `domain_warp(seed,style,x,z)` -> `osc_domain_warp(vec2,int,uint) -> vec2`:
    amount by style (3200/2200/1450/3650 — note Rust match order: Sierra 2200,
    Pamir 1450, Alpine 3200, Dissected 3650). dx = (osc_fbm(p,1/58000,3,2,0.55)-0.5)*amount;
    dz = (osc_fbm(p,1/61000,3,2,0.55)-0.5)*amount (different salt). return p+vec2(dx,dz).
14. `range_field(seed,style,params,x,z)` -> `osc_range_field(...) -> RangeField struct`
    {envelope, massif, ridge_axis, ridge_distance_m}. The 5x5 cell loop over
    `osc_range_segment`, gaussian envelope/ridge by distance, regional fbm blend,
    massif. Port lib.rs 540-579 exactly. lane_count: Alpine/Dissected=3, else 2.
15. `range_segment(seed,style,params,gx,gz,lane)` -> `osc_range_segment(...) -> Segment`
    {ax,az,bx,bz,weight}. center from rand01, coherent value_noise, angle from
    style_bias + coherent/local blend, length from rand01. Port lib.rs 581-612.
    style_bias TAU multipliers: Alpine 0.16, Sierra 0.08, Pamir 0.28, Dissected 0.20.
16. `primary_channel_distance(seed,style,params,x,z)` -> `osc_primary_channel_dist(...)`:
    angle by style (Alpine 0.36, Sierra 0.72, Pamir 1.42, Dissected 0.98) + jitter,
    rotate, k0 lane loop, sine-curve `curve`, min |v-curve|. Port lib.rs 614-637.
17. `tributary_channel_distance(...)` -> `osc_tributary_channel_dist(...)`: 5x5 cell
    loop, segment per cell, min point-seg dist. Port lib.rs 639-680. style_turn:
    Alpine 0.35, Sierra 0.18, Pamir 0.50, Dissected 0.72.
18. `synthesize_cell` height assembly -> `oracle_height(vec2 world_xz, uint seed)`:
    style_at -> style_params -> domain_warp -> range_field -> channel distances ->
    masks (primary/tributary/channel/carve/pass) -> base/regional_lift/ridge_texture/
    near_detail/ridge_micro/branch_detail -> massif_height/ridge_height/carve/pass_cut/
    lowland_smooth -> preview_height_m (lib.rs 432-436). RETURN that float.

## Structs needed in GLSL (plain structs, value-returned)

```glsl
struct OscStyleParams { float range_cell_m, range_width_m, ridge_width_m,
  range_len_min, range_len_max, relief_m, primary_spacing_m, primary_width_m,
  primary_amp_m, tributary_width_m, tributary_len_m, detail_amp_m, detail_freq; };
struct OscRangeField { float envelope, massif, ridge_axis, ridge_distance_m; };
struct OscSegment { float ax, az, bx, bz, weight; };
```

## Constants index (XOR salts used as 32-bit GLSL uint literals + u suffix)

From lib.rs (already 32-bit hex, lossless): 0x5198f00d, 0xf137d00d, 0x88ac4e21,
0x1c69b3f1, 0xa17e55ed, 0x5eaf1075, 0xa53c1f2d, 0x6d2b79f5, 0x61e72cad,
0x7311cafe, 0x1515a11a, 0x2d33cafe, 0x93ab41e9, 0x44c291af, 0xabc17133.
Octave mix consts: 0x9e3779b9, 0x68bc21eb, 0x85ebca6b.

## Verification

Task 6 gate asserts (per the hash decision): mode-1 deterministic + finite +
non-flat (spread over a threshold) + distinct from mode-0; mode-0 bit-identical to
the pre-integration M2.3 baseline. NOT GLSL==Rust bit-equality.
