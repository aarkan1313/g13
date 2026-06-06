# Roadmap

Milestones 1 and 2 are detailed in their own docs. Everything past that is a **header only** — deliberately not over-specified, so you don't lock in decisions before you have the foundation. Each item notes which side of the Field/Renderer boundary it lives on (per `00_ARCHITECTURE.md §2`), because that's what guarantees it won't break what came before.

**The ordering rule:** never start a milestone until the previous one is tagged complete and green. The order below is chosen so each feature lands on a foundation that can already bear it.

---

## M1 — Contiguous infinite land  *(detailed: MILESTONE_1_land.md)*  — **not started**
The foundation. Smooth, seamless, streaming, performant, untextured land.

## M2 — Untextured biomes + DEM-informed shape  *(detailed: MILESTONE_2_biomes.md)*  — **in progress**
Large contiguous biomes by climate; DEM statistics make terrain believable. Flat colors. (DEM library inventoried in `03_DEM_CATALOG.md`.)
**Roadmap correction (2026-06-06):** plain value-noise fBM proved structurally incapable of real landforms ("Perlin oatmeal", the attempt #1–12 failure), so a step **M2.3b — real macro-landform field** (domain-warped + ridged elevation: actual ridgelines/valleys) was inserted between M2.3 and M2.4. This macro-elevation field is the PERMANENT, non-deprecating shape infrastructure: **M6 erosion carves real detail into it, M2.5/2.6 DEM-stats tune it, M3 textures drape it, M4 scatter reads its slope.** Accordingly **M2.5/2.6 are redefined** from "rescue placeholder noise" to "tune the M2.3b ridged macro field with DEM-measured statistics." High-frequency detail is deliberately kept minimal in M2.3b because that is erosion's job (M6) — building it now would be throwaway (`00 §1.1`). See `M2_DESIGN.md` and the design spec `docs/superpowers/specs/2026-06-06-m2-3b-macro-landform-field-design.md`.

---

## M3 — Texturing & materials  *(Renderer side)*
Bind your ComfyUI tileable textures per biome. Triplanar mapping, splatting/blending at biome borders, distance-based tile-break to hide repetition. This is where it starts looking AAA. *Does not touch the field.*

## M4 — Scatter: grass, rocks, ground detail  *(Renderer side, reads field for placement)*
GPU instancing (MultiMesh) driven by deterministic placement rules that *read* the field (slope, biome, moisture) but never *write* it. Density falloff with distance. *Field unchanged.*

## M5 — Water: oceans, lakes, swimmable  *(Field defines water level/bodies; Renderer draws + handles swim)*
Sea level and lake basins are field data; water surface shader + buoyancy/swim is renderer/gameplay. Lakes should fall out of the terrain shape + (later) hydrology.

## M6 — Erosion & hydrology  *(Field side — a post-process pass on the field)*
The "cool water" realism you want. Hydraulic + thermal erosion as a GPU compute pass that runs over the field's heights to carve valleys and deposit sediment; hydrology traces where water flows, which feeds river/lake placement. Runs as a bake or region pass, results cached deterministically. *Pure field-side; renderer unaffected.* This is high-value, moderate-high risk — it gets its own detailed doc when M5 is done, not before.
**Relationship to M2.3b:** M2.3b builds the ridged macro-landform *skeleton* (where ranges/valleys are, large-scale). M6 erosion carves the *real* fine detail into that skeleton (hydraulic flow). This is why M2.3b deliberately keeps high-frequency detail minimal — erosion supplies it for real, so building elaborate fake detail in M2.3b would be throwaway. The two compose: macro structure (M2.3b) → carved detail (M6).

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
