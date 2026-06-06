# Milestone 2 — Untextured Biomes (+ DEM-informed shape)

**Prerequisite:** `m1-complete` tagged and green.

**Goal:** The infinite land from M1 now varies by biome — plains, hills, mountains, etc. — distinguished by **shape and flat color only** (no textures yet). Biomes are assigned by a climate model and are large and contiguous, never noisy splatter. This is also where **DEMs start informing the terrain**, because that's what makes it read as real instead of as "Perlin nebula" (the explicit failure of past 2D attempts).

**Definition of done (the milestone gate):**
> Fly over the world. You cross from plains into foothills into mountains in a way that feels geographically plausible — biomes are large, contiguous, and transition smoothly (no hard square borders, no single-chunk biome confetti). Each biome is a distinct flat color. Same seed → same biome map every time. Everything from M1 still holds (no seams, 60 FPS, streams fine).

**Out of scope for M2:** textures/splatting, scatter, water, erosion as a sim (but see §3 — DEM *statistics* are used here; full erosion simulation is a later milestone), caves.

---

## 1. What a biome IS (data, not code)

Per `00_ARCHITECTURE.md §6`, a biome is a **config entry**, never a code branch. In M2 a biome entry holds at minimum:
- `id` / name
- climate range it occupies (temperature band, moisture band)
- height-shaping params (base elevation, ruggedness, which noise/DEM-kernel profile it uses)
- a flat debug color (textures come later, and will just be another field on this same entry)

Adding a biome = adding a row. If adding a biome requires new Rust logic, the design is wrong.

## 2. Biome assignment (the anti-"splatter" rule)

- Assign biomes via a **climate model**: low-frequency temperature and moisture fields (world-space noise, optionally latitude-like banding), mapped through a Whittaker-style table to a biome id. This is all in the **field** (the "what").
- Low-frequency = large contiguous regions. This is the specific fix for the past "cloudy mess": macro structure first, never per-pixel noise deciding biomes.
- **Blend at borders** by interpolating height-shaping params across a transition band, so there are no square borders and no hard cliffs at biome edges (unless a biome *wants* a cliff).
- All of this stays behind the field contract — the renderer still just asks for height/material and draws it.

### Steps
- **M2.1** — Temperature & moisture fields exist and are tunable; visualize them as debug color. GATE (visual): two smooth, large-scale gradients across the world.
- **M2.2** — Whittaker mapping → biome id per location; render biome as flat debug color. GATE (visual): large contiguous color regions, no confetti. GATE (test): same seed → identical biome id at fixed test coords.
- **M2.3 ✓ DONE** — offline DEM distillation tool (rust/dem_distill, separate binary, no .tif at runtime) -> per-archetype fingerprint (radial amplitude spectrum + slope_p95 + ridge character). Gate PASS.
- **M2.4 (REDESIGNED 2026-06-06)** — The spectral octave-sum synthesis was abandoned (made uniform terrain, no discrete ranges). Terrain is now **WG10-informed layered composition**: a shared composition MACHINE (domain warp, region envelope, ridged fbm, valley carve, blend) + per-biome RECIPE functions, DEM-fingerprint-tuned, biome-selected, border-blended. Spec: `docs/superpowers/specs/2026-06-06-m2-terrain-composition-machine-design.md`. **PROVE WITH 3 first:** M2.4a machine + MOUNTAIN recipe (envelope×ridges→ranges with valleys) + fallback; M2.4b GRASSLAND; M2.4c DESERT. GATE (test): determinism, range-structure, no cliffs. GATE (visual): real ranges/valleys, distinct per biome. After the 3 prove out -> the remaining recipes, each gated.
- **M2.5** — Border blending (refine the recipe-blend). GATE (visual): no hard borders; natural transitions.
- **M2.6** — Efficiency/performance pass (LAST, M1.9-style): profile the real composed field, optimize. GATE (test): frame budget held on RTX 3070.

## 3. How DEMs inform the field (the part you wanted but didn't fully understand)

You have DEM (Digital Elevation Model) data — real-world heightmaps from sources like SRTM/Copernicus. You don't want to *place* real Earth in the game; you want real Earth's *statistical character* to make the procedural terrain believable. Here's the plan, in plain terms:

**The idea (REPLANNED 2026-06-06):** Pure noise looks like noise — proven the hard way when hand-tuned procedural noise (M2.3/M2.3b) failed to make believable landforms. Real terrain has structure noise lacks. We don't *place* real Earth (no .tif at runtime, would repeat); we distill each DEM archetype's **terrain FINGERPRINT** offline and synthesize procedural terrain SHAPED to it.

**The fingerprint (what the offline tool measures per archetype):**
1. **Radial amplitude spectrum** — the dominant "looks real" lever. How relief amplitude falls off across spatial scales (continental → ~10 m), measured by FFT. Real mountains/deserts/plains each have a distinct spectrum; generic `0.5^octave` fBM matches none. The runtime synthesizes octaves weighted by the MEASURED spectrum, so the procedural output carries the real type's structure.
2. **Slope ceiling** — real steepness bound (p95), so synthesis structurally cannot make the vertical-cliff garbage the noise attempts produced.
3. **Ridge character** — ridged vs rounded, from local-curvature distribution; sets the smooth↔ridged blend per archetype from data.

**Output:** a small per-archetype params file (a few KB) into config. The DEM `.tif`s stay OUTSIDE the runtime (the hard rule below); only the distilled fingerprint ships.

**Deferred (not M2, flagged so we don't over-build):** richer exemplar/texture-synthesis guided by DEM patches, and feature-template stamping. M2 does spectrum + slope + ridge character only. Erosion (M6) later carves real hydraulic detail into this already-real macro shape.

(Step list with gates is in §2 above: M2.3 distill tool → M2.4 spectral field → M2.5 border blend → M2.6 perf pass.)

## 4. Milestone gate
Run the Definition of Done. Tag `m2-complete`.

---

## Note for the agent
DEM data files can be large. They live OUTSIDE the runtime. The runtime only ever sees the small distilled params/kernels in `WorldConfig`. If you find yourself loading a multi-megabyte DEM at runtime, STOP and log it — that's an architecture violation.
