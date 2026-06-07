# M2.4b - DEM Structural Scaffold

## Status

Planning checkpoint after M2.4a failed visual review twice. This plan supersedes
the scalar DEM-character idea. Do not restart parameter tuning against
`dem_fingerprints.json` until this scaffold path has been evaluated.

Implementation checkpoint: Step 2/3 prototype exists in `rust/structural_scaffold`.
It generates deterministic CPU-only RegionFacts and writes
`wg-13/_captures/m2_4b_scaffold_review.png/.md` plus
`wg-13/_captures/m2_4b_scaffold_3d.json`. The first toy-line version was visually
wrong, so it was replaced with an adapted WG10 Rust recipe port: `recipe_noise`,
`array_ops`, and the mountain seam-safe synthesis pipeline now drive the scaffold
facts directly. The review sheet is aligned to the archived WG10 mountain
synthesis setup: seed `177`, 200 km span, four mountain styles, and WG10-style
hillshade.

3D review status: `wg-13/scenes/m2_4b_scaffold_3d_review.tscn` is a macro
concept proof and demonstrates promising structure, but it is too compressed and
unplayable as gameplay scale. `wg-13/scenes/m2_4b_scaffold_playable_scale_review.tscn`
is the current single-panel scale-calibration view. Gate
`m2_4b_scaffold_3d_check.gd` is green for both rendered scenes, and the
unit/workspace gate is green for determinism, adjacent-region seam agreement,
nontrivial drainage signal, and bounded finite values. Full
provenance/reproduction notes are in
`docs/superpowers/plans/2026-06-06-m2-4b-wg10-port-record.md`. This is not
runtime-integrated and not M2.4 visual acceptance.

## Diagnosis

M2.4a used DEM fingerprints as scalar controls for local ridge/detail/relief
knobs. That can change roughness, but it cannot create the organized geography
that makes DEM terrain read as real. It passed numeric gates and still produced
corduroy grooves and harsh parallel walls.

The WG10 mountain synthesis archive points at the better path:

- generate explicit range/channel/pass structure;
- carve height from those facts;
- review chunks/seams/player-eye views separately;
- keep reference, candidate, and diagnostic lanes distinct;
- promote by visual review, not by a green metric alone.

The important WG10 result was "baked", but the idea does not require a static
world. WG13 should make the bake procedural and deterministic: region facts are
computed from world coordinates + seed, cached, and sampled by runtime pages.

## Target Architecture

Runtime terrain should become:

```
world seed + region coord
  -> structural region fact generator
  -> cached RegionFact
  -> page producer samples RegionFact + field shader outputs
  -> renderer / collision / material overlays use the same facts
```

The facts are small, explicit terrain-structure layers:

- `range_mask`: where mountain/highland mass stands up.
- `ridge_axis` / `ridge_distance`: ridge skeleton or distance-to-ridge signal.
- `channel_mask` / `channel_distance`: valley/drainage/pass corridors.
- `pass_floor`: graded traversable corridor height where routes cross ranges.
- `style_id` / `style_weight`: morphology family such as alpine branching,
  sierra block, pamir chains, dissected highlands.
- `material_hints`: rock, snow, low-pass/valley floor hints for later surfaces.

Height assembly should demote noise to residual/detail:

```
h = uplift_macro
  + ridge_profile(distance_to_ridge, style)
  - valley_carve(distance_to_channel, pass_floor, style)
  + slope_aligned_detail(style, climate)
  + residual_noise(style)
```

## How DEMs Are Used

DEMs should not be copied into the game world and should not drive local scalar
knobs directly. They should train and validate the structural vocabulary:

- range width and ridge-valley spacing distributions;
- channel density and branching;
- orientation coherence / chain style;
- valley cross-section profiles;
- pass/corridor width and slope budgets;
- hypsometry and elevation percentile envelopes;
- style reference sheets for human visual comparison.

The current `dem_distill` output is still useful as a guardrail, but it is not
enough. It measures spectrum, slope, and ridge roughness. M2.4b needs structural
measurements and/or generated structural references.

## Biome / Climate Integration

Biomes remain the M2.2 classifier and skin. They should not become hard-coded
terrain recipes in M2.4b.

Climate and biome fields can influence structural facts as weights:

- temperature + elevation bias snow/rock/vegetation material hints;
- moisture biases drainage density, valley floor width, and erosion/detail
  strength;
- macro altitude helps choose range/highland/plain structural regions;
- biome id colors/materials the result and can gently modulate style weights.

The key rule: climate/biome may bias morphology, but structure still comes from
the scaffold. No per-biome branch that says "if biome == mountain, run a totally
separate generator" in this step.

## Procedural Region-Fact Plan

### Step 1 - Reference Analysis / Spec Lock

Use the WG10 mountain synthesis archive as the visual target set:

- `mountain_synthesis_200km.png`
- `mountain_synthesis_200km_debug.png`
- `mountain_network_oblique.png`
- `mountain_corridor_sheet.png`
- `mountain_world_chunks_3x3_seams.md`
- `mountain_network_chunks.json`

Output: a short WG13 structural scaffold spec with accepted style targets and
the required overlays.

### Step 2 - Rust Structural Oracle

Create a deterministic Rust oracle that produces one small region fact from:

- seed;
- region coordinate;
- style id;
- region span/resolution.

Initial oracle can be CPU-only. It must be seam-aware and unit-testable before
GPU acceleration. This is where route/carve/pass-network logic belongs.

Minimum proof:

- same seed+region -> identical facts;
- adjacent regions agree on borders or use an apron/super-region slice;
- pass/channel masks are connected enough to be useful;
- no runtime DEM file dependency.

### Step 3 - Static Review Harness

Before integrating the runtime page pool, render a static 3x3 or 9x9 review
payload like WG10:

- normal shaded terrain;
- range overlay;
- channel/pass overlay;
- seam guide mode;
- player-eye/fly review.

Current result: the static review harness exists as a 2D sheet plus two Godot 3D
review scenes. The macro scene is useful for judging structure, but its compressed
scale is not gameplay-ready. The playable-scale scene is the active calibration
surface before runtime integration. This is not final runtime acceptance. It is
the cheap visual filter that prevents bad structure from entering the live
clipmap.

### Step 4 - Runtime Candidate Lane

Add a candidate runtime mode separate from the accepted M2.3 baseline:

- `REFERENCE`: current M2.3 terrain, known visual baseline.
- `SCAFFOLD_CANDIDATE`: pages sampling generated region facts.
- `DIAGNOSTIC`: overlays for range/channel/pass/material facts.

Do not replace default terrain until the candidate has visual approval.

### Step 5 - Region Fact Cache / Worker

Adapt the WG10 RegionFact idea procedurally:

- compute super-region with apron;
- route/carve/condition it off the render frame;
- slice into region facts;
- cache facts in Rust;
- pages sample cached facts;
- use deterministic fallback while facts are pending.

GPU compute is appropriate for dense macro fields. Rust should own routing,
contracts, caches, and acceptance reports. Expensive readback is allowed only in
worker/off-frame paths.

## Gates

Test gates:

- structural oracle determinism;
- region seam/apron exactness;
- route connectivity / pass-network existence;
- fallback-to-fact upgrade does not violate page pool invariants;
- M2.1/M2.2/M2.3/M1.7c regressions remain green.

Visual gates:

- side-by-side with WG10 mountain synthesis references;
- overlays prove ranges/channels/passes are real facts;
- player-eye pass through/around mountains reads traversable at gameplay scale;
- same failed M2.4a hotspots are included once runtime-integrated;
- human visual pass before M2.4 is marked complete.

## Explicit Non-Goals

- No more scalar DEM knob tuning as the main plan.
- No static baked world as the final architecture.
- No runtime loading of large DEM files.
- No per-biome terrain recipe fork yet.
- No erosion simulation milestone yet, though this scaffold is designed to feed
  erosion later.

## Immediate Next Implementation Bite

UPDATE 2026-06-06: the per-cell oracle (`sample_cell`) has now been rendered and
reviewed (oracle review bite complete — see
`docs/superpowers/plans/2026-06-06-m2-4b-oracle-review-bite.md`). Static review was
INCONCLUSIVE: the oracle has real relief and renders, but reads flat at honest 64 km
playable scale, and the fly-only review scenes cannot judge walkability. So the
static-panel filter has hit its ceiling.

DECISION (human-confirmed, spec Branch 1 — see
`docs/superpowers/specs/2026-06-06-m2-4b-oracle-validation-and-integration-design.md`):
proceed to Step 4 (runtime candidate lane) NOW, integrating the oracle into live
`demo.tscn` as a toggleable candidate beside M2.3, so it can be FLOWN AND WALKED with
real collision and compared. Anchor rationale: this integration work is SHARED with
the deferred Approach C (window-based GPU pipeline) — the candidate toggle, the
Rust->shader param plumbing, the GLSL per-cell primitives, and the collision/biome
contract are all needed either way; only the analytic sine-curve channels (~20%) are
throwaway if C later proves necessary. ~40% the oracle walks well and C is skipped;
~60% it needs C, but entered then with a real walk-test as evidence (not a guess),
avoiding the attempt #1-12 "big risky rebuild on a hunch" failure mode.

RESOLVED 2026-06-07 — the integration plan was executed and the oracle walk-tested.
The per-cell oracle is now LIVE as a toggleable candidate (B key; terrain_mode
0=REFERENCE/1=SCAFFOLD_CANDIDATE). All output gates green. WALK-TEST FAILED:
persistent dark crater/walls + flat/wrong terrain. ROOT CAUSE (measured): the oracle
is spacing-independent but its coarse-LOD max adjacent step is 1076m vs M2.3's 482m —
its sharp analytic channel/carve features alias at coarse LOD into ~1km walls between
cells/LOD levels. A per-cell field can't do the Gaussian neighbor-smoothing that made
the WG10 window-port read well, so the per-cell approach structurally fights the
clipmap (same family as the M2.4a corduroy failure).

DECISION (human-confirmed Branch 3): ESCALATE to Approach C = the window-based GPU
pipeline. This is what Step 4/5 below (apron / super-region fact cache / off-frame
routing) were always pointing at. Approach C re-architects page production: super-
region apron, multi-pass GPU compute (blur + flow routing) seam-safe at every LOD,
collision reading the multi-pass field. It is a MILESTONE-SCALE step and needs its
own brainstorm + spec + plan before any code. The oracle candidate lane STAYS as the
non-destructive per-cell base layer C builds on (toggle/param/collision plumbing
reused). The analytic sine-curve channels are the part C replaces with real routing.

Do not use the compressed four-panel macro scene as gameplay scale. It is a
structure proof.
