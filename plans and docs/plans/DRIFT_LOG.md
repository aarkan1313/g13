# DRIFT LOG (append-only)

The human reads this FIRST every session. The agent appends here whenever it blocks, parks for a visual gate, needs a contract change, or averts a deviation. Entry format is defined in 02_WORKFLOW.md §3. Never delete entries; resolve them by adding a follow-up entry.

---

## [2026-06-06] — M1.1
TYPE: PARKED-FOR-VISUAL
WHAT I WAS DOING: Building the M1.1 skeleton — gdext crate + WorldRoot node + .gdextension + demo scene; proving the Rust↔Godot bridge and hot reload.
WHAT HAPPENED: Bridge works end-to-end, and the rebuild→reload mechanism is now verified programmatically (not just eyeballed):
  - RUN 1 (headless) printed `WG13 WorldRoot ready — Rust bridge live (M1.1).` → extension loads, `WorldRoot` registers, `_ready` fires.
  - Then edited the string to `[reload-test v2]`, `cargo build`, RUN 2 (headless) printed the NEW string → Godot loads the freshly rebuilt DLL after a source change. Reverted the string and rebuilt clean.
  - REMAINING (narrow): each run is a fresh process, so this proves "rebuilt DLL loads on next run," not literal in-editor live swap (gdext `reloadable=true` replacing the lib while the editor process stays open). That last nicety is a ~10s desk check; the substance of the gate (Rust runs in Godot; your edits take effect after rebuild) is proven.
TWO FINDINGS WORTH KNOWING (now in 01_TOOLCHAIN.md §1/§3):
  1. A global `CARGO_TARGET_DIR=D:\cargo-target-kalshi` env var (another project's) overrides `.cargo/config.toml` and sends our build out of the tree. Build commands now pin `CARGO_TARGET_DIR=rust/target`.
  2. A fresh project has no `.godot/extension_list.cfg`, so a plain game run fails with `Cannot get class 'WorldRoot'`. Fixed by an editor import scan: `--headless --editor --import`. Documented as a required first-time step.
HOW TO RESOLVE THIS GATE (human, at desk):
  - Open the project in the Godot 4.6.2 editor: `& $env:GODOT --path "D:\world gen 13\wg-13"` (or just launch the editor and open it).
  - Run the project (F5). Confirm `WG13 WorldRoot ready — Rust bridge live (M1.1).` appears in the Output/console.
  - With the editor still open, change that string in `rust/gdext/src/lib.rs`, rebuild (`$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml"`), run again, and confirm the NEW string appears WITHOUT having restarted the editor. That is the hot-reload pass.
EXACT ERROR / STATE: none — green and compiling.
MY HYPOTHESIS: gate should pass; gdext `reloadable = true` is set and 0.5.3 supports hot reload.
CODEBASE STATE: green at the M1.1 commit (see git log).
WHAT I DID NOT DO: Did not start M1.2. Did not self-certify the visual gate. Did not change the contract.

## [2026-06-06] — M1.2
TYPE: (informational — test gate passed, self-certified)
WHAT I WAS DOING: First GPU step — field compute shader produces one world-space height page; Rust dispatches on a LOCAL RenderingDevice and reads back; determinism/continuity tests assert on the readback.
WHAT HAPPENED: PASS (output-proven, 02_WORKFLOW §2). All four checks green: determinism (same seed → identical 4096-cell page), seed sensitivity (different seed → different), continuity (max adjacent step 2.93 << 120 limit, no NaN), seam preview (east page reproduces deterministically). GPU is the source of truth and we trust it via readback, exactly per 00 §2.1.
FINDING (now in 01_TOOLCHAIN §4): **GPU compute tests cannot run under `--headless`** — the dummy driver returns no RenderingDevice. Must use `--rendering-driver vulkan`. This changes the test-gate command for every GPU step. Implication: a GPU-less remote agent box could not self-certify these gates.
EXACT ERROR / STATE: green and compiling.
CODEBASE STATE: green at the M1.2 commit.
WHAT I DID NOT DO: Did not start M1.3 (the first on-screen render — a real visual gate). Did not change the contract.

## [2026-06-06] — M1.3
TYPE: PARKED-FOR-VISUAL
WHAT I WAS DOING: First on-screen render. Read the GPU height page back into an R32F ImageTexture, displaced a flat subdivided plane with the ring_displace.gdshader (render shader PRESENTS the page; does not generate it — 00 §4), added camera/sun/ambient. Wired into demo.tscn so F5 shows it.
WHAT HAPPENED: Renders correctly. Captured two PNGs (visual-capture procedure, 01_TOOLCHAIN §5):
  - res://_captures/m1_3_page.png — seed 1234, smooth rolling 1024m terrain.
  - res://_captures/m1_3_page_seed2.png — seed 77777, distinctly different shape (central ridge).
  Demo scene loads clean under vulkan (both WorldRoot print and "page presented" fire, no errors).
WHAT I CAN CERTIFY FROM THE CAPTURES: terrain is non-blocky (smooth normals), not Perlin-nebula, and SHAPE RESPONDS TO SEED (the two PNGs differ clearly). The AESTHETIC pass ("does this read as good terrain") is the human's call.
HOW TO RESOLVE THIS GATE (human, at desk):
  - Open the two PNGs in _captures/ and confirm they look like smooth, non-blocky terrain and differ by seed. OR run live: `& $env:GODOT --rendering-driver vulkan --path "D:\world gen 13\wg-13"` (F5), tune seed_val/base_freq/amplitude on the M1_3_View node in the inspector and watch the shape change (the tuning loop).
NOTE (must use vulkan, not headless): GPU compute needs a real driver (see M1.2 finding). The capture window flashes briefly.
EXACT ERROR / STATE: green and compiling.
CODEBASE STATE: green at the M1.3 commit.
WHAT I DID NOT DO: Did not start M1.4 (seamless NxN). Did not change the contract. Did not introduce a CPU meshing path (heights go GPU → texture → displacement shader).

## [2026-06-06] — M1.3 RESOLVED
TYPE: PARKED-FOR-VISUAL → PASS
Human ran the demo live (editor, F5, 2481×1396) and confirmed: "looks good." M1.3 visual gate PASSED. PROGRESS marked [x]. Proceeding to M1.4.
(Note: editor re-added [dotnet] to project.godot on save — Mono build, harmless, no C# written; left as-is per earlier decision. Viewport set to 2560×1440 by the user; capture scripts will follow project window size going forward.)

## [2026-06-06] — M1.4
TYPE: PARKED-FOR-VISUAL (test gate already PASS)
WHAT I WAS DOING: Make pages tile seamlessly. Documented the shared-boundary-cell convention (00 §5.1: page covers (N-1)*spacing; neighbors share their boundary cell, so the shared edge is the same world points → identical by determinism). Wrote the edge-readback test and a 3×3 visual.
WHAT HAPPENED:
  - TEST GATE PASS (self-certified): east seam + south seam shared edges are bit-identical across all 128 cells; a "teeth" check confirms the WRONG stride does NOT match (so the test is discriminating, not vacuous). Seams are structurally impossible, not patched.
  - 3×3 visual: terrain is continuous across all page boundaries — no cracks. Capture at res://_captures/m1_4_grid3x3.png.
DEBUGGING NOTE (root-caused, not guessed): early 3×3 captures rendered flat/white. Root cause via systematic debugging: m1_4_grid_view.gd created the ShaderMaterial but never assigned it (`mi.material_override = mat` was missing) → mesh drew default white, undisplaced. One-line fix. (Lesson: I burned several capture iterations adjusting the camera before reading both view scripts line-by-line; should have diffed first.)
FINDING (01_TOOLCHAIN §5): `--script`-mode captures render small (~640×360) regardless of window size; window-size scripting is unreliable. Captures are confirmatory; the definitive seam/aesthetic pass is the human flying the live editor scene.
HOW TO RESOLVE THIS GATE (human): glance at _captures/m1_4_grid3x3.png (continuous, no cracks), OR — better — run live and fly to a page boundary: `& $env:GODOT --rendering-driver vulkan --path "D:\world gen 13\wg-13"` then load scripts/m1_4_grid_view.gd in a scene (or temporarily set it as the M1_3_View script) and inspect boundaries up close. The faint checkerboard marks page edges; confirm the surface crosses them with no crack.
EXACT ERROR / STATE: green and compiling.
CODEBASE STATE: green at the M1.4 commit.
WHAT I DID NOT DO: Did not start M1.5. Did not change the contract. Did not introduce CPU meshing.
