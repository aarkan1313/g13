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
- **M2.3** — Per-biome height shaping wired into the field. GATE (visual): mountains are mountainous, plains are flat, visibly different terrain per biome. *(Built; test gate green. Live flyover showed the underlying SHAPE was "Perlin oatmeal" — see M2.3b.)*
- **M2.3b** *(inserted 2026-06-06)* — **Real macro-landform field.** Replace plain value-noise fBM with a **domain-warped + ridged** macro-elevation field: actual ridgelines, connected valleys, organic (non-blobby) continental structure. Per-biome character = ridge intensity (mountains sharp, plains smooth) on the shared continuous base. This is the PERMANENT shape infrastructure (erosion M6 carves into it, DEM-stats M2.5/6 tune it, textures M3 drape it, scatter M4 reads its slope); high-freq detail kept minimal (erosion's job). GATE (test): ridge structure exists + differs per biome + deterministic + no border cliff. GATE (visual): reads as real terrain, not oatmeal. Spec: `docs/superpowers/specs/2026-06-06-m2-3b-macro-landform-field-design.md`.
- **M2.4** — Border blending. GATE (visual): no hard square borders; transitions read as natural.

## 3. How DEMs inform the field (the part you wanted but didn't fully understand)

You have DEM (Digital Elevation Model) data — real-world heightmaps from sources like SRTM/Copernicus. You don't want to *place* real Earth in the game; you want real Earth's *statistical character* to make the procedural terrain believable. Here's the plan, in plain terms:

**The idea:** Pure noise looks like noise. Real terrain has structure — valleys connect, ridges have a characteristic spacing, slopes have a typical distribution. We extract those *statistical fingerprints* from DEMs and use them to bias the procedural field, without copying the actual landscape.

**Concretely, in priority order:**
1. **Slope/roughness statistics (easiest, do first):** From a DEM of, say, a mountain range, measure the distribution of slopes and the typical feature spacing (via frequency analysis). Feed those into the **M2.3b ridged macro field's per-biome params** (warp amplitude/frequency, ridge sharpness, octave gain) so the procedural mountains match the measured slope/ridge-spacing distribution. Result: your procedural mountains have the *texture of realness* of real mountains. This is parameter-fitting onto a noise that already makes ridges — low risk, high payoff. *(This is why M2.3b had to come first: DEM stats tune a ridged field; they cannot rescue plain fBM, which has no ridges to tune.)*
2. **DEM tiles as noise kernels:** Use small, tileable patches derived from DEMs as an additional noise layer blended into a biome's shaping. The procedural layer places the macro structure; the DEM kernel adds believable meso-detail.
3. **(Later, optional) Feature templates:** Extract characteristic landforms (a valley cross-section, a ridge profile) and use them as profiles the field can stamp/blend along procedural skeletons. Higher complexity — defer.

**M2 only does #1**, and only as much as needed to make biomes look plausible. #2 and #3 are flagged as future enhancements so the agent doesn't over-build. The DEM preprocessing (downloading, normalizing, computing statistics) is an **offline tool** that outputs numbers/small textures into `WorldConfig` — it is NOT part of the runtime field and must never be, or you'll couple the generator to gigabytes of data.

- **M2.5** — Offline DEM-stats tool produces slope/roughness/ridge-spacing params for 2–3 reference terrain types. GATE (test): tool runs, outputs a small params file. *(Redefined 2026-06-06: these stats TUNE the M2.3b ridged macro field — its warp/ridge/octave params — rather than rescue placeholder noise. The tool's job is unchanged; what it feeds is now a noise that can actually use ridge-spacing/slope numbers.)*
- **M2.6** — Mountain/hill biomes use DEM-derived params **fed into the M2.3b ridged-field params** (per-biome warp/ridge/octave coefficients from measured DEM statistics). GATE (visual): side-by-side, DEM-tuned terrain reads as more believable than the hand-tuned-ridged version. (Human visual call.)

## 4. Milestone gate
Run the Definition of Done. Tag `m2-complete`.

---

## Note for the agent
DEM data files can be large. They live OUTSIDE the runtime. The runtime only ever sees the small distilled params/kernels in `WorldConfig`. If you find yourself loading a multi-megabyte DEM at runtime, STOP and log it — that's an architecture violation.
