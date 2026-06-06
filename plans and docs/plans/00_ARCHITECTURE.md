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

A pure, deterministic, side-effect-free function:

```
sample_density(world_pos: Vec3, seed: u64) -> f32      // < 0 = solid, > 0 = air (signed distance-ish)
sample_surface(world_xz: Vec2, seed: u64) -> f32       // convenience: surface height at x,z
sample_material(world_pos: Vec3, seed: u64) -> MaterialId
```

Properties that MUST hold forever:

- **Deterministic:** same input + same seed → same output, always, on any machine, in any session. No global mutable state. No time dependence. No frame dependence.
- **Chunk-agnostic:** the field does not know what a chunk is, how big it is, or that meshing exists. You can query any point in continuous space.
- **3D-capable from day one:** even though Milestone 1 only reads the *surface*, the canonical model is a 3D density field. This is what makes caves, overhangs, and editable terrain possible later WITHOUT a rewrite. (See Section 3 for why this is the chosen representation.)
- **Pure Rust, GPU-mirrorable:** the field is authored in Rust and written so its math can also run as a GLSL/compute shader. CPU and GPU paths must produce matching results (within float tolerance). The CPU path is the source of truth and the test oracle.
- **Independently testable:** the field has unit tests that never open Godot. "Does height at (1000, 1000) equal X" is a test, not a thing you check by looking at the screen.

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

## 3. Terrain representation: density field, surface-only rendering (for now)

**Decision: A signed-distance / density field is the canonical data model from day one. Milestone 1 renders only its surface layer as a heightfield-style mesh. Caves/overhangs are unlocked later by sampling the full 3D field — with no change to the field's contract.**

### Why not pure heightmap?
A heightmap (`height = f(x,z)`) is simpler and faster, but it structurally cannot represent caves, overhangs, or arbitrary editable terrain. Choosing it now would guarantee a rewrite later. Rejected for that reason.

### Why not full voxel meshing everywhere right now?
Full 3D surface extraction across an infinite world (with LOD, seams, and collision on a 3D field) is exactly the class of difficulty that has wrecked previous attempts. It violates Pillar #1 (Survivability) to take it all on at once.

### The hybrid (chosen)
- The field is **3D and density-based** from the start. `sample_density` exists from day one.
- Milestone 1's renderer extracts only the **top surface** of that field — effectively asking "where does density cross zero, scanning down from the sky?" — and meshes it like a heightfield. This is fast, gives gorgeous smooth (non-blocky) land, and has none of the full-voxel complexity.
- When caves arrive (later milestone), the renderer gains a full-volume surface-extraction path (**Surface Nets / Dual Contouring** — smooth, non-Minecraft) for chunks that contain interior air pockets. The field does not change. Only the renderer learns a new way to read it.

This gives the AAA, non-blocky, cave-capable future without paying its full cost on attempt #13.

### 3.1 CPU source of truth vs the WG10 GPU page machinery (resolving the tension)

`WG10_MOUNTAIN_DEEP_DIVE.md` documents a GPU-centric runtime: GPU page producers, clipmap rings, a bounded page pool, off-frame readback. That is **not** how WG13 starts, and the two must not be confused:

- **WG13 M1 starts CPU-first.** The Rust `field` (this section's contract) is the **source of truth**, sampled on the CPU. The renderer meshes the surface into per-chunk `ArrayMesh`es on worker threads. Simple, debuggable, no GPU/CPU two-worlds problem. This honors Pillar #1 (Survivability).
- **The WG10 GPU page-pool spine is a *later performance path*, not a foundation.** When CPU meshing stops meeting the perf budget at the render distance we want, *then* we consider mirroring the field math into a GPU compute path — and `00 §4`'s rule applies: the CPU field stays the oracle, the GPU path must match it within tolerance, verified by a test. We never start with two implementations.
- **What we copy from WG10 now is the *discipline*, not the machinery:** bounded work per frame, never-black coverage, read-only terrain view, explicit review modes, visual promotion gates. The discipline is portable to a CPU renderer.

If a step ever seems to require building the GPU page pool to pass an M1 gate, STOP and log it — that is a foundation-level decision, not an in-step fix.

---

## 4. Rust / Godot split

**Decision: gdext (godot-rust) v0.5+. Rust owns the field and the meshing. GDScript owns scene orchestration and editor-facing tuning.**

- **Rust (the GDExtension):**
  - The World Field (Section 2.1)
  - Surface extraction / meshing
  - Chunk streaming math and the WorkerThreadPool jobs
  - Anything performance-critical or correctness-critical
  - Exposes a small set of Godot nodes/resources with `#[export]` tunables
- **GDScript / Godot scene:**
  - The test/demo scene
  - Wiring the viewer (camera/character) to the streaming node
  - Exposed tuning knobs in the inspector (seed, render distance, noise params)
  - Nothing that decides world shape

### Why gdext and not a separate compute lib
A standalone Rust lib called over FFI fragments the code across a boundary you'd fight forever. gdext gives real Godot nodes, inspector integration, and **hot reload** — which is essential to the visual-gate workflow (`02_WORKFLOW.md`). As of v0.5 (March 2026) it is production-usable, hot-reload is tested in their CI, and extensions built for API ≥4.2 run on Godot 4.6.

### GPU compute
- Use Godot's `RenderingDevice` compute pipeline for the GPU field path and (later) erosion.
- **Rule:** the CPU Rust field is the source of truth. The GPU path must match it within tolerance, verified by a test. Never let the GPU path drift into being a separate, second implementation of the world — that is two worlds, and they will disagree.

---

## 5. Determinism & seeding (non-negotiable)

- One `u64` master seed for the world.
- Per-feature seeds are **derived** from the master seed by hashing (e.g. `hash(master_seed, "erosion")`), never by incrementing a shared counter, so adding a new feature never shifts the seed stream of existing features.
- Noise is sampled in **world coordinates**, never chunk-local coordinates. (Chunk-local sampling is the #1 cause of seams — it was almost certainly a culprit in past attempts.)
- A chunk's content depends ONLY on its world position + seed. Two players, two sessions, two machines: identical. This is also what later makes save/load trivial — you only store *diffs* from the deterministic baseline.

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
