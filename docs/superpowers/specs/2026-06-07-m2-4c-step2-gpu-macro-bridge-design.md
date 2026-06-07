# M2.4c Step 2 — GPU Macro Bridge (upload + sample) Design

Date: 2026-06-07
Status: DESIGN — pending spec review, then writing-plans.
Parent spec: `docs/superpowers/specs/2026-06-07-m2-4c-macro-cache-terrain-design.md` (Approach C).
Predecessor: step 1 (pure-Rust `crate::macro_cache`: MacroBake + RegionCache + RegionMacro) is DONE + pushed.

## Goal

Make the live per-cell field (`field_height.glsl`) able to SAMPLE the cached macro
layer, so `height = macro.height + per_cell_detail` produces the smoothed,
neighbor-aware, LOD-stable terrain the per-cell oracle structurally couldn't. This
is the one genuinely new/risky piece of Approach C: the bridge from a cached
`RegionMacro` (Rust RAM) onto FieldGpu's local RenderingDevice and into the compute
shader.

## Scope

Step 2 of 4. It proves the bridge works in the live world, SYNCHRONOUSLY (bake-on-
demand in `produce`, which will hitch when crossing into fresh regions). The async
scheduler + prefetch that removes the hitch is STEP 3 — designed for as a clean swap
seam here, not a rewrite. Step 4 = loading-screen prefetch + tunables + final visual
acceptance.

NOT in step 2: off-thread baking, prefetch, atlas management, per-biome style routing.

## Locked decisions (from brainstorm, pillar-driven)

1. **2x2 region binding.** A page binds the (up to 4) macro regions its world span
   touches; the shader selects the owning region per cell by world coord. Correct for
   ANY region/page size (infinite-safe), no reliance on apron-overlap coincidence
   (rejected the "bind 1 region, lean on apron" option as slop for an infinite world;
   deferred the "sliding atlas" option as premature). No blending needed at region
   borders — step 1's seam test proved adjacent regions agree to <1m, so it's
   SELECT-not-blend.
2. **R32F sampled textures + a linear sampler** on FieldGpu's local RenderingDevice
   (hardware bilinear). Required for quality: macro is coarse (~256m/cell) sampled by
   fine cells (down to 4m/cell), so without bilinear there'd be ~256m terraced steps.
   Hardware bilinear is exact, free, and reusable by M3 materials / M6 erosion. Chosen
   over storage-buffer+manual-bilinear on Quality + build-it-right-once, ACCEPTING that
   sampled textures are new mechanics in FieldGpu's compute dispatch (today it uses only
   STORAGE_BUFFER uniforms). That new-mechanics risk is isolated as the FIRST build task.
3. **Mode-gated additive height.** A new `terrain_mode` value (2 = MACRO_CACHE):
   `height = macro.height + per_cell_detail(world_xz)`. Detail reuses the existing cheap
   noise (NOT the oracle's sharp analytic channels). Non-destructive: M2.3 REFERENCE
   (mode 0) and the per-cell oracle (mode 1) stay as toggle comparisons.

## Data path

```
RegionCache (RAM, f32 fields)            [step 1, done]
  -> on cache-insert / first use: upload each sampled field as an R32F texture on
     FieldGpu's LOCAL RenderingDevice + a shared linear sampler -> GpuRegionMacro
     {one R32F texture RID per field, keyed by (rx,rz)}          [GPU-resident cache]
  -> dispatch_page(params, neighborhood): bind the page's 2x2 region textures as
     SAMPLER_WITH_TEXTURE uniforms (new bindings after the existing 0/1/2)
  -> field_height.glsl macro_sample(world_xz): pick the owning region, compute its
     local UV in [0,1], texture(field, uv) -> hardware bilinear
  -> height = macro.height + per_cell_detail(world_xz)   (terrain_mode == 2)
  -> readback as today (height = channel 0; collision/climate/biome unchanged)
```

GPU-side resident cache (critical): macro textures are created ONCE per region (first
use) and kept resident on the local RD, reused by every page touching that region. We
do NOT recreate textures per page dispatch. The GPU-resident map is bounded + evicted
in lockstep with the RAM RegionCache so they don't drift. Mirrors how PagePool keeps
resident page textures.

## Components

1. **GpuRegionMacro (Rust, new — `macro_gpu.rs` or in field_gpu.rs)** — one region's
   fields as R32F texture RIDs resident on the local RD, + (rx,rz) + resolution.
   `upload(rd, &RegionMacro, sampler) -> Self` creates the textures; `free(rd)` frees
   the RIDs on eviction (RD resources are manual-free, like the dispatch buffers).

2. **GPU-resident macro map (in FieldGpu)** — `HashMap<(i32,i32), GpuRegionMacro>` +
   one shared linear `sampler` RID created at init. Bounded; evicted in lockstep with
   RegionCache. Interface: `ensure_region(rd, &RegionMacro)` (upload if absent),
   `has_region(rx,rz)`, `evict_region(rx,rz)`. Lives in FieldGpu because it owns the RD.

3. **Macro-aware dispatch_page (extend field_gpu.rs)** — takes the page's 2x2 region
   neighborhood (4 (rx,rz) + their world origins + resolution, via PageParams or a small
   struct). Binds those regions' field textures as SAMPLER_WITH_TEXTURE uniforms at new
   bindings, dispatches, frees the UNIFORM SET after (NOT the cached textures). FALLBACK:
   if a neighborhood region isn't uploaded yet, bind a 1x1 placeholder + signal the
   shader to use REFERENCE height for cells in that region (never-black). In step 2 the
   synchronous bake means this rarely triggers; it exists so step 3's async path inherits
   it.

4. **macro_sample + height branch (field_height.glsl)** — `terrain_mode == 2`:
   `macro_sample(world_xz)` selects the owning region from the 4 bound (using their world
   origins + bake spacing in the params block), computes local UV, `texture(field, uv)`
   per needed field; `height = macro.height + per_cell_detail`. Params block carries the
   4 region origins + bake_spacing so the shader maps world->UV.

5. **Wiring (page_pool.rs + world_view.gd)** — `produce()` computes the 2x2
   neighborhood, calls `ensure_macro_neighborhood(regions)` (the step-3 swap seam — see
   below), uploads via `ensure_region`, passes the neighborhood to `dispatch_page`. The
   B-key toggle gains MACRO_CACHE mode.

## The step-3 swap seam (designed in now, not a rewrite later)

The "make these 4 regions ready" logic is isolated behind ONE function:
`ensure_macro_neighborhood(regions) -> Ready | Pending`.
- Step 2: always returns `Ready` — bakes any missing region SYNCHRONOUSLY (the
  temporary main-thread hitch, ~87ms at 128m), inserts to RegionCache, uploads to GPU.
- Step 3: returns `Pending` for not-yet-baked regions (queues an off-thread bake via
  the BakeScheduler); the dispatch uses the REFERENCE-fallback (component 3) for those
  cells until the bake lands. SAME call site, SAME fallback path — step 3 changes only
  what's behind this function. No rewrite.

## Synchronous-bake tradeoff (accepted, fixed in step 3)

Flying into unbaked territory stutters (synchronous ~20-90ms bake on the main thread).
This is DELIBERATE: step 2 proves correctness; step 3 moves the bake off-thread +
prefetches to remove the hitch. The user confirmed this is acceptable given step 3 fixes
it. Never-black still holds: the coarse blanket covers not-yet-produced pages, and the
per-region REFERENCE fallback covers any missing macro.

## Testing / gates

Output-provable (agent self-certifies):
- **GpuRegionMacro upload round-trip** (FIRST task — isolates the risky new mechanic):
  upload a known RegionMacro, sample it back via a tiny compute dispatch, assert sampled
  == source within bilinear tolerance. Proves the local-RD texture+sampler path works
  before anything else is built.
- MACRO_CACHE mode determinism: same page+seed -> bit-identical (GPU cache is a speed
  layer; output deterministic).
- NO-TERRACING gate: macro height across a fine page has SMOOTH max-adjacent-step (no
  ~256m blocky jumps) — proves hardware bilinear works (the quality decision paid off).
- 2x2 selection / seam: a page straddling a region boundary produces finite, seam-free
  height across the boundary (max adjacent step bounded — the exact thing the oracle
  failed at 1076m; compare against M2.3's 482m).
- Regression: M2.1/2.2/2.3/m1_7c + step-1 macro_cache unit tests stay green; REFERENCE
  (mode 0) bit-identical.

The real gate (human, parked): fly AND walk MACRO_CACHE at playable scale — believable
smoothed ranges/valleys + connected drainage, no terracing, no 1km walls, traversable.
Accepting the temporary fly-into-fresh-region hitch (step 3 fixes).

## Build sequence (risky mechanic first)

1. GpuRegionMacro + the local-RD texture/sampler upload + round-trip test (ISOLATE the
   one new mechanic; if the local-RD texture path fights, we find out cheaply here).
2. GPU-resident macro map on FieldGpu (ensure/has/evict, lockstep with RegionCache).
3. Macro-aware dispatch_page: bind 2x2 textures + the REFERENCE fallback for missing.
4. field_height.glsl: terrain_mode 2, macro_sample (region select + UV + texture),
   height = macro + detail; params block carries 4 region origins + bake_spacing.
5. page_pool wiring: compute neighborhood, ensure_macro_neighborhood (sync seam),
   pass to dispatch; world_view B-key MACRO_CACHE mode.
6. Gates (round-trip, determinism, no-terracing, seam, regression) + human fly/walk park.

## Explicit non-goals

- No off-thread baking / prefetch (step 3).
- No sliding macro atlas (rejected as premature; 2x2 binding is correct + simpler).
- No per-biome style routing (the bake is single-style until a later step).
- No change to the height/collision contract (height stays channel 0).
- No erosion (M6).

## Honest risk read

- The local-RD R32F texture + sampler + SAMPLER_WITH_TEXTURE uniform is the one new
  mechanic in FieldGpu's compute dispatch. Isolated as build task 1 (round-trip test) so
  failure is cheap and early. If it genuinely fights gdext 0.5.x, the documented fallback
  is storage-buffer + manual bilinear behind the same macro_sample interface (the shader-
  facing contract hides which) — but we go textures-first per the quality decision.
- Per-dispatch uniform-set churn grows (4 regions x N fields of texture binds). Bounded
  and cheap; the textures themselves are cached (created once per region), only the
  uniform SET is rebuilt per dispatch (as it already is today).
- Synchronous bake hitch — accepted, step 3 fixes via the designed swap seam.
