# M2.4 (reframed) — Eliminate the chunk-boundary geometry step via clipmap geomorphing

**Date:** 2026-06-07
**Status:** design, awaiting user review
**Supersedes the prior M2.4 mission** ("richer terrain shape"), which was attempted 4 ways and rolled back (see `plans and docs/plans/M2_4_POSTMORTEM.md`). The reframe below is the new M2.4.

## Why this, and why not "richer terrain shape"

A brainstorm (2026-06-07) walked the actual requirement:

- **Target viewing scale:** terrain must look *good* low (walk / near-fly), *ok* at higher/faster scales. The hardest scales (coarse-LOD, ~10 km altitude) the failed M2.4 attempts fought only need "ok".
- **Low-altitude shape:** already fine. The M2.3 composition-machine mountains/plains are the "looks really good" baseline and are **not touched** by this work.
- **Textures / biome features:** intentionally absent (M3+).
- **The one real defect at the scale that matters:** *seams between chunks* — and specifically a **geometry step/lip** (user-identified), not a shading break and not a same-level crack.

So the next gated step is **not** richer shape — it is removing the chunk-boundary geometry step. (A separate, larger track — *rendering real DEMs directly as terrain* — is the user's chosen next brainstorm AFTER this fix ships; logged in DRIFT_LOG, out of scope here.)

## Root cause (evidence-based, from code)

The step is the **cross-LOD transition**, not a same-level crack:

1. **No same-level crack.** `wg-13/tests/m1_4_seam_check.gd` proves adjacent same-level pages share bit-identical boundary heights. The display mesh is one vertex per texel (`subdivide_width = mini(page_res-1, 160)` → 127, the cap doesn't bite at `page_res=128`), so same-level borders share vertices at identical world positions and heights → continuous by construction.
2. **The cross-LOD step is structural.** Every level uses a 128² height texture, but coarse levels stretch `spacing` by `2^level` (`rust/gdext/src/page_pool.rs` `produce()`: `span = page_span * 2^level`, `spacing = cfg.spacing * 2^level`). A level-0 page samples height at 4 m; the coarse page it abuts samples at 8/16/.../128 m. The coarse page has **no texel** for the detail the fine page shows, so its plane renders a straight cut where the fine plane curves into that detail → a visible lip at the fine↔coarse ring boundary.

This is the roadmap's deferred **geomorph** item, surfacing as a low-altitude lip at clipmap ring boundaries.

## Approach (chosen) — self-contained vertex geomorphing

Standard clipmap geomorphing, done per page with **no cross-page state**:

Near a level's outer transition band, blend each vertex's height between its full-detail value and the value it would have at **half this page's resolution** (a coarser tap of the *same* height texture), keyed by camera distance. Each level smoothly sheds its highest-frequency detail as it approaches the next-coarser level's domain, so by the boundary the two adjacent levels are displaying the **same** surface there — contiguous, no step.

### Pillar call (stated, not ratified — per 02_WORKFLOW §8)

Chosen over "morph toward the neighbor's fine page" on **every** pillar:
- **Quality (no slop):** no cross-page coupling → no stale-neighbor / streaming-frontier edge cases. Cleaner = more right.
- **Survivability:** nothing to break when neighbor pages load / evict / recenter each frame.
- **Modularity:** a pure property of the page's own shader + uniforms; zero dependency on `world_view.gd`'s ring bookkeeping.
- **Performance:** one extra texture tap per vertex vs. binding & sampling additional neighbor textures.

### Honest tradeoff (on the record)

Self-contained geomorph smooths the transition by gently **reducing** fine detail in the morph band near a level's outer edge (converging to the coarser representation), not by *adding* coarse-page detail. This is correct for the stated bar: at **low** altitude you stand on level-0 fine pages at full detail; the morph only acts where levels transition, which is farther out. So borders become smooth without robbing the ground under you.

## Mechanism (concrete)

In `wg-13/shaders/ring_displace.gdshader`, `vertex()`:

1. **Inputs available without new plumbing:**
   - `page_world_size` (already a uniform) = the page span = `508 * 2^level`. Encodes the level.
   - `CAMERA_POSITION_WORLD` (Godot spatial vertex built-in) = camera world position. **No camera uniform needed.**
   - World vertex position via `MODEL_MATRIX * vec4(VERTEX,1)` (or `NODE_POSITION_WORLD` + local) to compute camera distance.
2. **Morph factor** `a in [0,1]`: 0 = full detail, 1 = fully coarsened. Compute from camera distance to the vertex relative to this level's transition band. The band is defined so a page's outer region (the part nearest where the next-coarser level takes over) reaches `a=1` exactly at the hand-off, while its inner region stays `a=0`. Band edges derived from `page_world_size` and the ring geometry (`ring_radius`, level span), passed as 1–2 uniforms (`morph_lo`, `morph_hi` in world units, or a single `morph_band` fraction).
3. **Coarse tap:** sample the height texture at the vertex UV **snapped to half resolution** (`uv_coarse = (floor(uv * (res/2)) + 0.5) / (res/2)`), giving the height this vertex would have on a page of half the texel density. `res` passed as a uniform (`page_res`, currently 128) or `inv_res` precomputed.
4. **Blend:** `h = mix(h_full, h_coarse, a)`. Apply the **same** blend when computing the finite-difference normal taps so normals stay consistent with the morphed surface (no shading seam reappearing).

### Plumbing in `wg-13/scripts/world_view.gd`

Set the new uniforms on each page material in `_make_page_instance` (alongside the existing `page_world_size`, `height_scale`, `cell_spacing`):
- `page_res` (int) — for the half-res snap.
- `morph_band` parameters — derived once from `base_span`, `num_levels`, `ring_radius` (constants already in the view). Set once per material; no per-frame churn (respects M1.9.3c).

No Rust changes. No rebuild. GDScript + shader only → scene reload picks it up.

## Determinism / contracts preserved

- **Heights array & collision unchanged.** Geomorph is a *display-only* vertex blend in the shader; `page.heights` (collision source, M1.7) is untouched. Collision is level-0 only, where `a=0` (full detail) under the player. No collision-vs-visual drift introduced.
- **Never-black / annulus visibility unchanged.** The visibility rule (`_update_annulus_visibility`) is untouched; geomorph only changes vertex Y within a shown page.
- **M2.1/M2.2 climate & biome channels unchanged.** Fragment shader untouched except (if needed) keeping normals consistent.

## Risks & mitigations

- **Morph band mis-tuned** (too wide = detail vanishes too early; too narrow = step still visible). Mitigation: band is a uniform, tunable live in the inspector; the human walk-test is the gate.
- **Normal shading seam** if normals aren't morphed with the surface. Mitigation: apply the same `mix` to the normal's neighbor taps.
- **Half-res snap at page edges** could re-introduce a one-sided artifact via UV clamp. Mitigation: the snap stays within [0,1]; verify edge taps in the gate. If it bites, clamp the coarse UV identically to the full UV (already clamped).

## Acceptance gates

1. **Automated (output-proven):** a new `m2_4_geomorph_check.gd` that, at minimum, asserts (a) determinism unchanged, (b) `page.heights` / collision path bit-identical to pre-change (display-only proof), (c) existing gates still green: `m1_4_seam_check`, `m1_5c_overlap_check`, `m1_7c_stand_check`, `m2_3_composition_check`, `m2_1_climate_check`, `m2_2_biome_check`. Run GPU gates with `--rendering-driver vulkan` (no `--headless`).
2. **Human visual (the real gate):** launch via `run.ps1`, fly **low** over chunk borders — the geometry step/lip is gone, ground reads smooth and contiguous across LOD ring boundaries; and confirm the M2.3 shape and the standing surface under the player are unchanged. (User has deuteranopia — judge by shape/shading, not color.)

## Out of scope (do not entangle)

- Terrain shape (M2.3 stays).
- **Direct-DEM terrain** — the user's chosen NEXT brainstorm track after this ships.
- Far-edge streaming pop-in; ~150 ms startup hitch; materials/biome features (M3+).
- Character/collision controller polish (M2.7).
