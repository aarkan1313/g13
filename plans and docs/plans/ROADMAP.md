# Roadmap

Milestones 1 and 2 are detailed in their own docs. Everything past that is a **header only** — deliberately not over-specified, so you don't lock in decisions before you have the foundation. Each item notes which side of the Field/Renderer boundary it lives on (per `00_ARCHITECTURE.md §2`), because that's what guarantees it won't break what came before.

**The ordering rule:** never start a milestone until the previous one is tagged complete and green. The order below is chosen so each feature lands on a foundation that can already bear it.

---

## M1 — Contiguous infinite land  *(detailed: MILESTONE_1_land.md)*  — **not started**
The foundation. Smooth, seamless, streaming, performant, untextured land.

## M2 — Untextured biomes + DEM-informed shape  *(detailed: MILESTONE_2_biomes.md)*  — **in progress**
Large contiguous biomes by climate; DEM statistics make terrain believable. Flat colors. (DEM library inventoried in `03_DEM_CATALOG.md`.)
**Roadmap correction (2026-06-06):** hand-tuned procedural noise proved structurally incapable of believable landforms ("Perlin oatmeal" → "mesa cliffs", the attempt #1–12 failure) — both the original M2.3 and an attempted M2.3b ridged-noise step failed; the field was reverted to M2.2. **M2 shape was replanned to DEM-spectral-informed synthesis:** an offline tool distills each DEM archetype's terrain FINGERPRINT (radial amplitude spectrum + slope ceiling + ridge character), and the runtime synthesizes procedural terrain SHAPED to that fingerprint per biome — procedural + cheap, but structure borrowed from real Earth. **The DEMs move from peripheral/late (stats-only) to central/early (the shape source).** Revised sub-steps: M2.3 distill tool → M2.4 spectral field (mountain+grassland+desert first, then all 12) → M2.5 border blend → M2.6 efficiency/perf pass LAST (M1.9 lesson: optimize the real field, not a placeholder). See `M2_DESIGN.md` and the spec `docs/superpowers/specs/2026-06-06-m2-dem-spectral-terrain-design.md`.

---

## M3 — Texturing & materials  *(Renderer side)*
Bind your ComfyUI tileable textures per biome. Triplanar mapping, splatting/blending at biome borders, distance-based tile-break to hide repetition. This is where it starts looking AAA. *Does not touch the field.*

## M4 — Scatter: grass, rocks, ground detail  *(Renderer side, reads field for placement)*
GPU instancing (MultiMesh) driven by deterministic placement rules that *read* the field (slope, biome, moisture) but never *write* it. Density falloff with distance. *Field unchanged.*

## M5 — Water: oceans, lakes, swimmable  *(Field defines water level/bodies; Renderer draws + handles swim)*
Sea level and lake basins are field data; water surface shader + buoyancy/swim is renderer/gameplay. Lakes should fall out of the terrain shape + (later) hydrology.

## M6 — Erosion & hydrology  *(Field side — a post-process pass on the field)*
The "cool water" realism you want. Hydraulic + thermal erosion as a GPU compute pass that runs over the field's heights to carve valleys and deposit sediment; hydrology traces where water flows, which feeds river/lake placement. Runs as a bake or region pass, results cached deterministically. *Pure field-side; renderer unaffected.* This is high-value, moderate-high risk — it gets its own detailed doc when M5 is done, not before.
**Relationship to M2 (DEM-spectral) shape:** M2.4 builds the macro landform *skeleton* with real spectral structure (where ranges/valleys are, at the right scales). M6 erosion carves the *real* fine hydraulic detail (drainage, sediment) into that skeleton. M2 deliberately keeps fine detail modest because erosion supplies it for real — building elaborate fake detail in M2 would be throwaway. The two compose: DEM-spectral macro structure (M2.4) → carved hydraulic detail (M6).

## M7 — Caves, overhangs, tunnels  *(Renderer gains full-volume extraction; Field already 3D)*
The payoff of choosing a density field in M1. The field already returns 3D density; here the renderer learns Surface Nets / Dual Contouring for chunks containing interior air, so caves are smooth, not blocky. *No field rewrite — this is why we paid for the density field up front.*

## M8 — Editable terrain (toggle)  *(Field gains a writable diff layer)*
A sparse, writable layer composited on top of the deterministic base field. Edits are stored as diffs from the deterministic baseline (cheap, because the base is reproducible from seed). Toggleable per-game. *Base field untouched; this is an additive layer.*

## M9 — Traversal guarantees: paths, roads, trails, POIs  *(Field side, structural)*
Ensure every chunk is traversable; generate paths/roads/trails along walkable gradients; place points of interest. Graph-based structure over the field. Depends on having stable terrain + hydrology (roads avoid water, follow valleys).

## M10 — Procedural flora & fauna  *(Renderer/gameplay; flora reads field)*
Procedural trees (beyond M4 scatter), animal placement and spawning rules driven by biome/field data. Your Meshy/TRELLIS models slot in here.

## M11 — Weather & atmosphere  *(Renderer/gameplay, mostly field-independent)*
Sky, atmospheric scattering, volumetric fog, weather states. Largely decoupled — can be developed in parallel late.

## M12 — Top-down / 2.5D support  *(Renderer side — alternate camera/extraction profile)*
Late feature. Because the field is camera-agnostic data, supporting top-down is "a different way to render the same field," not a new world. This is the dividend of the whole architecture: the world doesn't care how you look at it.

---

## Things deliberately NOT scheduled
These are real wants you mentioned, parked on purpose so they don't cause scope creep. They get scheduled only when their prerequisites are solid:
- Advanced LOD geomorphing (smooth, zero-pop transitions) — polish pass, fits anywhere after M1.
- Far-from-origin floating-point precision strategy (origin rebasing) — address when it actually bites, flagged in M1 notes.
- Save/load of edited/visited chunks — trivial once M8 exists (store diffs only).
- Multiplayer determinism — the seeding rules in `00_ARCHITECTURE.md §5` already keep this door open; no work needed until you want it.

## How to read this roadmap when tempted to skip ahead
Every past attempt died from doing too much at once. If you're at M2 and excited about caves (M7): the *reason* you can be relaxed about caves is that you're building the density field NOW that makes them easy LATER. Skipping to them now, on an unproven foundation, is exactly attempt #1 through #12. Trust the order.
