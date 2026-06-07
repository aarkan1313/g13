# Milestone 2 — Untextured Biomes (+ DEM-informed shape)

**Prerequisite:** `m1-complete` tagged and green.

**Goal:** The infinite land from M1 now has large climate-driven biome regions and believable macro terrain shape — plains, hills, mountains, etc. — distinguished by **flat color plus terrain form** (no textures yet). Biomes are assigned by a climate model and are large and contiguous, never noisy splatter. Terrain shape is a separate shared composition/scaffold system, informed by DEMs, because that's what makes it read as real instead of as "Perlin nebula" (the explicit failure of past 2D attempts).

**Definition of done (the milestone gate):**
> Fly over the world. You cross from plains into foothills into mountains in a way that feels geographically plausible — terrain structure is organized, biomes are large/contiguous, and obvious borders/artifacts are either addressed or intentionally deferred with a plan. Each biome is a distinct flat color. Same seed → same biome map and terrain facts every time. Everything from M1 still holds (no seams, 60 FPS, streams fine).

**Out of scope for M2:** textures/splatting, scatter, water, erosion as a sim (but see §3 — DEM *statistics* are used here; full erosion simulation is a later milestone), caves.

---

## 1. What a biome IS (data, not code)

Per `00_ARCHITECTURE.md §6`, a biome is a **config entry**, never a code branch. In M2 a biome entry holds at minimum:
- `id` / name
- climate range it occupies (temperature band, moisture band)
- debug/material/style fields that can later influence surface treatment
- a flat debug color (textures come later, and will just be another field on this same entry)

Adding a biome = adding a row. If adding a biome requires new Rust logic, the design is wrong.

## 2. Biome assignment (the anti-"splatter" rule)

- Assign biomes via a **climate model**: low-frequency temperature and moisture fields (world-space noise, optionally latitude-like banding), mapped through a Whittaker-style table to a biome id. This is all in the **field** (the "what").
- Low-frequency = large contiguous regions. This is the specific fix for the past "cloudy mess": macro structure first, never per-pixel noise deciding biomes.
- Border/material blending is a later polish layer. The current M2.4b bite is terrain structure: ranges/ridges/channels/passes should be organized before border tinting tries to hide artifacts.
- All of this stays behind the field contract — the renderer still just asks for height/material and draws it.

### Steps
- **M2.1** — Temperature & moisture fields exist and are tunable; visualize them as debug color. GATE (visual): two smooth, large-scale gradients across the world.
- **M2.2** — Whittaker mapping → biome id per location; render biome as flat debug color. GATE (visual): large contiguous color regions, no confetti. GATE (test): same seed → identical biome id at fixed test coords.
- **M2.3** — General composition machine wired into the field. GATE (visual): macro mountains/plains/lowlands are visibly different and good enough to continue.
- **M2.4** — DEM structural scaffold / procedural mountain-synthesis facts. GATE (visual): organized ranges/ridges/channels/passes read like terrain structure, not local noise or scalar DEM grooves.
- **M2.5** — General-terrain visual acceptance + polish. GATE (visual): fly/walk review; remaining border/material blending and steep-terrain consequences are addressed in the right layer.

## 3. How DEMs inform the field (the part you wanted but didn't fully understand)

You have DEM (Digital Elevation Model) data — real-world heightmaps from sources like SRTM/Copernicus. You don't want to *place* real Earth in the game; you want real Earth's *statistical character* to make the procedural terrain believable. Here's the plan, in plain terms:

**The idea:** Pure noise looks like noise. Real terrain has structure — valleys connect, ridges have a characteristic spacing, slopes have a typical distribution. We extract those *statistical fingerprints* from DEMs and use them to bias the procedural field, without copying the actual landscape.

**Concretely, current priority order:**
1. **Structural scaffold first:** M2.4a proved slope/roughness scalar tuning can pass numeric gates while still looking bad. The next pass extracts/adapts the WG10 mountain-synthesis lesson into procedural facts: range masks, ridge/channel/pass structure, style weights, and material hints generated from seed+region.
2. **Offline DEM distillation still matters:** DEMs inform the structure and style targets, but the runtime consumes small distilled facts/params only. No runtime DEM loading.
3. **Kernels/templates are later tools, not the first fix:** DEM-derived kernels or landform profiles may still be useful after the scaffold exists, but they should ride on organized structure rather than try to create structure by themselves.

**M2 now does the structural scaffold**, not just #1 slope/roughness parameter fitting. Border blending and per-biome shape modulation are polish/future layers after the general terrain reads well. The DEM preprocessing (downloading, normalizing, computing statistics/facts) is an **offline tool** that outputs small data into `WorldConfig` or a region-fact cache — it is NOT part of the runtime field and must never be, or you'll couple the generator to gigabytes of data.

- **M2.4** — DEM structural scaffold produces deterministic range/ridge/channel/pass facts and a visual review sheet. GATE (test): deterministic facts, seam/apron correctness, connected pass/channel structure, regressions green.
- **M2.5** — General-terrain visual acceptance + polish. GATE (visual): fly/walk review confirms believable terrain and resolves remaining artifacts in the right layer.
- **M2.6** — Performance pass. GATE: real composed field stays inside target frame budget.

## 4. Milestone gate
Run the Definition of Done. Tag `m2-complete`.

---

## Note for the agent
DEM data files can be large. They live OUTSIDE the runtime. The runtime only ever sees the small distilled params/kernels in `WorldConfig`. If you find yourself loading a multi-megabyte DEM at runtime, STOP and log it — that's an architecture violation.
