# M2.6 perf — GPU-resident rendering + collision-only readback

**Date:** 2026-06-07
**Status:** design, awaiting user review
**Trigger:** the M2.4 seam fix (analytic normal) exposed and worsened a pre-existing
streaming-burst hitch. Profiling (this session) showed the dominant cost is the
per-page synchronous GPU round-trip, not the seam fix's math. User chose the full
M2.6 perf pass now. Target: **smooth on the RTX 3070 — streaming/motion as smooth
as stationary.**

## Root cause (measured, not assumed)

Per produced page, `FieldGpu::dispatch_page` does, on the main thread, serialized:
dispatch (local RenderingDevice) → **`rd.sync()` blocks** (~130 us) → `buffer_get_data`
readback (~130 us) → then `page_pool::produce` builds **4 ImageTextures** (~56 us each
≈ 224 us) and uploads them. In a streaming BURST (many pages in one frame) these
serialize: N × ~640 us. The steady-state m1_6 gate never bursts, so it showed 1.4 ms
p99 while a turbo+jump burst probe showed p99 26 ms / max 43 ms. Split timing proved
sync ≈ readback ≈ equal; the whole synchronous round-trip is the cost.

**Key insight:** for RENDERING, the round-trip is pure waste. The display shader only
SAMPLES textures; producing on the GPU, reading to CPU, then re-uploading as a texture
is GPU→CPU→GPU for no reason. Only COLLISION (M1.7 `HeightMapShape`) needs CPU heights,
and only for the ~25 near level-0 pages — not the hundreds of coarse render pages.

## Approach (chosen — pillar call, user-delegated)

Split the one conflated production path into two honest paths:

1. **Render path = GPU-resident.** A compute pass on the **main** RenderingDevice
   (`RenderingServer.get_rendering_device()`) writes height/climate/normal into GPU
   textures. Each page material samples them via **`Texture2DRD`** (verified present
   in Godot 4.6: `texture_rd_rid` / `set_texture_rd_rid()`; "a 2D texture created
   directly on the RenderingDevice as a texture for materials"). No sync, no readback,
   no re-upload. Applies to ALL levels.
2. **Collision path = CPU readback, near only.** For level-0 pages within
   `collision_radius`, read back the HEIGHT channel only for the `HeightMapShape`
   (M1.7). Async — the collision body build already runs off the main thread via
   WorkerThreadPool. ~25 pages, not hundreds.

Why (pillars): Quality — removes the cost at its root (no wasteful round-trip for
render data) rather than hiding it. Survivability — never-black + M1.7 preserved
(collision still gets real CPU heights; render just stops needing them). Modularity —
separates two genuinely different concerns. Performance — the largest possible win and
it SCALES (heavier future fields/erosion/materials add no readback cost to rendering).

## Honest risks (and mitigations)

- **Production moves local device → main device.** Heavy compute on the main device
  can itself cost frame time if not spread. Mitigation: keep the existing per-frame
  page caps (`max_eager_per_frame`/`max_new_per_frame`); measure with the new burst
  gate at every stage; the dispatch is cheap vs the sync we're removing.
- **Manual RID lifetime.** RenderingDevice textures are NOT ref-counted (unlike
  `ImageTexture`). The pool MUST free each page's texture RIDs on evict or VRAM leaks.
  Mitigation: a dedicated free-on-evict path + a VRAM-stability gate (stream many
  pages, assert VRAM returns to a flat baseline).
- **Two production paths.** More surface area. Mitigation: both call the SAME GLSL
  (one field source of truth); the collision path is a thin height-only readback of
  the same dispatch, not a second field.
- **This is M1-foundational code.** Mitigation: STAGED (below), each stage gated +
  human-felt + committed; collision path left untouched until rendering is proven.

## Staging (4 gated stages — each: build → gate green → human feel → commit)

### Stage 0 — Reliable burst perf gate (FIRST, nothing ships without it)
Single-run burst timing was too noisy (same build varied 3–25 over-budget frames).
Build `m2_6_burst_perf_check.gd`: deterministic fixed-step turbo motion + fixed jump
pattern + warmup, run the burst, AND repeat the burst N times reporting the AGGREGATE
worst sustained frame (e.g. median-of-maxes across repeats, or 99.9th percentile over
all frames) so it's stable enough to A/B. Establish the CURRENT (committed seam-fix)
baseline number as the regression reference. This gate is the measuring stick for
stages 1–3.

### Stage 1 — GPU-resident render textures (render only; collision untouched)
Add a main-device compute path producing the page's height/climate/normal into GPU
textures wrapped as `Texture2DRD`, bound to the page material. KEEP the existing
local-device readback + ImageTexture path feeding COLLISION exactly as-is (so
collision is never at risk while rendering moves). Gate: burst gate improves vs
baseline; m1_4/m1_7c/m2_1/m2_2/m2_3 still PASS; human feel-check (smooth + seam still
gone + shape unchanged). NOTE: this stage temporarily does BOTH (GPU render + CPU
collision readback for all near pages) — perf win comes from render no longer
blocking; full win lands in stage 2.

### Stage 2 — Trim collision readback to near level-0 only
Stop reading back / building CPU arrays for pages that don't need collision (all
coarse + far pages). Only level-0 within `collision_radius` read back the height
channel. Gate: burst gate improves further; m1_7c PASS (collision intact); never-black
intact; human feel.

### Stage 3 — Free RIDs on evict + VRAM-stability gate
Ensure every page's `Texture2DRD` RIDs are freed when the page evicts. Gate:
`m2_6_vram_check.gd` streams a large area and asserts VRAM/texture count returns to a
flat baseline (no leak). Human: long flight, watch HUD `vram` stays bounded.

## Acceptance (the whole pass)
- Burst gate: worst sustained frame within budget on the dev machine, AND estimated/
  reasoned acceptable for the RTX 3070 min target (the stated bar: streaming ≈ as
  smooth as stationary).
- All existing gates green (m1_4, m1_5c, m1_6, m1_7c, m2_1, m2_2, m2_3).
- No VRAM leak (m2_6_vram_check).
- Human feel-check PASS: fly low + fast, no streaming hitch; seam still gone; shape
  unchanged. (User has deuteranopia — judge by shape/shading/smoothness, not color.)

## Out of scope
- Terrain shape, materials, DEM-direct (the user's chosen NEXT track after perf).
- The async page-production "double buffer" variant — superseded by GPU-resident
  (which removes the readback entirely for render, a higher ceiling).

## Rollback discipline
Each stage is its own commit on `main` (project norm). If a stage fails its gate or
human feel, REVERT that stage's commit (don't stack a fix), reassess. Stages 1–3 are
ordered so collision (the safety-critical path) is the LAST thing touched.
