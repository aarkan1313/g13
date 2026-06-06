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
