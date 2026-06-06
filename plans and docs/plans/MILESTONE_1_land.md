# Milestone 1 — Contiguous Infinite Land (GPU-first)

**Goal:** Stand at spawn and fly in any direction forever over continuous, smooth, non-blocky terrain that streams in around you, with no seams, no holes, no stutter, and **never any black/missing ground**. Untextured (flat/vertex color is fine). The terrain is produced by a **GPU compute field** (per `00_ARCHITECTURE.md §2.1, §3`) and presented through a bounded page pool + read-only clipmap view.

**Definition of done (the milestone gate):**
> Launch the demo scene. Fly 5+ minutes in one direction. Terrain is continuous to the horizon, no seams between pages, no popping that reads as broken, no holes you fall through, **no black gaps ever** (coarse coverage always shows through while fine pages load), memory stable (pages evict behind you), frame time under budget on the named target machine.

**Out of scope for M1 (do NOT do these — later milestones):** mountains/recipes beyond a simple test field, textures, biomes, erosion, caves, water, scatter, LOD geomorph polish, route/carve facts. Get the *infinite GPU shell* solid first. The interesting field math (mountains, biomes) lands later, on a shell already proven to stream and not crack.

**Architecture reminders (read before coding):**
- The field is **GLSL compute, GPU is source of truth** (`00 §2.1`). No CPU copy of the world math.
- Pages are sampled in **world coordinates** (`00 §5`). The compute shader gets a page's world origin; it samples absolute positions. Page-local sampling = seams = STOP and log.
- The terrain view is **read-only over resident pages** — the render binding path never triggers compute (`WG10` discipline, rebuilt clean).
- WG10 is **reference only**. Rebuild every piece; copy no files. No WG10 number is trusted until a WG13 gate re-proves it.

Each step is small on purpose and ends in a gate. Follow `02_WORKFLOW.md`. Build/run/test/capture commands are in `01_TOOLCHAIN.md`.

---

### M1.1 — Project skeleton + gdext loads, hot reload works
- Create the gdext Rust workspace (`rust/`): a `gdext` crate depending on `godot` (v0.5+, `compatibility_minimum = 4.2`) and an empty `field` crate placeholder. Create `wg-13/wg13.gdextension` pointing at the built lib.
- Register one Rust node (`WorldRoot`) that prints to the Godot console on `_ready`.
- Pin the exact `godot` crate version; record it back into `01_TOOLCHAIN.md §1`.
- **GATE (visual):** Open Godot 4.6.2, run the scene, see the print. Change the print string, `cargo build`, see the new string **without restarting the editor** (hot reload proven). Park for visual per `02_WORKFLOW.md`; capture not required (it's a console string).

### M1.2 — One GPU page, produced and read back deterministically
- Stand up a `RenderingDevice` compute pipeline that runs a trivial field GLSL (e.g. `height = f(world_xz, seed)` with simple fBM) over **one page** at world origin, writing to a buffer/texture.
- Rust reads the page back to CPU.
- Tests (run the real compute path): **determinism** — produce the origin page twice, same seed → identical bytes; produce with a different seed → different bytes. **Continuity** — adjacent samples within the page don't jump discontinuously.
- **GATE (test):** `cargo test` (Rust orchestrating the GPU readback) passes determinism + continuity. No rendering yet, no eyeballing.

### M1.3 — One page on screen (the first visual proof)
- Displace that one produced height page onto a subdivided mesh via a `ring_displace` render shader. One page, one mesh, one camera, one light.
- Capture a PNG (`01_TOOLCHAIN.md §5`).
- **GATE (visual):** A single patch of smooth, non-blocky terrain at origin, shape responding to seed/noise params via inspector (hot-tunable). PNG written; park for visual.

### M1.4 — Pages tile with NO seams
- Produce and display a fixed NxN block of pages around origin (still static, no streaming yet). Because pages sample world coordinates, the shared edge between adjacent pages must be identical.
- **GATE (test):** a readback test asserting the shared edge row/column of two adjacent pages matches to the bit (same seed).
- **GATE (visual):** NxN terrain with zero visible cracks/gaps at page boundaries; fly to a boundary and look closely — seamless. PNG written; park for visual.

### M1.5 — Bounded page pool + clipmap rings + read-only view (the infinite shell)
- Build the runtime spine, clean: a **bounded page pool** (max new pages/frame), **clipmap rings** at multiple levels (coarse levels blanket under fine), and a **read-only `TerrainView`** that binds only resident pages and never triggers compute in the bind path.
- **Never-black coverage is structural:** coarse blanket under fine; missing fine pages hide and let coarse show through; hold-last-good for the coarsest; display pins so visible pages can't be evicted underneath the mesh.
- Add a free-fly camera. As it moves, the pool acquires pages ahead (bounded) and evicts behind.
- **GATE (visual):** Fly in any direction; new terrain appears ahead, old evicts behind. **No black ever.** No main-thread freeze/stutter crossing page boundaries (explicit past failure — watch for it). Fly 5 minutes; memory stays flat. PNG + a short capture sequence written; park for visual.
- **GATE (test):** pool invariants — never exceeds max pages/frame; never evicts a pinned/displayed page; coverage rule holds (every visible cell has at least a coarse page).

### M1.6 — LOD to the horizon at frame budget
- Tune ring levels / page resolution so render distance reads as "to the horizon." Handle inter-level seams with skirts for now (geomorph polish is later). Minor popping acceptable at this milestone; cracks and black are NOT.
- **Name the target hardware** (resolve the open item in `01_TOOLCHAIN.md §6`) before trusting the number.
- **GATE (test):** a scripted fly-path at fixed speed samples frame time; max and 99th-percentile under budget (16.6 ms) on the named machine. Measured, not eyeballed (`01_TOOLCHAIN.md §6`).
- **GATE (visual):** horizon reads as far; LOD transitions don't read as broken. Park for visual.

### M1.7 — Minimal collision so you stand on it
- Generate collision (e.g. `HeightMapShape3D`) for **near pages only** (far pages need none), async, off the main thread. Collision reads the same resident page heights the view uses — never a second field path.
- **GATE (visual):** a character walks on the terrain and doesn't fall through, anywhere, including freshly streamed pages. Park for visual.

### M1.8 — Milestone gate
- Run the full Definition of Done above.
- **GATE (visual + test):** all conditions met. Tag `m1-complete`.

---

## Notes for the agent
- **Seams or determinism fighting you (M1.4):** the bug is almost always page-local coordinates or a precision issue, never a reason to abandon world-space sampling. That's a contract-level decision — log it, don't "fix" it by changing the contract.
- **Black flicker while streaming (M1.5):** that's a coverage-rule violation (a visible cell with no coarse page, or a pinned page evicted). Fix the pool invariant; don't paper over it by slowing the camera.
- **GPU readback is for tests and collision, off-frame.** Never block a render frame on a full readback. If a gate seems to need per-frame readback, STOP and log it.
- **Keep `density(...)`'s 3D meaning** even though M1 only renders the surface page. Collapsing the field to pure 2D height "because that's all M1 shows" would break caves later. Same well-meaning cleanup that causes future rewrites.
- **Far-from-origin float precision:** if terrain degrades thousands of units out, log it as a known issue for a precision strategy (origin rebasing) — do NOT redesign the field unsupervised.
