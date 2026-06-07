# M2.4c — Macro-Cache Terrain (Approach C) Design

Date: 2026-06-07
Status: DESIGN — pending spec review, then writing-plans.
Context: the M2.4b per-cell oracle was integrated + walk-tested + FAILED (sharp
analytic features alias at coarse LOD into ~1km walls; a per-cell field cannot do
the neighbor-smoothing the WG10 window-port relies on). Human chose Branch 3:
escalate to Approach C. See DRIFT_LOG 2026-06-07 and
`docs/superpowers/specs/2026-06-06-m2-4b-oracle-validation-and-integration-design.md`.

## The idea in one sentence

Give the live field a TWO-LAYER structure: a CACHED MACRO layer (the proven
window-port's blur + flow routing, computed off-frame per super-region and cached
in RAM) plus the existing PER-CELL detail layer — so the smoothed, neighbor-aware,
LOD-stable ranges/valleys/drainage that made the window-port read well are
available to the live infinite world, with cheap per-cell detail on top.

## Why this, and why it is feasible (measured)

The M2.4b walk-test proved a per-cell field can't produce the window-port look: the
blur + flow routing are NEIGHBOR operations a stateless per-cell shader can't do, so
the oracle's sharp analytic substitutes aliased into 1km walls at coarse LOD
(coarse-LOD max step 1076m vs M2.3's 482m).

Feasibility was diagnosed with real numbers before committing:

- A naive "apron per fine page" pipeline is INFEASIBLE: the window-port's blur is
  WORLD-ANCHORED (sigma covers a fixed ~5.12km regardless of LOD spacing). At the
  fine level (4m/cell) that apron is 1280 cells each side -> a 128² core needs a
  2688² padded compute = 441x overhead PER PAGE. Dead on arrival.
- The MACRO bake is the feasible shape: compute the window-port ONCE per ~30km
  super-region at COARSE spacing, cache it, let fine pages sample it. Measured CPU
  bake (release, 1 thread, existing `generate_seamsafe_fields`, flow_on):
  - 256m spacing (118² core): **20 ms**
  - 128m spacing (235² core): **87 ms**
  - 64m spacing (469² core): **358 ms**
- Cache footprint is small (7 structural fields per region):
  - 256m: ~0.37 MB/region -> a 450km prefetch ring (225 regions) = ~84 MB
  - 128m: ~1.5 MB/region  -> a 330km ring (121 regions) = ~178 MB
- The bake runs OFF the render frame. It does NOT spend the ~8ms frame budget; the
  8ms only pays for per-frame SAMPLING (a couple of bilinear reads + the existing
  detail noise — strictly cheaper than the oracle's analytic channel fields, which
  already ran at ~4ms/240fps).

So the feasible architecture is the opposite of the first intuition: the "ambitious"
regional cache is cheap and gives globally-connected drainage; the "pragmatic"
per-page apron is the impossible one.

## Live + procedural + infinite (NOT a disk bake)

"Bake" here = compute-once-and-cache-in-RAM, exactly like the existing PagePool
caches GPU pages. It is NOT a pre-built world file. Every macro region is computed
on demand from `seed + region coord`, deterministically, at runtime. Nothing is read
from disk. The procedural invariant from the M2.4b spec holds: every value is a pure
function of (seed, world coords); DEMs inform code constants only. Determinism makes
cache eviction safe — an evicted region rebuilds identically when revisited.

## Bake engine decision: CPU worker (GPU deferred)

CHOSEN: bake on a `WorkerThreadPool` thread, reusing the EXISTING, tested window-port
(`structural_scaffold::recipes::mountain::generate_seamsafe_fields`) verbatim.

Rationale (measured + pillar-driven):
- The bake is OFF-frame, so per-bake speed costs wall-clock latency-until-ready, not
  the 8ms budget. The coarse never-black blanket covers until a region is ready;
  prefetch makes misses rare.
- Flow accumulation is iterative/whole-grid — naturally a CPU array algorithm,
  awkward and risky to port to GPU ping-pong dispatches.
- The CPU code already exists, is fixture-tested, and is literally the look the human
  liked. GPU would re-derive all of it in GLSL (the M2.4b oracle-port pain, 5x bigger,
  plus the iterative-flow hazard) — the "big risky rebuild" pattern that killed
  attempts #1-12.
- 20-90ms off-frame at the macro spacings that matter is well within a prefetch budget.

GPU multi-pass bake is DEFERRED, not rejected: if real flythrough shows bake latency
hurts (blanket visible too long when flying fast into fresh regions), the bake engine
can be swapped to GPU later — the cache/sample architecture is identical either way.
This is the "CPU now, GPU later if needed" safety valve.

## Architecture (two-layer field)

```
seed + region coord
  -> MacroBake (off-frame worker): window-port blur + flow routing on a coarse
     padded grid -> RegionMacro {height, range_mask, channel/discharge, pass_floor,
     massif, material hints} for that region
  -> RegionCache (bounded LRU, RAM): baked regions keyed by (rx, rz); deterministic
  -> macro uploaded as GPU texture(s); field_height.glsl macro_sample(world_xz)
     bilinear-reads it
  -> height = macro.height + per_cell_detail(world_xz); macro.range/channel/etc.
     exposed for biome/material use
  -> height/climate/biome/collision consume it exactly as today (height = channel 0)
```

Macro answers "what's the km-scale structure here" (the neighbor-smoothed part a
per-cell field can't make). Per-cell adds the fine roughness walked on. This is the
WG10 lesson made live: structure baked at macro scale, height assembled per-cell from
it, detail on top.

## Components (one job each, clean interfaces)

1. **MacroBake (Rust, pure compute)** — `bake_region(seed, rx, rz, cfg) -> RegionMacro`.
   Runs the existing `generate_seamsafe_fields` on a coarse padded grid, crops apron,
   returns flat f32 field arrays. No I/O, no engine state. Reuses proven terrain math
   (no new terrain math). Testable for determinism + seam agreement.

2. **RegionCache (Rust, bounded LRU)** — `get/insert/contains/evict_lru`, keyed by
   (rx,rz), tunable cap. Pure data structure; deterministic rebuild makes eviction
   safe. Mirrors the existing PagePool cache pattern.

3. **BakeScheduler (Rust, off-frame orchestration + prefetch)** — decides which
   regions to bake and when: (a) on-demand on a page miss; (b) background prefetch of
   a tunable ring ahead of the play frontier; (c) a callable `prefetch_ring(center,
   radius)` for loading-screen pre-bake. Runs bakes on WorkerThreadPool; inserts into
   RegionCache on completion (deferred to main thread). The only unit that touches
   threading.

4. **Macro upload + sample (Rust->GPU bridge + GLSL)** — a cached RegionMacro is
   uploaded as GPU texture(s) (one per field or packed); `macro_sample(world_xz)` in
   field_height.glsl bilinear-reads the region texture for this world point; the field
   assembles `height = macro.height + detail(...)`. Field only READS the macro; never
   bakes. THE one genuinely new/risky piece — prototype first.

5. **terrain_mode integration (REUSES the oracle work)** — the B-key toggle,
   terrain_mode param, set_terrain_mode/clear_cache, collision contract are already in
   place. C plugs in as a new terrain_mode value; REFERENCE (M2.3) stays the toggle
   comparison baseline; the per-cell oracle (mode 1) may stay for comparison or retire.

Boundary chain (each layer testable alone): bake (pure) -> cache (pure data) ->
scheduler (threading) -> upload/sample (GPU read) -> field (consumer).

## Data flow

HIT (region cached): page needs height at P -> region of P -> RegionCache hit ->
region macro textures resident on GPU -> macro_sample(P) bilinear read ->
height = macro.height + detail(P). In-frame, cheap.

MISS (not cached): RegionCache miss -> BakeScheduler.request_region -> page falls back
to the coarse never-black blanket (or M2.3 reference height) meanwhile -> bake
completes off-frame (~20-90ms) -> cached + uploaded -> next frames sample the real
macro. Prefetch makes misses rare in normal play.

THE HARD PART (flagged, prototyped first): getting cached macro from Rust RAM to
GPU-samplable per page. (a) Upload: one texture create/upload per region on bake
completion (off-frame, standard). (b) Which region texture a page binds: a page binds
the region its center falls in; the bake's APRON already overlaps neighbors (what
makes it seam-safe), so the region texture covers slightly past its core and the apron
covers boundary pages. Seam-safety is inherited from the window-port's apron, proven
by existing seam tests. Prototype this bridge (one region, one page) before building
the scheduler.

Everything downstream is unchanged: height is still channel 0 (collision reads it as
today); climate/biome read height additively (no circularity); page texture/contract
identical. C changes WHERE height comes from, not the contract around it.

## Tunables (data-driven; engine-not-a-game; defaults picked by visual gate)

bake_spacing (start ~256m), super_region_size (~30km), cache_cap (LRU bound),
prefetch_ring_radius, loading_screen_prefetch_radius, frontier_lookahead,
detail_amplitude/blend. All in WorldConfig/inspector, no hardcoded terrain values.

## Testing / gates

- Bake determinism + adjacent-region seam agreement (Rust unit; reuses existing
  seam-test machinery).
- Cache invariants (Rust unit): bounded size, LRU eviction, evicted-then-rebuilt
  identical.
- Live integration gate (GDScript): macro mode deterministic, finite, AND coarse-LOD
  adjacent step BOUNDED (the exact failure the oracle had — this gate proves C fixed
  it; compare to oracle's 1076m and M2.3's 482m).
- Regression: M2.1/M2.2/M2.3/m1_7c stay green; height/collision contract intact.
- THE REAL GATE: human fly AND walk at playable scale — believable smoothed
  ranges/valleys with connected drainage, NO 1km walls, traversable.

## Build sequence (each step independently green; risky part isolated early)

1. MacroBake + RegionCache in Rust (pure, unit-tested, NO GPU).
2. Upload + sample ONE region for ONE page (prove the GPU bridge — the risky part —
   before any scheduler complexity).
3. BakeScheduler: on-demand + background prefetch + never-black fallback.
4. Loading-screen prefetch ring API + tunables + the human fly/walk visual gate.

## Explicit non-goals

- No disk bake / pre-built world file (live procedural cache only).
- No abandoning per-cell detail (macro + detail, both).
- No change to the height/collision contract (height stays channel 0).
- No GPU bake engine in v1 (CPU worker; GPU is a deferred swap behind the same
  cache/sample architecture).
- No per-biome terrain recipes yet (still later, one biome at a time).
- No erosion (M6).

## Honest risk read

- The GPU bridge (component 4) is the one genuinely new/risky piece; isolated as
  build step 2 and prototyped before the scheduler so failure is cheap.
- Bake latency under fast flight is the open empirical question; mitigated by prefetch
  + never-black fallback, and the GPU-bake swap is the escape hatch if it bites.
- Everything else is either proven code (the window-port bake) or a standard
  bounded-cache/worker pattern this codebase already uses.
- This is milestone-scale, bigger than the oracle bite — sequenced so each step is
  green and the foundation bears the next (the ordering rule that kept attempts #1-12
  from repeating).
