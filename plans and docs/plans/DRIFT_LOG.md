# DRIFT LOG (append-only)

The human reads this FIRST every session. The agent appends here whenever it blocks, parks for a visual gate, needs a contract change, or averts a deviation. Entry format is defined in 02_WORKFLOW.md §3. Never delete entries; resolve them by adding a follow-up entry.

---

## [2026-06-06] — M2.1 climate fields implemented — test gate PASS, visual gate PARKED
TYPE: PARKED-FOR-VISUAL (output-provable core self-certified; 14/14 gates green)
WHAT I WAS DOING: Built M2.1 per M2_DESIGN (decisions were already locked, so I built, didn't re-decide): temperature + moisture climate fields in the GLSL, produced in the SAME GPU dispatch as height, visualized by a V-key view-mode toggle.
WHAT I DID (the data path, plain language for the human):
  - field_height.glsl: the page now carries 3 floats/cell INTERLEAVED [height, temp, moisture] (was 1). Temperature = a smooth latitude band on world-Z (warm equator -> cold poles, ~120 km period via a smoothstep triangle wave) MINUS altitude cooling (high ground colder; sets up M2.3) PLUS gentle low-freq noise (so bands aren't perfect stripes). Moisture = independent low-freq world-space noise. Per-feature seeds DERIVED by hashing the master seed (00 §5), so temp/moist are decorrelated but reproducible. All sampled in WORLD coords -> deterministic + seamless, same as height.
  - field_gpu.rs: dispatch_page now reads back the interleaved buffer and DEINTERLEAVES into a FieldPage{heights, temp, moisture}. CRUCIAL: `heights` is byte-identical to what the M1 single-channel path produced (climate is purely additive, never feeds back into height), so the M1.7 collision/height contract is untouched. Params block grew 8->16 floats (climate params + a pad), kept std430-aligned.
  - page_pool.rs: ResidentPage now also holds temp_tex + moist_tex (R32F, one per channel), built from the SAME production as the height texture (one source of truth, can't drift). Height texture/heights array UNCHANGED. New getters get_page_temp_tex / get_page_moist_tex; new configure_climate() tunable; configure() preserves climate params so the M1 call site didn't change.
  - field_compute.rs (test oracle): produce_page unchanged for callers (climate defaults match the pool so height is identical); added produce_climate_page returning [temp,moisture] interleaved for the gate.
  - ring_displace.gdshader: added temp_tex/moist_tex uniforms + a `view_mode` int. mode 0 = normal height shading (unchanged), 1 = temperature (cold blue->hot red ramp), 2 = moisture (dry tan->wet blue). The renderer only READS the field's climate output and tints (never decides climate, 00 §2.2).
  - world_view.gd: _view_mode state, V cycles normal->temp->moisture and pushes it to all live + recycled materials; _make_page_instance binds the page's climate textures. view_mode()/view_mode_name() introspection.
  - NEW GATE tests/m2_1_climate_check.gd: determinism (same page+seed -> bit-identical climate), seed sensitivity, range [0,1] (no NaN/Inf), LOW FREQUENCY (max adjacent-cell step tiny -> smooth, the anti-confetti rule), latitude gradient (temp shifts meaningfully over 30 km world-Z).
VERIFY (output-provable): m2_1_climate_check PASS — determinism, range temp[0.31,0.53]/moist flat-within-a-page (varies globally: probed temp 0.08-0.79, moist 0.31-0.66 across distant pages), max adjacent step temp 0.0058 / moist 0.0000 << 0.05 (smooth), latitude delta 0.359/30km. ALL 14 GATES GREEN (13 M1 + M2.1). Critically m1_2/m1_4/m1_7a re-ran identical (continuity max step still 2.934, get_page_heights still bit-identical to the R32F texture) -> the height path is provably unchanged; climate is additive.
PARKED FOR VISUAL: M2.1's visual gate is "two smooth, large-scale gradients across the world" (rendered pixels -> human's eyes). Believe it is satisfied. Evidence captured (high wide vantage, ~60 km span): wg-13/_captures/climate_{normal,temperature,moisture}.png. Temperature clearly shows the warm-foreground -> cold-back latitude band with altitude texture on top (reads as Earth-like). Moisture shows a gentle large-scale band (subtle at this span; moisture's real test is M2.2 biome distribution). Normal mode = unchanged M1 terrain (toggle proven to switch). To confirm live: run.ps1, press V to cycle modes, fly tens of km north/south to watch the bands.
NOTE / non-blocking observation (NOT a fix-now): at small zoom, temperature visually reads as altitude-driven (per-hill) because lapse=0.4 competes with the slow latitude change across a small frame; at a wide vantage the latitude band dominates as intended. Moisture is gently varying. Both are correct/deterministic; whether to push moisture contrast or lapse is a TUNING call best made at M2.2 against real biome output, not against a debug tint (avoid optimizing a placeholder viz — same discipline as the deferred async-GPU call). Did NOT retune the model on a too-zoomed static capture.
CODEBASE STATE: green at the M2.1 commit.
WHAT I DID NOT DO: Did NOT start M2.2 (parked for the human's visual confirm, per 02_WORKFLOW §2 — unsupervised work may only cross TEST gates; a visual gate parks). Did NOT change the field/renderer contract (climate is a new field OUTPUT, explicitly allowed 00 §2.3). Did NOT touch the height/collision path (proven bit-identical). Did NOT retune climate against the static capture.

## [2026-06-06] — M2 planned (decisions locked); implementation deferred to a fresh session
TYPE: (planning + design decisions; no code)
User asked to plan M2 well, update docs, refresh handoff, then START M2 IMPLEMENTATION IN A NEW SESSION (context was getting long; clean start preserves the rhythm). Also clarified honestly: they don't fully follow the field internals and want "the best realistic system" — so I made the pillar-driven calls and wrote a PLAIN-LANGUAGE design note (M2_DESIGN.md) so the next session builds without re-deciding and the user understands what they're getting.
DECISIONS LOCKED for M2 (rationale in M2_DESIGN.md):
  1. Climate = Earth-like: temperature ~ latitude gradient (world-Z) minus altitude plus low-freq noise; moisture ~ low-freq noise. (Best-realistic over simplest; altitude coupling sets up M2.3.)
  2. Climate produced in the SAME field dispatch as height (the page carries height+temp+moisture). One source of truth, no extra GPU pass, M2.2/2.3 read these same values (build-it-right-once, 00 §2.1).
  3. Viz = recolor terrain via a view-mode toggle (key V cycles normal/temp/moisture, later biome) — user's explicit pick; same render path biome-color will use.
  4. Biomes = DATA rows (00 §6); DEMs inform via OFFLINE stats only, never runtime file loads (milestone §3/§4). (M2.2+ / M2.5+ guardrails noted so they aren't violated early.)
ALSO answered the user's frame-floor question (recorded in chat + the budget framing already in 01_TOOLCHAIN §6.1): the ~4ms steady floor is mostly Godot's own per-frame cost (clear/sky/light/present), NOT our code — our part is ~1.13ms (the HUD's `view` row). Can't and shouldn't push the engine floor lower; it's fixed overhead, and the 12+ms of remaining budget is for real content. Not waste, leave it.
M2.1 is the START: temp/moisture fields in field_height.glsl (world-space, deterministic), page grows to ~3 channels, ring_displace gets a view_mode tint, world_view cycles it, new m2_1_climate_check gate (determinism + smooth/low-freq + range). See M2_DESIGN "what M2.1 concretely touches".
CODEBASE STATE: green (planning only).
WHAT I DID NOT DO: Did not implement M2.1 (deferred to fresh session per the user). Did not change code.

## [2026-06-06] — M1.9 live confirm + "is the budget real?" framing recorded
TYPE: (human visual confirm + doc honesty pass)
Human flew the M1.9 build ~49 km from origin (HUD: page -6,-97, xz -2773/-48898) and read the HUD: 240 fps / 4.17 ms, p99 4.55 == max 4.55 (worst frame == median, DEAD FLAT, no spikes), prod 0.00 / mesh 0.00 / view 1.13 ms steady, mem 132 MB flat (made 1831 / evict 1485 -> eviction working), vram 155 MB. HUD backing panel reads cleanly. Visual + perf confirmed good.
HONEST FRAMING (user asked "is the frame budget even real / will it just be 4ms no matter what?" — good instinct): the 16.6ms budget is real and fixed, but today's ~4ms is measured on an ALMOST-EMPTY world and is a FLOOR, not representative — it climbs with M2 biomes (field math), M3 textures (fragment work), M4 scatter, M5/M6 water/erosion. What M1.9 permanently bought is that the STREAMING SHELL itself is now ~free (structural alloc/churn/burst removed), so the whole budget is available for content. Don't read "4ms today" as "perf solved forever." Recorded this in 01_TOOLCHAIN §6.1. Async GPU production stays deferred precisely because tuning it now optimizes a placeholder field.
NEXT: M2.1 (temperature & moisture debug-color fields).
CODEBASE STATE: green.

## [2026-06-06] — M1.9.3c string-churn removal + M1.9 CLOSED
TYPE: (workload-independent waste removed; M1.9 perf milestone done; 13/13 gates green)
M1.9.3c: the per-frame drop/pin/annulus loops re-split the "L:gx:gz" string key and re-iterated _instances ONCE PER LEVEL (6x). Fix: parse the key ONCE at instance creation into a parallel _inst_meta[key]=Vector3i(level,gx,gz); drop+pin is now a SINGLE pass reading meta (no per-level re-iteration, no string parsing); annulus visibility reads meta too. Churn (view minus prod minus mesh) dropped ~3.6ms -> ~1.8ms on the worst frame. The annulus overlap/coverage gates pass, so the visibility refactor preserved behavior exactly.
M1.9 PERF MILESTONE SUMMARY (all evidence-driven, measure-before-cut):
  worst fast-motion frame (2400 u/s boost): 35.40ms -> 17.15 (3a mesh pool) -> 10.97 (3b eager spread) -> ~11ms (3c). 0/300 frames over the 16.6 budget. ~3.2x.
  - 3a: shared per-level PlaneMesh + MeshInstance3D free-list (no per-page alloc).
  - 3b: bound mid-coarse eager production; coarsest stays unbounded (never-black floor). PROVEN never-black by m1_9b_eager_spread_check.
  - 3c: parse page key once; single-pass per-frame loops.
  All workload-INDEPENDENT (always correct, never re-done). 13 gates green. No feature/quality sacrificed; field/contract untouched.
REMAINING COST = GPU page production (~5-7ms on the worst burst frame) — but that's REAL WORK (producing pages), bounded + spread, not waste. Optimizing it (async/double-buffered GPU production to avoid the blocking rd.sync) is WORKLOAD-DEPENDENT (the field gets much heavier with biomes/erosion in M2/M6), so per the agreed scope it's DEFERRED — optimize it when real content reveals the true cost, not against the placeholder fBM. Logged in HANDOFF.
CODEBASE STATE: green at the M1.9.3c commit. M1.9 done.
WHAT I DID NOT DO: Did not optimize the GPU production path (deferred, workload-dependent). Did not change the field/contract.

## [2026-06-06] — M1.9.3b eager-burst spread — worst frame 17 -> 11 ms, 0/300 over budget (never-black PROVEN)
TYPE: (perf fix touching never-black, proven safe; 13/13 gates green)
THE CAREFUL ONE (a prior naive eager-cap broke never-black — see M1.6 entry — so this needed a real argument, not a cap). Three production modes in the pool now:
  - COARSEST level: unbounded eager (request_page_eager) — the never-black FLOOR, always complete.
  - MID-coarse (0<level<coarsest): BOUNDED eager (request_page_eager_bounded, max_eager_per_frame, default 8) — spread over frames.
  - FINE (0): bounded as before.
WHY SPREADING MID-COARSE IS NEVER-BLACK-SAFE (the argument): _update_annulus_visibility hides a coarse page only when its ENTIRE finer footprint is displayed; if a mid-coarse page is missing, the coarser page beneath stays visible and covers that ground. So a missing mid-coarse page falls back to a COARSER blanket (blurrier for a frame), never to black — down to the unbounded coarsest floor. The old failure capped the floor too; this keeps it.
PROVEN, not assumed: new gate m1_9b_eager_spread_check (4 levels, mid-coarse starved to 3/frame) asserts every fine cell is still covered by SOME resident level AND the coarsest ring is complete (49/49). PASS.
RE-CAPTURED (same 2400 u/s flight): worst frame 35.40 (before) -> 17.15 (after 3a) -> 10.97ms (after 3b). FRAMES OVER 16.6 BUDGET: 0/300. prod dropped ~9.3 -> ~4.5ms (8 eager/frame, not 28-at-once).
max_eager_per_frame is an @export (view) + set_max_eager_per_frame (pool) — the lever to lower the worst frame further on weaker GPUs (relevant to the RTX 3070 min target: 11ms*~3x is near/over 60fps budget at sustained MAX boost — an extreme case; tune this down there if needed).
VERIFY: all 13 gates (incl. coverage + the new spread gate + overlap + frame-time + smokes) PASS.
CODEBASE STATE: green at the M1.9.3b commit.
WHAT I DID NOT DO: Did not cap the coarsest floor (that's what broke never-black before). Did not claim safe without the new proving gate. Did not change the field/contract.

## [2026-06-06] — M1.9.3a mesh/material pooling — worst frame 35 -> 17 ms (verified)
TYPE: (perf fix, evidence-verified; 12/12 gates green)
FIX (targets the M1.9.2 finding exactly): stop allocating per page. (1) ONE shared PlaneMesh per level (identical geometry for every page at a level) -> referenced, not re-newed. (2) A free-list of MeshInstance3D+material: evicted instances are hidden and recycled (re-point height_tex, reposition) instead of queue_free + new. Steady state and the eager burst now allocate nothing.
RE-CAPTURED (same flight, 2400 u/s, before -> after):
  worst frame 35.40ms -> 17.15ms (-52%)
  worst mesh  19.08ms ->  0.79ms (-96%)  <- the alloc spike is gone
  view total over 300 frames 1014ms -> 835ms
VERIFY: all 12 (10 gates + 2 smoke) PASS — pooling didn't break annulus visibility/coverage (recycled instances leave _instances, so the annulus pass ignores them; reused ones are re-shown then coverage-resolved as normal).
WHAT THE EVIDENCE NOW SHOWS (-> M1.9.3b): worst frame 17.15ms is JUST over the 16.6 budget, and mesh is no longer the cause. The remaining cost on the worst (28-eager) frame is prod 9.3ms (GPU producing 28 coarse pages in ONE frame — my original hypothesis, real but secondary) + ~13ms non-mesh view (ring/dict iteration across 6 levels). Root trigger is the EAGER BURST (28 coarse pages/frame). 3b: spread that burst over a few frames WITHOUT breaking never-black (note: a prior naive eager-cap broke never-black + worsened startup — see 2026-06-06 M1.6 entry; must spread, not starve).
CODEBASE STATE: green at the M1.9.3a commit.
WHAT I DID NOT DO: Did not claim "fixed" without re-measuring. Did not touch the field/contract. Did not yet address the eager burst (3b).

## [2026-06-06] — M1.9.2 spike CAPTURED — root cause was NOT what I assumed
TYPE: (root-cause via evidence; hypothesis overturned)
Captured the fast-motion spike with the M1.9.1 profiler (scratch diag flying east at 2400 u/s, AutoTour disabled). WORST 12 FRAMES:
  dt=35.4ms -> prod 8.75 | view 31.4 | mesh 19.1 | 4 fine, 28 EAGER
  dt=31.7ms -> prod 8.34 | view 27.8 | mesh 16.0 | 4 fine, 21 eager
  ... calm frames: 0 eager -> mesh ~2.5ms, dt ~10ms.
  Totals over 300 frames: prod=106ms, view=1014ms (view includes mesh).
FINDING (overturned my guess): I assumed the spike was GPU production/readback (prod / rd.sync). IT IS NOT. prod is cheap and well-behaved (~8ms worst). The spike is VIEW-side GDScript, ~10x the GPU cost, dominated by MESH: building a fresh PlaneMesh + ShaderMaterial + MeshInstance3D PER PAGE. The trigger is the EAGER coarse-page burst — flying fast crosses coarse boundaries and the view builds many coarse pages in ONE frame (up to 28), each allocating mesh+material on the main thread. Worst frames correlate exactly with eager count. (This is why "measure before cutting" is a rule: optimizing prod/sync would have fixed nothing.)
SECONDARY: view-minus-mesh ~12ms on the worst frame = non-mesh per-frame work (ring iteration / dict churn across all levels) — a second GDScript target.
PLAN CHANGE: M1.9.3's "mesh/material reuse" is actually the PRIMARY spike fix, so it moves up (M1.9.3a): pool/reuse PlaneMesh + ShaderMaterial instead of per-page alloc. Then re-capture; address the ring/dict churn (3b) only if still significant.
CODEBASE STATE: green (diagnostic was scratch, removed; no code change yet).
WHAT I DID NOT DO: Did not optimize the GPU path (the evidence says it's not the problem). Did not cut on a guess.

## [2026-06-06] — M1.9.1 profiler instrumentation (measure before cutting)
TYPE: (instrumentation; smoke + 10 gates green)
First M1.9 step is MEASUREMENT, not optimization (Survivability: don't cut on a guess). Added per-system frame timing so the fast-motion spike becomes attributable:
  - Rust PagePool: produce_us_this_frame (wall-time in produce() = GPU dispatch + blocking rd.sync readback — the PRIME SUSPECT for the spike), reset each begin_frame; getters produce_us_this_frame() + eager_this_frame(). Timed with std::time::Instant (negligible).
  - world_view.gd: prof_process_us (whole _process) + prof_mesh_us (just _make_page_instance: PlaneMesh+ShaderMaterial+MeshInstance3D alloc/add_child — an M1.9.3 reuse target). Timed with Time.get_ticks_usec().
  - perf_hud.gd: new profiler section (key 5) — "prod X ms (N fine/M eager)" + "view X ms  mesh X ms". So when you boost across boundaries you SEE whether the spike is GPU production (prod) or GDScript mesh-build (mesh) or general view work (view).
EARLY READ (settled frame, camera still): prod 0ms / mesh 0ms (no pages produced) and view ~2.1ms (steady per-frame ring logic). The spike will show under motion; that's M1.9.2's capture.
VERIFY: hud_smoke_check extended (profiler row + getters wired) PASS; all 10 gates (9 structural + frame-time) PASS — instrumentation didn't regress or measurably cost. One untyped-inference parse error fixed (typed prod_ms).
CODEBASE STATE: green at the M1.9.1 commit.
WHAT I DID NOT DO: Did not optimize anything yet (next: capture the spike live, then fix with evidence). Did not change the field/renderer contract.

## [2026-06-06] — M1.8 MILESTONE GATE PASS — m1-complete tagged
TYPE: (milestone gate met, tagged)
M1 Definition of Done verified in two halves: (1) OUTPUT-PROVABLE/MEASURED — all 9 structural gates green (determinism, seams, pool bounding, streaming invariants, never-black coverage, annulus no-overlap, collision heights/build/stand) PLUS the m1_6 frame-time gate (steady-state ~2.5ms, p99 2.78ms << 16.6 budget). (2) VISUAL — human flew the live world via the auto-tour (cruise/boost/pan/ascend/orbit/walk-drop) with the perf HUD up and signed off: continuous to horizon, no seams, no black even outrunning the streamer, no fall-through on the walk step, memory flat. Known-deferred far-edge items (LOD detail-step + streaming pop-in) are within M1's "no popping that reads as broken" allowance.
PERF NOTE (-> M1.9): user observed occasional p99/max/frame-time jumps when moving fast (240->210 fps dips, ~4ms baseline). These are WITHIN M1's under-budget gate (4ms vs 16.6), so they do NOT block the tag — but the user wants the foundational infra as efficient as possible. DECISION (pillars): tag M1 now (every gate green = a real checkpoint; denying it would discard proven state), then do performance as its OWN gated milestone M1.9 before M2 — evidence-first (instrument, then cut), optimizing workload-independent things only (defer content-dependent tuning so we don't optimize a placeholder field). See PROGRESS M1.9.
TAGGED: m1-complete.
CODEBASE STATE: green at the m1-complete tag.
WHAT I DID NOT DO: Did not start M2. Did not begin optimizing before instrumenting (M1.9.1 is measurement first).

## [2026-06-06] — Dev tooling: perf HUD + data-driven auto-tour (smoke PASS)
TYPE: (tooling — demo-side, not milestone work; smoke-verified, all 9 gates still green)
Built two DEMO dev tools (no engine/contract impact; world_view/Rust/GLSL untouched), brainstormed + user-approved:
  - perf_hud.gd (top-right CanvasLayer): true per-frame delta -> fps/ms + rolling p99/max (amber over 16.6ms budget; the M1.6 "Engine FPS hides spikes" lesson), streaming (resident pages / collision bodies / made / evicted from the pool's getters), camera world pos + page index, static mem + VRAM. COST DISCIPLINE: the label is rebuilt at update_hz (~5/s), NOT per frame — per-frame work is one delta sample into a ring buffer. H toggles all; 1-4 toggle sections. Reads the scene, never writes.
  - auto_tour.gd (Node): DATA-DRIVEN — `tour` is an Array of {action,...,secs} step dicts; change the tour by editing rows (engine "variability in data" rule). Actions: fly_forward/boost/slow_pan/reverse/ascend/descend/orbit/walk_drop — each a small reusable fn. DRIVES THE EXISTING RIGS (moves world_view's fly-cam; triggers the player's walk via a new auto_move hook), not a parallel mover. T toggles; any movement input or T PAUSES and hands over the normal fly/walk from the current spot; T resumes from the same step. Starts OFF so a normal launch is clean.
  - player_capsule gained `auto_move` (local-space drive dir): when set, the capsule moves by it instead of reading keys, so the tour can auto-walk without faking OS input. Zero -> manual keys as before.
SMOKE PASS (output-provable, hud_smoke_check + tour_smoke_check): HUD finds the view, all 4 sections show sane values, the streaming count matches pool.resident_count, section toggle removes a row. Tour starts OFF, drives the real fly-cam (moved ~70m in 0.5s @ 600/s), advances steps, pause restores fly control, resume reactivates. All 9 M1 gates + the m1_6 frame-time gate still PASS (no regression from the auto_move hook).
Wired both into demo.tscn (PerfHUD, AutoTour nodes beside View/Player). Removing them later = delete two nodes.
NEXT: M1.8 — run the milestone flythrough (the auto-tour is the vehicle) and tag m1-complete.

## [2026-06-06] — Far-distance visual items confirmed (both deferred)
TYPE: (observation logged, no code change)
Human flying the live world reported two far-distance visual items: (1) SLIGHT LOD detail-step at clipmap ring boundaries (already a known deferred geomorph item), and (2) the MAIN one — terrain POPPING IN at the loaded-world frontier instead of dissolving into the depth fog. #2 was NOT distinctly logged before (it's separate from the geomorph step and the startup hitch). Added #2 as its own item in HANDOFF "Known deferred items". User agreed both are fine to fix later. Neither blocks M1 (gate is no-black/no-cracks; both hold — these are far-edge LOD/fog softness). Not fixing piecemeal (would be slop).

## [2026-06-06] — M1.7c LIVE WALK PASS + controls polish
TYPE: PARKED-FOR-VISUAL -> PASS (human), then demo-control tweaks
HUMAN VISUAL PASS: after the input-bleed + spawn-at-terrain fix, the user re-flew the live world, dropped in (G), and confirmed: "i didnt fall through, i think you fixed it." M1.7c fall-through gate satisfied — the capsule stands on the streamed terrain and does not fall through, including the Shift case that first exposed it. The fix (walk/fly mutually exclusive + spawn just above resident terrain) is the real resolution.
CONTROLS (user-requested, demo-only QoL — GDScript, no rebuild): fly now uses SPACE = rise / C = descend (E/Q kept as aliases). Walk: SPACE = jump (from the ground), SHIFT = sprint (move_speed x3). Stand gate still PASS; sprint speed (~36 m/s) is far under the tunneling-safe range proven earlier (2400 u/s probe didn't tunnel).
REMAINING for M1.7: this was the last sub-step. M1.7 collision is DONE pending nothing — proceed to M1.8 (full M1 definition-of-done + tag m1-complete).

## [2026-06-06] — M1.7c (test character) — output-provable core PASS, live walk PARKED-FOR-VISUAL
TYPE: PARKED-FOR-VISUAL (output-provable core self-certified)
WHAT: Added player_capsule.gd (DEMO content, not engine) + wired into demo.tscn beside the view. CharacterBody3D capsule with F = fly (hand control back to world_view's free-fly camera, capsule sleeps -> flying unchanged) / G = walk (snap under the fly-cam, switch to the capsule's own camera, gravity + WASD). Finds the fly-camera via the viewport's current camera, so it never reaches into world_view internals (clean boundary). world_view.gd untouched (stays the reusable view).
OUTPUT-PROVABLE CORE PASS (most of the "doesn't fall through" gate, certified without eyes):
  - DIAGNOSTIC raycast (scratch, removed): collision_y == field-array height to <1cm at every sample cell incl. ASYMMETRIC ones (100,20)/(20,100) that would expose any transpose -> the HeightMapShape3D surface lines up EXACTLY with the field. M1.7b transform confirmed correct end-to-end.
  - m1_7c_stand_check.gd PASS: loads demo.tscn, drops the capsule in WALK from 480m over page (0,0); it falls, is_on_floor() goes true, settles at y=310.3 on terrain ~308.7 (floor + capsule half-height). Did NOT fall through; genuinely standing on the HeightMapShape3D.
DEBUGGING LESSON (systematic, no fix stacked): first stand-check FAILED "settled 37m too high" (y=345.8 vs 309.7). Root-caused with EVIDENCE before touching code: (a) the raycast diagnostic proved collision geometry is bit-exact to the field (so NOT a collision bug), (b) a trajectory log showed the capsule was still FALLING at t=3s (y=344, vy=-90) — the 180-frame/3s settle window just closed mid-air. Fix was the TEST's settle time (wait for is_on_floor, up to 10s), NOT the collision code. The collision was correct the whole time. (User intuition "maybe it just closed too soon" was right.)
LIVE WALK — first human test surfaced a real issue (see fix below), then re-launched.
USER REPORT (live, first build): "if I hit Shift I fall through — or maybe it just happened at the same time, hard to tell."
INVESTIGATED WITH EVIDENCE (scratch diagnostics, removed; no fix stacked on a guess):
  - Raycast probe: collision geometry is bit-exact to the field at all sample cells (already known from M1.7b). Shift does NOT speed up the capsule — Shift is the FLY-camera's boost; the capsule's move_speed is fixed. So Shift can't accelerate the walking capsule.
  - Three repro probes — fast horizontal motion (2400 u/s), drop onto a far unbuilt page, and the user's exact "fly fast then press G" — ALL settled on_floor=true, no tunnel, no fall-through (collision builds within ~0.18s of arrival; eager-coarse + off-thread build are fast enough).
ROOT CAUSE (by inspection, the live-vs-script difference): in walk mode the fly-camera's _process was STILL running, so both controllers read WASD/Shift at once — Shift boosted the invisible fly-cam while you walked. That input-bleed makes "did Shift do it?" impossible to tell, and dropping the capsule from the fly-cam's high altitude meant a long fall that could cross onto a momentarily-uncollided page.
FIX (two parts, both verified green): (1) walk/fly are now mutually exclusive — _enter_walk disables the fly-cam's process/input, _enter_fly re-enables (one controller at a time). (2) _enter_walk now spawns the capsule just ABOVE the resident terrain height (sampled via new world_view.page_terrain_height(), reading the same level-0 pool heights collision uses) instead of from the fly-cam altitude — small drop, no tunneling speed, and the page's heights are resident so its collision is present/lands within a frame. Can't fall through a fresh page. m1_7c_stand_check still PASS (now drops from terrain+3m); all three repro probes still clean.
LIVE WALK PARKED (human, re-launched with fixes): run.ps1 (visible window). Fly with WASD + right-drag + Shift boost; press G to drop in and walk (capsule takes the keys, fly-cam is parked); fly far/fast to outrun the streamer, look at a fresh page, press G and confirm you stand on it; F to go back to flying. Believe it is satisfied; awaiting human visual confirmation; did NOT start M1.8.
CODEBASE STATE: green at the M1.7c commit.
WHAT I DID NOT DO: Did not self-certify the live-walk feel. Did not put character logic in world_view (kept it demo-only). Did not change the contract. Did not start M1.8.

## [2026-06-06] — M1.7b (near-page collision build) PASS
TYPE: (test gate passed, self-certified)
WHAT: world_view now builds collision for NEAR fine (level-0) pages only, radius 1 (3x3 around camera). Per frame: read the page's heights on the MAIN thread (cheap CoW handle from get_page_heights), pass the array INTO a WorkerThreadPool task that packs a HeightMapShape3D + StaticBody3D off-tree (touches no pool, no active tree), then call_deferred add_child on the main thread. Bodies free when pages leave radius+evict_margin (hysteresis). collision_radius (1) <= keep (4), so collision pages are already pinned by the mesh pass -> heights can't be evicted under a live body.
TRANSFORM (verified Godot facts applied): HeightMapShape3D grid is 1 unit/vertex and centered on the body origin, so body.position = page CENTRE (same formula as the mesh) and body.scale = (spacing,1,spacing). map_data is row-major width*depth (X=width,Z=depth) = our field's z*res+x, dropped in untransposed.
GATE m1_7b_collision_check.gd PASS: drives the REAL view through 40 frames (exercises the async WorkerThreadPool + deferred attach). Body exists for the page under the camera; shape.map_data BIT-IDENTICAL to pool.get_page_heights (pool->collision end-to-end, no drift); dims 128x128; position = page centre (254,254); scale = (4,1,4) = cell_spacing; all bodies are HeightMapShape3D; 9 collision bodies for 294 displayed meshes (near-pages-only proven, not one-per-mesh). The transform values that decide float-vs-sink are output-proven, de-risking the M1.7c visual gate.
GDScript-only (no Rust rebuild). One parse-error fixed (typed an untyped-property inference) before PASS.
CODEBASE STATE: green at the M1.7b commit.
WHAT I DID NOT DO: Did not add the character yet (M1.7c). Did not build collision off a second field path (reads the cached pool heights). Did not block a render frame on the build (off-thread).

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
