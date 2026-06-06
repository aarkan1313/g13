# World Generator — Architecture & First Principles

**Project:** Infinite, modular, AAA-grade procedural 3D world generator
**Engine:** Godot 4.6 (Forward+ renderer, Vulkan)
**Core language:** Rust via gdext (godot-rust) v0.5+, `compatibility_minimum = 4.2`
**Status of this doc:** CANONICAL. If code and this doc disagree, the code is wrong until this doc is deliberately changed. See `02_WORKFLOW.md` for how changes to this doc are authorized.

---

## 0. Why this attempt is structured differently

This is attempt #13. The previous twelve did not fail on algorithms. They failed on **two things**:

1. **Architecture that tangled data and rendering**, so that adding a feature (caves, erosion) broke an unrelated feature (contiguous land), and the only fix was a massive refactor.
2. **Plan divergence during unsupervised work.** Progress happened at the desk with visual feedback. Then unsupervised sessions drifted from the plan, accumulated changes, and the result no longer matched any document and could not be troubleshot back.

Therefore this architecture is built around **one structural rule** (Section 2) and the whole project is built around **one process rule** (see `02_WORKFLOW.md`): every step ends in a gate that visibly passes or fails. Nothing is ever "improve the terrain." Everything is "after this, you see X, or it failed."

---

## 1. The pillars (in priority order)

When two pillars conflict, the higher one wins. Write this order down; an agent will face these conflicts constantly.

1. **Survivability** — the codebase must remain buildable, runnable, and troubleshootable at all times. A feature that risks the whole project is deferred, not attempted. This pillar is NEW and it is #1 specifically because it is the thing that has failed before.
2. **Modularity** — the generator must be drop-in reusable across future games by tuning parameters and swapping assets, never by rewriting core code.
3. **Performance** — 60 FPS on midrange PC, no stutter on movement.
4. **Quality** — AAA-grade visuals, no Minecraft blockiness, no "cloudy Perlin nebula."

Note that Quality is LAST. This is deliberate. Every previous attempt chased quality and sacrificed survivability. Quality is meaningless if the project is dead.

---

## 2. THE STRUCTURAL RULE: the Field/Renderer boundary

> **The world is defined by a pure data function. The renderer only reads that function. They never know about each other's internals.**

This is the single most important rule in the entire project. Almost every past failure is a violation of it.

### 2.1 The World Field (the "what")

The Field answers exactly these questions about any point in continuous world space, given a seed:

```
density(world_pos: Vec3, seed: u64) -> f32       // < 0 = solid, > 0 = air (signed distance-ish)
surface(world_xz: Vec2, seed: u64) -> f32        // convenience: surface height at x,z
material(world_pos: Vec3, seed: u64) -> MaterialId
```

These are the **contract** — the questions the renderer is allowed to ask. They are stable regardless of *how* they're computed.

**The Field's canonical implementation is a GPU compute shader (GLSL), authored in WG13 as the source of truth.** It produces height/density/material **pages** (tiles of world space) on the GPU. There is no separate CPU implementation of the world math to keep in sync — that "two worlds" duplication is exactly what `00 §4` warns against, so we don't create it.

Properties that MUST hold forever:

- **Deterministic:** same world position + same seed → same output, always, on any machine, in any session. No global mutable state, no time dependence, no frame dependence, no chunk/page-local coordinates (sample in world space — see §5). This is the rule that makes seams, save/load, and multiplayer possible.
- **Page/chunk-agnostic in meaning:** the *math* does not depend on how the renderer tiles the world. A page is a unit of *production* (a tile the compute shader fills), never a unit that changes the *answer*. Two different page layouts over the same world point must yield the same value.
- **3D-capable from day one:** even though Milestone 1 only renders the *surface*, the canonical model is a 3D density field. `density(...)` exists from the start so caves, overhangs, and editable terrain arrive later WITHOUT a rewrite. (See §3.)
- **Verified by GPU readback, not by a CPU oracle:** determinism and continuity are proven by **reading the GPU's output back and asserting on it** — "produce the page at world origin twice, same seed, get identical bytes"; "the shared edge of two adjacent pages matches to the bit." These are automated test gates (`02_WORKFLOW.md`) that run the real compute path. The screen is never the determinism check.
- **Rust owns everything around the field that isn't the math:** seed derivation, page scheduling, residency, route/carve/condition facts, and the readback-based tests are deterministic Rust (`§4`). The GLSL owns only the per-point world math.

### 2.2 The Renderer / Streaming layer (the "how it looks")

Knows nothing about *why* a density value is what it is. Its only questions to the field are "what's the value here?" Responsibilities:

- Chunk streaming (load/unload around the viewer)
- Surface extraction (turning field samples into a mesh)
- LOD selection and seam handling
- Collision generation
- Asset binding (textures, materials, later: scatter)

If the renderer ever contains a line like "if biome == desert, lower the height," **that is a bug**, because that decision belongs in the field. The renderer's job is to faithfully draw whatever the field says.

### 2.3 Why this prevents "works then breaks"

Every future feature lands on exactly ONE side of the boundary:

| Feature | Lives in | Cannot break |
|---|---|---|
| DEM-informed terrain shape | Field | Rendering, streaming |
| Biomes | Field | Meshing, LOD |
| Erosion / hydrology | Field (a post-process on the field) | Streaming, collision |
| Caves / overhangs | Field (just 3D density that goes solid→air→solid) | Surface land (already 3D-ready) |
| Editable terrain | Field (a writable layer added on top) | The base field |
| LOD / seams / popping | Renderer | The world's shape |
| Texturing / splatting | Renderer | The world's shape |
| Scatter (grass/trees) | Renderer (reads field for placement rules) | The field |

A change on one side cannot force a refactor on the other side **as long as the function signatures in 2.1 stay stable.** Those signatures are the contract. Changing them requires a deliberate doc change (`02_WORKFLOW.md`), never an ad-hoc edit.

---

## 3. Terrain representation: GPU-produced density/height pages, surface-only rendering (for now)

**Decision: A signed-distance / density field is the canonical data model from day one, produced on the GPU as world-space pages. Milestone 1 renders only the surface layer (a height page displaced onto a mesh). Caves/overhangs are unlocked later by reading the full 3D density — with no change to the field's contract.**

### Why GPU-first (and not a CPU heightfield first)
We are not building a throwaway CPU meshing path. A GPU compute producer is the runtime we actually want — it's how an infinite, high-detail world hits the frame budget — and we already learned its shape in WG10 (reference only; we are rebuilding clean). Starting CPU-first would mean writing a heightfield path we'd delete the moment performance bit, then re-deriving the field math in GLSL anyway. That is the duplicated effort, not the safe choice. So the field is GLSL from step one.

### Why not pure heightmap?
A 2D heightmap (`height = f(x,z)`) is structurally incapable of caves, overhangs, or arbitrary editable terrain. The **page** we render in M1 is a height page (the surface), but the underlying contract is `density(...)` in 3D, so the surface page is a *view* of a 3D field, not the field itself. This is what avoids the rewrite later.

### Why not full 3D voxel meshing everywhere right now?
Full volumetric surface extraction (Surface Nets / Dual Contouring) across an infinite world, with LOD/seams/collision on a 3D field, is the class of difficulty that wrecked past attempts. We don't take it on in M1. We render the **top surface** of the GPU field as a displaced page — fast, smooth, non-blocky — and add full-volume extraction only when caves arrive (later milestone). The field's GLSL doesn't change then; the renderer learns a new way to read it.

### The chosen path
- The field is **3D and density-based**, authored as **GPU compute (GLSL)** from the start. `density(...)` exists day one.
- M1's renderer asks the GPU for **height pages** (the surface) and displaces them onto a clipmap/ring mesh. The producer runs bounded work per frame; pages are held in a pool and the view is read-only over resident pages.
- Determinism/seams are proven by **reading pages back** (`§2.1`), not by eyeballing.

### 3.1 What we take from WG10, and what we don't
`WG10_MOUNTAIN_DEEP_DIVE.md` is **reference only** — a record of what the previous attempt learned, not a codebase to port and not a spine to inherit. WG13 starts over with a clean implementation.

- **We adopt the *shape* of the runtime** because it's the right one: GPU page producer → Rust facts (routes/carve/condition) → bounded page pool residency → read-only terrain view → explicit review modes → visual promotion gate. We rebuild it ourselves, cleanly, gated step by step — we do not copy WG10 files.
- **We adopt the *discipline*:** bounded pages per frame, never-black coverage (coarse blanket under fine, hold-last-good, display pins), accepted/candidate/diagnostic lanes kept separate, tests that encode the failure modes, visual gates as first-class.
- **We do not inherit WG10's accumulated baggage:** no porting its god-files, no WG11 spike-tune drift, no assumption that any WG10 number is correct until a WG13 gate re-proves it.

If a step's gate seems to require importing WG10 code wholesale, STOP and log it — reference means learn-from, not copy-from.

---

## 4. Rust / Godot split

**Decision: gdext (godot-rust) v0.5+. Rust owns the runtime (scheduling, residency, facts, tests) and drives the GPU field. GLSL compute owns the world math. GDScript owns thin scene assembly and editor-facing tuning only.**

- **GLSL compute (the field's implementation — Section 2.1, 3):**
  - The world math: `density`/`surface`/`material` per world point, producing pages.
  - Run via Godot's `RenderingDevice` compute pipeline.
  - This is the source of truth. There is no second (CPU) copy of this math.
- **Rust (the GDExtension):**
  - Everything around the field that must be deterministic and correct: seed derivation, page scheduling (bounded work/frame), residency/pool, the read-only terrain view, and later route/carve/condition **facts**.
  - Dispatching the compute, and **reading pages back** for the determinism/seam test gates.
  - Anything performance- or correctness-critical that isn't the per-point math.
  - Exposes a small set of Godot nodes/resources with `#[export]` tunables.
- **GDScript / Godot scene:**
  - The demo + review scenes (assembly only).
  - Wiring the viewer (camera/character) to the runtime node.
  - Exposed tuning knobs in the inspector (seed, render distance, recipe params).
  - **Nothing that decides world shape.**

### Why gdext and not a separate compute lib
A standalone Rust lib called over FFI fragments the code across a boundary you'd fight forever. gdext gives real Godot nodes, inspector integration, and **hot reload** — essential to the visual-gate workflow (`02_WORKFLOW.md`). As of v0.5 (March 2026) it is production-usable, hot-reload is tested in their CI, and extensions built for API ≥4.2 run on Godot 4.6.

### The one-implementation rule
- The GLSL field is the only implementation of the world math. We deliberately do **not** keep a parallel CPU version — that "two worlds that drift apart" duplication is the trap, not the safeguard.
- Determinism is enforced instead by **reading the GPU's own output back** and asserting on it (same seed → identical page bytes; adjacent page edges match). The real compute path is what the test exercises.
- A Rust-side render shader (`ring_displace`) only *presents* produced pages; it is never a second terrain generator. The render shader and the field-producer compute shader are separate and must stay separate.

---

## 5. Determinism & seeding (non-negotiable)

- One `u64` master seed for the world.
- Per-feature seeds are **derived** from the master seed by hashing (e.g. `hash(master_seed, "erosion")`), never by incrementing a shared counter, so adding a new feature never shifts the seed stream of existing features.
- Noise is sampled in **world coordinates**, never page/chunk-local coordinates. (Local-coordinate sampling is the #1 cause of seams — almost certainly a culprit in past attempts.) The compute shader receives each page's world-space origin and samples absolute world positions.
- A page's content depends ONLY on its world position + seed. Two players, two sessions, two machines: identical. This is also what later makes save/load trivial — you only store *diffs* from the deterministic baseline.

---

## 6. What "modular / plug-and-play" concretely means

The end goal: start a new game, and configure the world by editing a resource file and swapping an asset folder — never by touching core Rust.

- All tunables live in a **`WorldConfig` resource** (seed, render distance, chunk size, noise/biome/erosion params, asset references).
- Biomes are **data**, not code: a biome is a config entry (height rules, material refs, scatter rules), so adding "volcanic wasteland" is a new data row, not a new code path.
- Assets (your ComfyUI tileable textures, Meshy/TRELLIS models) are referenced by the config, bound by the renderer. Swapping them never touches the field.

If a feature can only be added by editing core Rust logic, it has been designed wrong — push the variability into data.

---

## 7. Glossary (so the agent and you use words the same way)

- **Field** — the pure data function defining the world. The "what."
- **Renderer / Streaming** — everything that turns field values into visible, collidable geometry. The "how it looks."
- **Chunk** — a finite region the renderer meshes and streams. An implementation detail of the renderer. The field does not know it exists.
- **Gate** — a visible or testable pass/fail condition that ends every step. See `02_WORKFLOW.md`.
- **Contract** — the function signatures in 2.1. Changing them is a big deal.
