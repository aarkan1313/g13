# M2 Design Note — Biomes, in plain language + the decisions made

**Companion to `MILESTONE_2_biomes.md`** (which is the canonical spec). This note exists because the user asked, reasonably, "I don't fully understand what we're doing — build the best realistic system." So this explains M2 in plain terms AND records the design decisions already made, so the implementing session doesn't re-decide them.

---

## What M2 is, plainly

Right now the whole world is ONE kind of terrain (soft rolling hills, the same everywhere). M2 makes the world have **regions that differ** — flat plains, rolling hills, jagged mountains — **arranged so they make sense**, like a real continent, not random patches.

The trick to "makes sense" (and the specific fix for why past attempts looked like a "cloudy Perlin mess"): borrow how Earth works. **Climate decides terrain.** Two invisible, slowly-varying maps over the world:
- **Temperature** — cold near the "poles," warm near the "equator," colder high up on mountains.
- **Moisture** — wet regions and dry regions.

The *combination* of those two at any spot picks the biome (cold+wet → tundra, hot+dry → desert, temperate+wet → forest, …). This climate→biome lookup is a real concept: a **Whittaker diagram**. Because the climate maps vary *slowly*, biomes come out **large and contiguous**, blending into each other — exactly like real geography, never per-pixel confetti.

Then each biome **shapes the terrain differently** (mountains are rugged and tall, plains are flat), and borders **blend** so there are no hard square edges.

## The decisions made (so next session just builds)

1. **Climate model = Earth-like: latitude + altitude + gentle noise** (not pure noise, not pure stripes).
   - Temperature ≈ a smooth latitude gradient (cooler as world-Z grows) − altitude (high = cold) + low-frequency noise (so it's not a perfect stripe).
   - Moisture ≈ independent low-frequency noise (optionally a second axis).
   - *Why:* gives a believable world (poles/equator/mountains-cold), and the altitude coupling sets up M2.3 (mountains) naturally. The user asked for "best realistic," not "simplest."

2. **Climate is produced in the SAME field compute dispatch as height** (the height page grows to carry temp + moisture per cell, a few floats instead of one).
   - *Why ("build it right once," 00 §1.1 / §2.1):* one production, one source of truth, no extra GPU pass, no second path to keep in sync. M2.2 (biome id) and M2.3 (height shaping) read these exact values. The alternatives (a second dispatch, or recomputing in the display shader) either double GPU cost or get thrown away next step.
   - This stays behind the field contract (00 §2.1): the field still answers "what's here?" — now with climate as part of the answer.

3. **Visualization = recolor the terrain via a view-mode toggle** (user's explicit pick).
   - A key (proposed **V**) cycles view modes: normal / temperature / moisture (and later: biome). In temperature mode the ground tints cold→hot; moisture mode tints dry→wet.
   - *Why:* you see the climate ON the terrain you're flying, and it's the SAME render path M2.2's biome-color will use (not throwaway).

4. **Biomes are DATA, not code** (00 §6, milestone §1). A biome = a config row (id, climate band, height-shaping params, debug color). Adding a biome = adding a row, never a new code branch. (M2.2+ concern; noted so it's not violated earlier.)

5. **DEMs inform via OFFLINE statistics only** (milestone §3). M2.5/2.6 extract slope/roughness *numbers* from real-world elevation data offline and feed them into biome params. The runtime NEVER loads DEM files — only the small distilled params. (Later steps; flagged so it's not pulled forward wrong.)

## The steps (each ends in a gate; see MILESTONE_2 for exact gates)

- **M2.1 ✓ BUILT (test gate PASS; visual gate PARKED 2026-06-06).** Temperature & moisture fields exist in the GLSL field, tunable (configure_climate), deterministic; V cycles normal/temp/moisture. GATE (test): m2_1_climate_check PASS — determinism + range[0,1] + low-freq/smooth + latitude gradient. GATE (visual): two smooth, large-scale gradients — PARKED for the human (captures in _captures/climate_*.png; fly + press V). Climate rides height's single dispatch; height path bit-identical (M1.7 intact). NEXT after human confirm: M2.2.
- **M2.2** — Whittaker table → biome id per location; render biome as flat debug color. GATE: large contiguous color regions, no confetti; same seed → identical biome id (test).
- **M2.3** — per-biome height shaping wired into the field. GATE: mountains mountainous, plains flat — visibly different terrain per biome.
- **M2.4** — border blending. GATE: no hard square borders; natural transitions.
- **M2.5** — offline DEM-stats tool → slope/roughness params file. GATE (test): tool runs, outputs a small params file.
- **M2.6** — mountain/hill biomes use DEM-derived params. GATE (visual): DEM-informed reads more believable than pure noise.
- **Milestone gate** — run the DoD, tag `m2-complete`.

## What M2.1 concretely touches (the implementing session's starting map)

- **`wg-13/shaders/field_height.glsl`** — add temperature & moisture computation (world-space, low-freq, latitude+altitude+noise). The output buffer goes from 1 float/cell (height) to ~3 floats/cell (height, temp, moisture). This is the main change.
- **`rust/gdext/src/field_gpu.rs` + `page_pool.rs`** — the page now carries 3 channels. Decide packing: simplest is one R32F-per-channel readback, or pack into an RGB/RGBA texture. The render shader needs temp/moisture available per cell to tint — so a small texture (e.g. RGBAH or three R32F) the display shader can sample. Keep it ONE dispatch.
- **`wg-13/shaders/ring_displace.gdshader`** — add a `view_mode` uniform; in temp/moisture modes, tint by the climate channels instead of normal shading.
- **`wg-13/scripts/world_view.gd`** — a `view_mode` cycled by a key (V), pushed to the material(s).
- **New gate** `wg-13/tests/m2_1_climate_check.gd` — determinism: same world coord → same temp/moisture across runs; continuity: climate varies smoothly (low-frequency), no jumps; range sanity (temp/moisture in expected bounds).
- **Determinism rule still absolute** (00 §5): climate sampled in WORLD coordinates, never page-local. Same seed + world pos → same climate, always.

## Watch-outs (don't trip these)
- **Don't break the field/renderer contract** (00 §2.1). Climate is a new field *output*, which is allowed; the renderer still only *reads* it. If M2 seems to need the renderer to *decide* climate, STOP — that's a violation.
- **Don't load DEM files at runtime** (milestone §4). Offline tool only.
- **Performance:** climate is cheap (low-freq noise), but it does grow the page and add field math — watch the HUD `prod` row as biomes land (the frame budget is a live, watched thing now; today's ~4 ms is the engine floor + empty world, see `01_TOOLCHAIN §6.1`).
- **Keep `density()` 3D-capable in spirit** (00 §3) — don't collapse the field to pure-2D thinking just because M2 shapes a surface.
