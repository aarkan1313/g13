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

- **M2.1 ✓ DONE (test gate PASS; visual gate PASS 2026-06-06).** Temperature & moisture fields in the GLSL field, tunable (configure_climate), deterministic; V cycles normal/temp/moisture. Climate packed into one RG32F page texture (R=temp,G=moist). Distinct viz palettes (temp=thermal blue→red; moist=earth brown→blue). Height path bit-identical (M1.7 intact). Human flew it and confirmed both gradients read clearly.
- **M2.2 ✓ BUILT (test gate PASS; visual gate PARKED 2026-06-06).** Nearest-centroid Whittaker over temp/moisture/MACRO-altitude (10-biome data roster, field-side, page carries biome id). GATE (test): m2_2_biome_check PASS. GATE (visual): large contiguous regions — PARKED (capture _captures/climate_biome.png; V to biome mode). Two build-time fixes: macro-altitude (continental low-freq, not detailed height) killed confetti-at-LOD; M2.1 temp rebalance (warm floor + normalized lapse) made all 10 biomes appear. M2.4 will blend the hard borders. DECISIONS LOCKED below.
- **M2.3 ✓ BUILT; SHAPE judged "Perlin oatmeal" on live flyover -> M2.3b inserted.** height = shared base + biome.detail_amp * detail_fbm. Test gate m2_3_shaping_check PASS, but plain value-noise fBM is structurally incapable of real landforms. The per-biome MECHANISM (detail-on-shared-base, no cliff, no circularity) is sound and reused; the BASE noise is what M2.3b replaces.
- **M2.3b ← CURRENT (roadmap insertion 2026-06-06).** Real macro-landform field: domain-warped + ridged macro-elevation (ridgelines, valleys, organic). Per-biome = ridge intensity on the shared continuous base. The PERMANENT shape infra (erosion M6 carves into it, DEM-stats M2.5/6 tune it, textures M3 drape it, scatter M4 reads slope); high-freq detail kept minimal (erosion's job). Spec: `docs/superpowers/specs/2026-06-06-m2-3b-macro-landform-field-design.md`. M2.3's DECISIONS (the safe structure M2.3b preserves):
  - **Shaping = modulate DETAIL on a SHARED base** (pillar call, Survivability): `height = base_macro_landform + biome.detail_amp * detail_fbm(world, biome.detail_rough)`. The shared base keeps the world CONTINUOUS at biome borders NOW (no cliffs) — the alternative (full per-biome base elevation) would leave the world visibly broken with border cliffs until M2.4, violating "green at every step." M2.4 then blends the per-biome detail params across borders (clean continuation).
  - **No circularity / determinism intact** (00 §5): biome is chosen from the MACRO-altitude landform (continental, independent of shaped height), then biome reshapes the DETAIL. One-directional: macro -> biome -> detail. Height never feeds back into biome selection.
  - **Realism:** the mountain RANGE rises via the macro base; the biome adds the rugged high-amplitude surface that makes it READ as mountains. Plains flatten detail to ~0. Believable without cliffs.
  - **Shaping params = DATA** (extend biome rows): `detail_amp` (how much relief) + `detail_rough` (octave/lacunarity character). Mountain biome = high amp + rough; plains = ~0 amp. Adding a biome's shape = its row.
  - **Watch the M1 height contract:** restructuring the field's height into base+detail must keep the same overall character so M1 gates (continuity, seams) still pass; the height TEXTURE/array stays R32F single-channel (collision unchanged).
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

## M2.2 decisions locked (2026-06-06, pillar-driven + human input)

The human deferred to the pillars on WHERE the lookup runs, asked "will we have more than temp+moisture eventually?", and chose "N-axis if it's not much more work." Resolved:

1. **Lookup runs in the FIELD GLSL** (not the display shader). *Why (00 §1.1 build-it-right-once + §2.1 contract):* a biome id is a "what's here?" field output, and M2.3 height-shaping MUST read the id on-GPU to shape terrain — computing it in the display shader would be thrown away one step later. The page gains a **biome-id channel** (so the page carries [height, temp, moist, biome_id]; climate already packed RG32F, id packed alongside).

2. **N-axis DATA layout from the start; 3 axes WIRED now** (temp, moisture, **altitude**). *Why:* the human wants room to grow (latitude/continentality later) and altitude is FREE — the field already computes it, and altitude-as-an-axis immediately makes biomes better (snow-capped peaks). Adding a 4th axis later = one more dimension in the data + the field emitting that axis (data + small field change, NOT a rewrite). N-axis *structure* without speculative machinery (avoids the §1.1 over-build trap) — earns its keep day one via altitude.

   **Lookup = NEAREST CENTROID (Whittaker-as-Voronoi), not strict bands.** A biome row = `{id, color, centroid (temp_c, moist_c, alt_c)}`; the sample picks the biome whose centroid is nearest in weighted climate space (argmin of per-axis-weighted squared distance). *Why nearest-centroid over (lo,hi) bands:* it is **gapless and overlap-free by construction** — every climate point gets exactly one biome, no "unmatched -> hole" and no row-order dependence. It's trivially N-axis (more dims in the distance), fully data-driven (centroid + color per row), and it sets up **M2.4 border-blending naturally** (blend by distance to the two nearest centroids). Per-axis weights (global) let altitude dominate so high ground reliably reads alpine/snow.

3. **Biomes are DATA rows** (00 §6), pushed to the GLSL as a uniform table from Rust `WorldConfig`-style config. Adding a biome = adding a row, never a code branch. The Whittaker lookup is generic (band containment), not a hardcoded if-ladder.

4. **Determinism unchanged** (00 §5): biome id is a pure function of (world climate, which is a pure function of world pos + seed) + the static biome table. Same seed + world pos → same id, proven by readback (m2_2_biome_check), like M2.1.

5. **Render = flat per-biome debug color** via a new `biome` view mode (V cycles normal/temp/moisture/biome). Same render path that real biome textures (M3) will use.

### M2.2 starting biome roster (DATA — centroids in normalized temp/moist/alt, debug colors)
Tunable rows, the initial set (Whittaker-style coverage of the climate cube; alt high → alpine pulls in via the altitude weight). Adding/removing a biome = editing this list, never code:

| id | name | temp_c | moist_c | alt_c | debug color (rgb) |
|----|------|--------|---------|-------|-------------------|
| 0 | snow / ice cap        | 0.15 | 0.50 | 0.95 | 0.95,0.96,0.98 (white) |
| 1 | tundra                | 0.18 | 0.35 | 0.55 | 0.62,0.60,0.52 (grey-brown) |
| 2 | taiga / boreal        | 0.35 | 0.62 | 0.50 | 0.20,0.42,0.34 (dark green) |
| 3 | bare mountain rock    | 0.50 | 0.30 | 0.85 | 0.55,0.52,0.50 (grey) |
| 4 | grassland / steppe    | 0.58 | 0.30 | 0.30 | 0.70,0.72,0.40 (tan-green) |
| 5 | temperate forest      | 0.55 | 0.70 | 0.35 | 0.30,0.55,0.28 (green) |
| 6 | temperate rainforest  | 0.50 | 0.92 | 0.35 | 0.16,0.45,0.30 (deep green) |
| 7 | desert                | 0.88 | 0.15 | 0.25 | 0.85,0.74,0.45 (sand) |
| 8 | savanna               | 0.85 | 0.45 | 0.30 | 0.78,0.70,0.32 (yellow-green) |
| 9 | tropical rainforest   | 0.90 | 0.90 | 0.30 | 0.18,0.60,0.25 (vivid green) |

Axis weights (global, tunable): temp 1.0, moisture 1.0, **altitude 2.0** (so elevation pulls peaks to snow/rock decisively). These live in Rust config and are pushed to the GLSL as a uniform table.

## Watch-outs (don't trip these)
- **Don't break the field/renderer contract** (00 §2.1). Climate is a new field *output*, which is allowed; the renderer still only *reads* it. If M2 seems to need the renderer to *decide* climate, STOP — that's a violation.
- **Don't load DEM files at runtime** (milestone §4). Offline tool only.
- **Performance:** climate is cheap (low-freq noise), but it does grow the page and add field math — watch the HUD `prod` row as biomes land (the frame budget is a live, watched thing now; today's ~4 ms is the engine floor + empty world, see `01_TOOLCHAIN §6.1`).
- **Keep `density()` 3D-capable in spirit** (00 §3) — don't collapse the field to pure-2D thinking just because M2 shapes a surface.
