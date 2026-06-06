# DRIFT LOG (append-only)

The human reads this FIRST every session. The agent appends here whenever it blocks, parks for a visual gate, needs a contract change, or averts a deviation. Entry format is defined in 02_WORKFLOW.md §3. Never delete entries; resolve them by adding a follow-up entry.

---

## [2026-06-06] — M1.7 design + M1.7a (heights retention) PASS
TYPE: (design decision + test gate passed, self-certified)
CONTEXT: User set the MINIMUM TARGET HARDWARE = RTX 3070+ (dev box stays RTX 5090 laptop). Recorded in 01_TOOLCHAIN §6/§7 (open item resolved) + project memory. Frame-budget gates must now hold on a 3070; the 5090 number is a dev baseline. M1.6's steady-state (2.4ms, ~7x under budget) is expected to clear 60fps on a 3070, but anything landing NEAR budget on the 5090 must be re-checked against the 3070 margin (margin discipline — we can't measure a 3070 from here).
M1.7 DESIGN (brainstormed, pillars applied, user approved): collision for NEAR (level-0) pages only, radius 1 (3x3 fine pages), async off-main-thread, reading the SAME resident page heights the view uses.
  - Verified Godot API facts (HeightMapShape3D): vertices 1 unit apart on X/Z -> scale body by cell_spacing; grid CENTERED on node origin -> body position = page center (same formula the mesh uses); map_data row-major width*depth with X=width,Z=depth -> our field's z*res+x array drops in untransposed.
  - Verified threading: build the HeightMapShape3D + StaticBody3D OFF the tree on a WorkerThreadPool task (thread-safe — data, not active tree), then call_deferred add_child on the main thread (the documented Godot pattern). On a 3070 this keeps the array->shape packing off the render/physics critical path.
  - Split (pillars): Rust PagePool OWNS heights (get_page_heights returns the cached array, no readback/re-dispatch); GDScript world_view OWNS collision as a renderer concern (00 §2.2). Rust never wrangles the Godot node tree across threads (avoids the "resource tweaked by multiple threads" footgun).
  - Sub-steps: M1.7a heights retention (test) -> M1.7b collision build (test) -> M1.7c capsule + F/G fly/walk toggle (VISUAL, park).
M1.7a RESULT: PASS (output-proven). PagePool now caches each page as ResidentPage{texture, heights} — ONE production fills both, so collision and the view can't disagree. New get_page_heights(L,gx,gz) returns that same array. m1_7a_heights_check.gd PASS: returned 16384 floats; texture R32F bytes BIT-IDENTICAL to get_page_heights (no drift); matches an independent FieldCompute production of the same page and differs for a different seed (discriminating); non-resident page returns empty (no fabrication). Eviction drops texture+heights together (one truth). cargo build clean.
CODEBASE STATE: green at the M1.7a commit.
WHAT I DID NOT DO: Did not start M1.7b's collision build yet. Did not add a second field path (collision reads the cached array). Did not change the Field/Renderer contract.

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

## [2026-06-06] — M1.5b live visual PASS
Human flew the live streaming world: "looks good, its fast." Confirmed the page checkerboard reads as intentional debug (not a defect) and that area scale is just WorldConfig tuning. M1.5b visually signed off. Two known cosmetic items, both deferred-by-design: (1) page_tint checkerboard is a debug aid — now a `show_page_tint` toggle; (2) faint per-page corrugation is the capped mesh subdivision (160/side) at close range — smooths with production subdivision / M1.6 LOD. Proceeding to M1.5c.

## [2026-06-06] — Discipline pass (organization + docs) + M1.5c WIP
TYPE: (refactor + cleanup, verified green) + BLOCKED-FOR-DECISION on M1.5c
DISCIPLINE PASS (done, all 4 prior gates still PASS — clean refactor):
  - De-duplicated GPU dispatch into rust/gdext/src/field_gpu.rs (the ONE place that runs the field on the GPU). FieldCompute (test oracle) and PagePool (runtime) both use it. field_compute.rs 234→~75 lines; page_pool lost its duplicate dispatch.
  - Deleted superseded view scripts (m1_3_view.gd, m1_4_grid_view.gd); world_view.gd is the single live view (demo.tscn runs it).
  - Split wg-13/tests (gates only) from wg-13/captures (screenshot tools); removed stale one-off capture scripts; renamed the keeper to captures/stream_capture.gd.
  - _captures/ PNGs now gitignored (regenerable scratch; gate evidence = DRIFT_LOG narrative + live scene).
  - Wrote 04_CODE_MAP.md: index of files, conventions, and how to run every gate. Added to README read-order.
  - page_tint is now a show_page_tint toggle on world_view.
M1.5c (multi-level clipmap) built but never-black coverage test (m1_5c_coverage_check.gd) is RED — and correctly so: it exposed that the coarse blanket can be BUDGET-STARVED. With num_levels=2, ring_radius=3, a coarse ring is 49 pages; at a bounded few-per-frame it can't fully populate before being relied on, so under fast motion some fine cells have neither fine nor coarse coverage → would show black. The coverage GEOMETRY is correct (equal-radius coarse ring reaches 2× as far, covers the fine ring); the GAP is throughput/budget allocation across levels.
DECISION NEEDED (surfaced to human): how to guarantee the coarse blanket is always complete — (a) coarse levels produced unbounded/eagerly (few & cheap), (b) per-level budget with coarse guaranteed first, (c) shrink coarse ring radius. Did NOT pick unilaterally; this sets the streaming budget model.
CODEBASE STATE: green and compiling (the RED is a test asserting a not-yet-satisfied property, intentionally committed red to track the gap honestly).
WHAT I DID NOT DO: Did not fake the coverage gate green. Did not change the contract.

## [2026-06-06] — M1.5c RESOLVED + M1.5 PARKED
TYPE: coverage gate now PASS (self-certified); full M1.5 PARKED-FOR-VISUAL
FIX (human-approved, after a plain-language explanation): the never-black gap was budget mis-allocation, not a perf wall. Coarse blanket pages are cheap and few; capping them like expensive fine pages starved the blanket → black under fast motion. Fix: coarse levels (>0) produced EAGERLY (request_page_eager, unbounded); only the finest level (0) stays bounded per frame. The budget caps the expensive detail (which causes stutter), not the cheap blanket.
RESULT: m1_5c_coverage_check PASS — with a deliberately tight budget that produced 0/49 fine pages, all 49 coarse blanket pages were produced and every fine cell stayed covered → never black. All 5 gates green (M1.2/1.4/1.5a/1.5b/1.5c). Live capture continuous to horizon, no black.
M1.5 milestone now awaits its FULL live visual gate (human): fly 5+ min, confirm no black ever (incl. fast motion), no stutter crossing page boundaries, memory flat. Launch: `& $env:GODOT --rendering-driver vulkan --path "D:\world gen 13\wg-13"` (F5), WASD + right-drag, Shift to boost — try to outrun the streamer and confirm you see blurry-coarse, never black.
CODEBASE STATE: green at the M1.5c commit.
WHAT I DID NOT DO: Did not start M1.6. Did not change the contract.

## [2026-06-06] — M1.6 LOD to horizon (frame gate PASS) + measurement lesson
SCALED to ~30km: num_levels 2 -> 6 (each level doubles span; 6 levels @ radius 3, base 508m -> coarsest reaches ~49km, 30km goal with margin). Camera far + depth fog matched to the loaded extent so the coarsest edge fades into sky (no hard boundary — WG10 lesson). Verified the clipmap value: 6 levels cover ~49km where fine-only would need thousands of pages.
FRAME-TIME GATE — measurement lesson (systematic debugging): first gate FAILED (p99 240ms) because it measured during the one-time STARTUP fill, AND because Performance.TIME_PROCESS (script-only) / TIME_FPS (smoothed) both HID the truth. Switched to true per-frame `delta` (vsync off) + warm up past the transient. Steady-state PASS: median 2.38ms (420fps at script res), p99 2.68ms << 16.6 budget, flying fast with constant streaming. The architecture has huge headroom.
FIX THAT FAILED (reverted, not stacked): tried capping eager coarse production to smooth startup. It BROKE never-black (coverage test red — coarse ring couldn't fill in one frame) AND made startup WORSE (spread the work over more frames; total 483->678ms). Diagnosis: the ~150ms worst frame is one-time engine/shader/pipeline init, NOT the eager page burst. Reverted to unbounded eager; all gates green again. Removed dead eager-cap field/setter (no slop).
STARTUP TRANSIENT (known, deferred): ~150ms worst frame, ~2 frames over budget at launch, then steady. One-time LOAD lag, not stutter-on-movement; proper fix is async page production / loading screen (later, not M1.6). Documented 01_TOOLCHAIN §6/§7.
M1.6 frame gate PASS. Live horizon awaits human visual (reads far, transitions not broken).

## [2026-06-06] — Launch method solved + M1.5 milestone PASS
LAUNCH METHOD (root-caused): launching the windowed scene for the user kept "disappearing." Root cause: Start-Process -PassThru and bash '&' return a DETACHED STUB pid, so Get-Process -Id tracked the wrong process and reported "gone" while real Godot ran — and the window didn't reliably surface. Verified via session check that the agent shell is SessionId 1 (same interactive console as the user — NOT service/session-0 isolation), so a window CAN appear. Fix: launch via a PowerShell background Job; confirmed real Godot pid in session 1 with a non-zero MainWindowHandle and title "wg13 (DEBUG)" — visible window on the user's desktop. Baked into run.ps1 (the agent launches scenes this way going forward; user no longer opens the editor unless tuning/rebuilding).
M1.5 MILESTONE PASS: user flew the live world: "looks good." Confirmed clean (no z-fighting, no black, streams fine). Noted slight LOD seams between fine ring and coarse annulus — correctly identified by the user as a later roadmap item (geomorph blending, explicitly deferred in ROADMAP "NOT scheduled"; M1.5 gate "no cracks/black" is met, the seam is shading softness not a crack). M1.5 COMPLETE.
NEXT: M1.6 (LOD to 30km horizon) — scale num_levels on the clipmap + frame-time gate.

## [2026-06-06] — Pillar reorder + M1.5 implementation complete
PILLAR CORRECTION: user intended Quality as the #1 pillar; docs still had the old order (Survivability #1, Quality last) and I'd been applying it. Reconciled: Quality #1 = "do it right, no slop" (not "chase visuals at any cost"). Order now Quality > Survivability > Modularity > Performance. This ALIGNS with the attempt #1-12 lesson (polish on a broken base IS slop). Committed (00 §1, §1.1, README).
COLORATION-BAND (human spotted in live fly): root-caused to the debug checkerboard (page_tint) differing between fine and coarse rings — confirmed by capturing with tint off (band largely gone). Defaulted show_page_tint = false (clean look). The FAINT residual is the genuine LOD detail difference: coarse pages sample height at 2x spacing, so they inherently carry less detail and shade smoother. A "normal tweak" can't recover detail that isn't in the coarse data — the only real fix is geomorph blending across the ring boundary.
DECISION (Quality-first applied): defer the LOD seam to the geomorph pass. Reasoning under the NEW order: geomorph is roadmap-scheduled as a later pass; doing it piecemeal now would be throwaway = SLOP, which Quality #1 forbids. M1.5's gate is "no cracks, no black" — both met (the seam is shading softness, not a crack). So deferring is the high-quality move here, not a quality compromise.
M1.5 IMPLEMENTATION COMPLETE: a/b/c done, all 6 test gates green, z-fighting fixed, never-black holds, tint clean by default. Awaits only the human's full live fly-through (5+ min: no black at speed, no stutter, flat memory) to tag the milestone.
CODEBASE STATE: green.
WHAT I DID NOT DO: Did not pull geomorph forward (would be slop). Did not start M1.6.

## [2026-06-06] — M1.5c z-fighting fixed (annulus clipmap)
TYPE: bug fix (systematic debugging) — human spotted it in live fly
SYMPTOM: human flying the live world saw blotchy patches + ghost contours on near terrain (screenshot). Read as "detail shifts/changes of the same area."
ROOT CAUSE (not guessed — traced): world_view drew the coarse blanket AND fine pages over the same ground, separated by only a 0.5m Y bias, relying on render_priority. render_priority does NOT stop opaque depth-fighting, and 0.5m is nothing at 240m terrain scale → Z-FIGHTING. The design ("draw both, bias") was the wrong mechanism, not a wrong constant.
DECISION (via pillars): annulus clipmap — each level draws only the region the finer level doesn't cover; no two levels overlap → no z-fight by construction. All four pillars + build-it-right-once point here, and it's exactly M1.6's 30km LOD structure (built once). Documented in MILESTONE_1 M1.5.
FIX (GDScript only, no Rust rebuild): _update_annulus_visibility() hides a coarse page wherever its full finer-level footprint is displayed; shows it over not-yet-loaded holes (never-black preserved). Removed the y_bias/render_priority hacks. Did the coverage decision in the VIEW (it owns display), not the pool — reverted a premature has_page pool method.
VERIFY: new m1_5c_overlap_check.gd PASS (no visible coarse page overlaps a fully-covered fine area; annulus = 25 fine + 21 coarse ring). Coverage (never-black) test still PASS. All 6 gates green. Capture: blotches gone, surface clean.
TEST DISCIPLINE NOTE: first overlap-test run "failed" counting INSTANCED (not visible) coarse pages — fixed the test to count .visible meshes (a hidden mesh can't z-fight). Did not declare victory on the wrong measurement.
FINDING (01_TOOLCHAIN §3): the open Godot editor locks wg13.dll; cargo build fails until it's closed. GDScript/shader changes need no rebuild.
NOTE on the whitish wash the human also asked about: that's the placeholder height-tint shader saturating high + no textures yet (M3). Cosmetic placeholder, legibility improvement optional/deferred.
CODEBASE STATE: green at this commit.
WHAT I DID NOT DO: Did not start M1.6. Did not change the contract.
