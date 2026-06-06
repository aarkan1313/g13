# Milestone 1 — Contiguous Infinite Land

**Goal:** Stand at spawn and walk in any direction forever over continuous, smooth, non-blocky terrain that streams in around you, with no seams, no holes, no stutter. Untextured (flat/vertex color is fine). This is the foundation everything else stands on.

**Definition of done (the milestone gate):**
> Launch the demo scene. Walk/fly 5+ minutes in one direction. Terrain is continuous to the horizon, no gaps between chunks, no popping that reads as broken, no holes you fall through, memory stable (chunks unload behind you), 60 FPS on the target midrange machine.

**Out of scope for M1 (do NOT do these — they're later milestones):** textures, biomes, erosion, caves, water, collision-perfect physics beyond "you don't fall through," scatter, LOD geomorphing polish. Get contiguous land first.

Each step below is small on purpose and ends in a gate. Follow `02_WORKFLOW.md`.

---

### M1.1 — Project skeleton compiles and loads
- Create the gdext Rust crate (v0.5+, `compatibility_minimum = 4.2`), the `.gdextension` file, and a minimal Godot 4.6 project.
- One Rust node registered (e.g. `WorldRoot`) that prints to the Godot console on `_ready`.
- **GATE (visual):** Open Godot, run the scene, see the print. Hot reload works: change the print string, rebuild, see new string without restarting the editor.

### M1.2 — The field crate exists and is deterministic
- Create the **field** as its own Rust module/crate with no Godot dependency at all.
- Implement `sample_surface(world_xz, seed)` using world-space multi-octave noise (fBM). `sample_density` may be a thin wrapper around the surface for now (`density = world_y - surface_height`), but the 3D signature exists.
- Write unit tests: determinism (same input → same output across many trials, against a stored golden value), and continuity (adjacent samples don't jump discontinuously).
- **GATE (test):** `cargo test` passes determinism + continuity. No Godot involved.

### M1.3 — One chunk renders
- Renderer side: a `Chunk` that samples the field over a grid and builds a single `ArrayMesh` (surface extraction = sample the surface heights). Flat shading or vertex color, no textures.
- Place exactly one chunk at origin in the scene.
- **GATE (visual):** A single patch of smooth, non-blocky terrain visible at origin. Shape responds to changing the seed/noise params via inspector (hot-tunable).

### M1.4 — A grid of chunks with NO seams
- Render a fixed NxN grid of chunks around origin.
- Because the field is sampled in world coordinates (not chunk-local), neighboring chunks must share exact edge vertices. Verify this.
- **GATE (visual):** NxN terrain with zero visible cracks/gaps at chunk boundaries. Walk to a boundary and look closely — seamless.
- **GATE (test):** a test asserting that the shared edge vertices of two adjacent chunks have identical positions.

### M1.5 — Streaming: chunks load/unload around a moving viewer
- Add a viewer (free camera or simple character). As it moves, load chunks within render distance, unload beyond it. Use `WorkerThreadPool` so meshing happens off the main thread.
- **GATE (visual):** Move in any direction; new terrain appears ahead, old terrain disappears behind. No main-thread freeze/stutter when crossing chunk boundaries (this was an explicit past failure — watch for it). Move 5 minutes; memory stays flat (no leak).

### M1.6 — LOD so "infinite" is actually performant
- Distant chunks use lower-resolution meshes. Simple distance-based LOD tiers. Handle seams between LOD levels with skirts (drop a vertical edge) for now — geomorph polish is later.
- **GATE (visual):** Render distance large enough to read as "to the horizon" at 60 FPS on target hardware. LOD transitions don't read as broken (minor popping acceptable at this milestone; cracks are NOT).
- **GATE (test):** frame time stays under budget (e.g. <16.6ms) while flying at speed across many chunk loads — measured, not eyeballed.

### M1.7 — Minimal collision so you stand on it
- Generate `HeightMapShape3D` collision for near chunks only (collision LOD: far chunks need none). Async generation.
- **GATE (visual):** A character can walk on the terrain and not fall through, anywhere, including freshly streamed chunks.

### M1.8 — Milestone gate
- Run the full Definition of Done above.
- **GATE (visual + test):** all conditions met. Tag `m1-complete`.

---

## Notes for the agent
- If world-space sampling and seamlessness fight you at M1.4, the bug is almost always chunk-local coordinates or a float-precision issue far from origin. Log it; do not "fix" it by abandoning world-space sampling — that's a contract-level decision.
- Far-from-origin float precision: if terrain degrades thousands of units out, log it as a known issue for a precision strategy (e.g. origin rebasing) — do NOT redesign the field unsupervised.
- Keep `sample_density`'s 3D signature even though M1 only uses the surface. Deleting it "because it's unused" would break Milestone (caves) later. This is exactly the kind of well-meaning cleanup that causes future refactors.
