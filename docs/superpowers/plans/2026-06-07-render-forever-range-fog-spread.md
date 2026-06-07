# Render Forever — Range + Fog + Spread Streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend terrain view distance ~4x (≈49km → ≈195km), retune fog/far so the streaming frontier dissolves in fog instead of popping in, spread far-page production so it never hitches, and hold the frame budget — building on the M2.6 GPU-resident foundation.

**Architecture:** Pure data/config changes plus (only if measured-necessary) one production-mode tweak. The clipmap was built to scale by adding levels ("just more levels + tuned radii" — M1.6). Pillars 1, 2, 4 are GDScript-only (zero Rust rebuild — important: Codex is actively editing the Rust files, and the editor/DLL lock complicates rebuilds). Pillar 3 (bound the coarsest level) is EVIDENCE-GATED: only done if the burst measurement at 8 levels shows the unbounded coarsest actually hitches.

**Tech Stack:** Godot 4.6.2-mono (GDScript), the live view `wg-13/scripts/world_view.gd`, existing GPU gates run via the Godot console exe with `--rendering-driver vulkan`.

**Spec:** `docs/superpowers/specs/2026-06-07-render-forever-range-fog-spread-design.md`

---

## Conventions used in every task

**Gate-run command** (from 04_CODE_MAP.md "Running gates" — GPU gates CANNOT use `--headless`):

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/<name>.gd
# PASS/FAIL printed; exit code 0 = pass.
```

**The 10-gate suite** (run all before declaring a stage green): `m1_4_seam_check`, `m1_5c_coverage_check`, `m1_7a_heights_check`, `m1_7b_collision_check`, `m1_7c_stand_check`, `m2_1_climate_check`, `m2_2_biome_check`, `m2_3_composition_check`, `m2_6_vram_check`, `m2_6_burst_perf_check`. Plus `m1_9b_eager_spread_check` (never-black) for Pillar 3.

**Commit discipline:** ASCII commit messages via a temp file (`git commit -F d:/tmp/msg.txt`), never a here-string with leading `/` or special chars (project has had broken commits that way). Commit ONLY at a green gate. End every commit message with the Co-Authored-By line.

**Visual gates PARK — do not self-certify.** When a task says PARK-FOR-VISUAL: bring it to green/compiling, launch `run.ps1`, write the PARKED entry in DRIFT_LOG, and STOP. The human's eyes resolve it. The agent proceeds across TEST gates only.

**No Rust files touched by Pillars 1/2/4.** Do NOT `git add` any `rust/**` file in those commits (Codex has uncommitted DEM-kernel edits there — kept, inert, not ours to commit). Always `git add` exact paths.

---

## File Structure

- `wg-13/scripts/world_view.gd` — the ONLY live view. Holds `num_levels` (Pillar 1), the fog/far/cam setup in `_spawn_camera()` (Pillar 2), the per-level production loop (Pillar 3). All changes land here.
- `wg-13/tests/m2_6_burst_perf_check.gd` — existing burst gate (Pillar 4 measurement). Not modified; re-run.
- `wg-13/tests/m1_9b_eager_spread_check.gd` — existing never-black gate (Pillar 3 guardrail). Not modified; re-run.
- Docs: `PROGRESS.md`, `DRIFT_LOG.md`, `04_CODE_MAP.md` updated as part of each stage (working method §8.4).

No new files. No new Rust. (Pillar 3, only if triggered, adds a tiny Rust method — its own sub-task with its own gate, flagged clearly.)

---

## Task 1: Pillar 1 — extend reach to ~195km (num_levels 6 → 8)

**Files:**
- Modify: `wg-13/scripts/world_view.gd` (the `@export var num_levels` line, ~line 30)

- [ ] **Step 1: Record the pre-change baseline burst number**

Run the burst gate on the CURRENT (6-level) build to have an A/B baseline:

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_6_burst_perf_check.gd
```

Expected: PASS, "0/720 over budget" (or similar median-of-maxes ~13ms). Note the exact numbers — this is the bar Pillar 4 must still clear at 8 levels.

- [ ] **Step 2: Change num_levels 6 → 8**

In `wg-13/scripts/world_view.gd`, the line currently reads:

```gdscript
@export var num_levels: int = 6            # fine (0) + coarse blankets, out to the horizon
```

Change to:

```gdscript
@export var num_levels: int = 8            # fine (0) + coarse blankets — 8 levels @ base span ~508m, radius 3 -> reach ~195km (render-forever); 2 new levels are coarse/bounded (auto via the mid-coarse path)
```

(GDScript-only — no rebuild. The startup print at ~line 96 will now report the new reach; it computes from num_levels so it updates automatically.)

- [ ] **Step 3: Run the full 10-gate suite to catch regressions early**

Run each gate (loop or individually):

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
$tests = @("m1_4_seam_check","m1_5c_coverage_check","m1_7a_heights_check","m1_7b_collision_check","m1_7c_stand_check","m2_1_climate_check","m2_2_biome_check","m2_3_composition_check","m2_6_vram_check","m2_6_burst_perf_check")
foreach ($t in $tests) { Write-Host "=== $t ==="; & $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/$t.gd"; Write-Host "exit=$LASTEXITCODE" }
```

Expected: all PASS (exit=0). KEY ONES: `m2_6_vram_check` (2 more coarse levels add pages — confirm VRAM still bounded) and `m2_6_burst_perf_check` (this is also Pillar 4's measurement — see Task 4; if it FAILS here, Pillar 3 / cap-tuning is triggered, do NOT proceed to visual yet).

- [ ] **Step 4: Verify the reach print**

Launch headless-script just to read the startup print, OR read it from the gate stdout. Expected line:

```
M1.6: 8-level clipmap, ring_radius 3, base span 508m -> reach ~195.1 km
```

Confirms num_levels took effect and reach ≈ 195km (`3 * 508 * 2^7 / 1000`).

- [ ] **Step 5: PARK-FOR-VISUAL — launch and look**

```powershell
cd "D:\world gen 13"; .\run.ps1
```

Write a DRIFT_LOG PARKED entry: "Pillar 1 reach 6->8 levels (~195km). All 10 gates green [quote the burst number]. Believe terrain now reads to a far horizon in all directions. Awaiting human visual confirm — does it read forever? Any vertex shimmer/precision wobble at the far distance (the one watched unknown)? Did NOT proceed to Pillar 2." Then STOP.

- [ ] **Step 6: Commit (after gates green; visual parked is fine to commit — code is green)**

Update `PROGRESS.md` (add a render-forever P1 line) and `DRIFT_LOG.md` (the PARKED entry). Then:

```powershell
git add "wg-13/scripts/world_view.gd" "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md"
# write d:/tmp/msg.txt: "[render-forever P1] num_levels 6->8, reach ~49->~195km; 10 gates green; parked for visual"
git commit -F d:/tmp/msg.txt
```

Do NOT add any `rust/**` file.

---

## Task 2: Pillar 2 — retune fog/far so the frontier dissolves (no pop-in)

**Files:**
- Modify: `wg-13/scripts/world_view.gd` — `_spawn_camera()`, the `cam.far` line (~421) and the fog block (~448-449).

**Prerequisite:** Task 1's visual gate must be human-PASSED (terrain reads far). This task tunes how the far edge looks; it builds on the confirmed reach.

- [ ] **Step 1: Add a frontier/fog/far diagnostic print (output-provable part of the gate)**

In `_spawn_camera()`, AFTER `reach` is computed (~line 418) and BEFORE creating the camera, add a print and compute the new ratios. Replace the existing `cam.far` and fog lines as follows.

Current (~line 421):
```gdscript
	cam.far = reach * 1.3                       # see the whole loaded extent + margin
```
Current fog (~448-449):
```gdscript
	e.fog_depth_begin = reach * 0.45
	e.fog_depth_end = reach * 0.98
```

Change to the new ratios (fog_end pulled IN to bury the frontier; cam.far follows fog_end; begin pushed out for the bigger near field). NOTE: `span = _pool.page_span()` is the BASE span (~508m), so derive the coarsest span explicitly. Add this block AFTER `reach` is computed (~line 418) and BEFORE `cam` is created:
```gdscript
	# render-forever Pillar 2: the streaming frontier must be INSIDE full fog so new
	# pages dissolve in rather than pop. fog_end pulled in to ~0.85*reach; cam.far
	# follows it (no geometry drawn past opaque fog = also reclaims depth precision);
	# begin pushed to ~0.55*reach so the much larger near/mid field stays crisp.
	var fog_begin: float = reach * 0.55
	var fog_end: float = reach * 0.85
	var coarsest_span: float = span * pow(2.0, num_levels - 1)
	# Two appearance bounds for a NEW coarsest page: a hard TELEPORT can in-fill out to
	# the ring edge (~reach, pessimistic); continuous FLIGHT only reveals ~one coarsest
	# page of new ground past the existing blanket per recenter step. The flight bound
	# is the real use; the teleport edge is covered by the persistent displayed blanket
	# (evict_margin hysteresis) + the visual gate. fog_end must bury the FLIGHT bound.
	var teleport_frontier: float = float(ring_radius) * coarsest_span
	var flight_frontier: float = coarsest_span
	print("render-forever P2: reach=%.0f coarsest_span=%.0f teleport_frontier=%.0f flight_frontier=%.0f fog_begin=%.0f fog_end=%.0f far=%.0f | flight<=fog_end: %s" % [
		reach, coarsest_span, teleport_frontier, flight_frontier, fog_begin, fog_end, fog_end, flight_frontier <= fog_end])
```

Then set the camera far:
```gdscript
	cam.far = fog_end                           # render-forever P2: no draw past opaque fog
```
and the fog block:
```gdscript
	e.fog_depth_begin = fog_begin
	e.fog_depth_end = fog_end
```

- [ ] **Step 2: Run the burst + coverage gates (cheap regression check; fog is render-only)**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_6_burst_perf_check.gd
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m1_5c_coverage_check.gd
```

Expected: both PASS. Fog/far are render-only; they shouldn't affect production/coverage gates. (These gates spawn the camera, so the P2 print appears in stdout — capture it.)

- [ ] **Step 3: Assert the frontier-inside-fog invariant from the printed numbers**

Read the `render-forever P2:` line from Step 2 stdout. CONFIRM `flight<=fog_end: true`.

Expected math at 8 levels: reach≈195120, coarsest_span≈65040, fog_end=0.85*reach≈165852. So `flight_frontier` (65040) ≤ `fog_end` (165852) → **true** (continuous flight in-fill is buried in fog). Meanwhile `teleport_frontier` (3*65040≈195120) > fog_end — EXPECTED and acceptable: a hard teleport's static ring edge is the pessimistic bound, covered by the persistent displayed blanket (evict_margin hysteresis) + the human visual gate, NOT by fog_end. This matches the spec ("0.85 is a starting point; the gate's measurement is the source of truth; the number that matters is where in-fill becomes VISIBLE under motion, not the static ring edge").

If `flight<=fog_end` is FALSE (shouldn't happen at these ratios, but if num_levels/ring_radius change): lower fog_end (and cam.far with it) until true, OR add a small `e.fog_density` so the 0.85→1.0 band reads opaque without moving begin — try begin/end first, measure, only then touch density. Do NOT proceed to the visual gate until `flight<=fog_end: true`.

- [ ] **Step 4: PARK-FOR-VISUAL — fly the frontier**

```powershell
cd "D:\world gen 13"; .\run.ps1
```

DRIFT_LOG PARKED entry: "Pillar 2 fog/far retune (begin 0.55*reach, end=far 0.85*reach). flight_frontier <= fog_end asserted true [quote print]. Burst+coverage green. Believe new terrain now DISSOLVES in from fog under continuous flight (no pop-in). Awaiting human: fly outward — does the far edge dissolve, or still pop? Did NOT proceed." STOP.

- [ ] **Step 5: Commit (gates green; visual parked)**

```powershell
git add "wg-13/scripts/world_view.gd" "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md"
# d:/tmp/msg.txt: "[render-forever P2] fog/far retune buries the streaming frontier (begin 0.55, end=far 0.85*reach); flight-frontier inside fog asserted; parked for visual"
git commit -F d:/tmp/msg.txt
```

No `rust/**`.

---

## Task 3: Pillar 4 — hold the budget (measure burst at 8 levels)

> Pillar 4 is sequenced BEFORE Pillar 3 deliberately: it MEASURES whether the unbounded coarsest level actually hitches at 8 levels. If the burst gate is already green, Pillar 3 (the riskier coarsest-cap change) may be UNNECESSARY (YAGNI — don't add it). If it's red, Pillar 3 is triggered.

**Files:** none modified (measurement only — the gate already exists).

- [ ] **Step 1: Run the burst gate (repeat for stability — it's median-of-maxes but A/B noisy)**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
1..3 | ForEach-Object { Write-Host "=== run $_ ==="; & $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_6_burst_perf_check.gd }
```

Expected (target): PASS, "0/720 over budget", median-of-maxes near the Task 1 Step 1 baseline (~13ms). Compare to the 6-level baseline.

- [ ] **Step 2: Decide — branch on the measurement (pillar call)**

- **If PASS (0/720, median-of-maxes <= ~baseline+small):** the GPU-resident + tapered-coarse foundation absorbed the 2 new levels. Pillar 4 is GREEN. **SKIP Task 4** (Pillar 3 not needed — record in DRIFT_LOG that the unbounded coarsest at 8 levels did not hitch, so the spread change is YAGNI). Proceed to Task 5 (final close).
- **If FAIL (frames over budget) or a visible recenter hitch:** Pillar 3 is triggered. Proceed to Task 4. First record the failing numbers in DRIFT_LOG.

- [ ] **Step 3: Record the measurement in DRIFT_LOG either way**

Entry: "Pillar 4 burst at 8 levels: [numbers]. [PASS -> Pillar 3 skipped as YAGNI | FAIL -> Pillar 3 triggered]."

---

## Task 4: Pillar 3 — bound the coarsest level (ONLY IF Task 3 triggered it)

> Skip this entire task if Task 3 Step 2 chose PASS. This is the evidence-gated, riskier change (touches the never-black floor). It needs a small Rust method (a separate coarsest cap with its OWN counter, so a fine-heavy frame can't starve the floor). Coordinate: Codex has uncommitted DEM edits in page_pool.rs — these additions are separate functions/fields; `git diff` first, add only our lines, and the commit will include Codex's inert edits in page_pool.rs ONLY IF unavoidable — prefer to keep our change minimal and in a region that doesn't conflict. If a clean separation isn't possible, STOP and log it (don't commit over Codex's work blindly).

**Files:**
- Modify: `rust/gdext/src/page_pool.rs` — new `RequestMode::EagerCoarsest` + `max_coarsest_per_frame` field + counter + `request_page_coarsest` `#[func]` + reset in `begin_frame`.
- Modify: `wg-13/scripts/world_view.gd` — coarsest level uses the new request; add `@export var max_coarsest_per_frame` and push it to the pool.

- [ ] **Step 1: Rebuild prerequisite — close the editor (DLL lock)**

Ensure the Godot EDITOR is closed and `run.ps1 -Stop` has stopped any running window (the open editor locks `wg13.dll` → cargo build fails).

- [ ] **Step 2: Add the coarsest-bounded mode in page_pool.rs**

`git diff HEAD -- rust/gdext/src/page_pool.rs` first to see Codex's current edits. Then add (near the `RequestMode` enum, the `max_eager_per_frame` field, and the request match):

Add to the `RequestMode` enum:
```rust
    EagerCoarsest,   // coarsest level — bounded by its OWN max_coarsest_per_frame (never-black floor, spread)
```
Add a field by `max_eager_per_frame`:
```rust
    max_coarsest_per_frame: i32,
```
Default it (by the `max_eager_per_frame: 8` default, ~line 203):
```rust
            max_coarsest_per_frame: 16,   // coarsest pages/frame; generous (cheap, huge area) but spread to kill teleport hitch
```
Add a counter by `eager_bounded_this_frame` (find it near the other `*_this_frame` fields) and reset it in `begin_frame` where the others reset (mirror `eager_bounded_this_frame = 0`).
Add the budget gate in `request()` match:
```rust
            RequestMode::EagerCoarsest => {
                if self.max_coarsest_per_frame > 0
                    && self.coarsest_this_frame >= self.max_coarsest_per_frame {
                    return None;
                }
            }
```
Increment in the produce match:
```rust
            RequestMode::EagerCoarsest => {
                self.coarsest_this_frame += 1;
                self.eager_this_frame += 1;
            }
```
Add the `#[func]` + a setter:
```rust
    /// Coarsest-level page, bounded by max_coarsest_per_frame (own counter, so a
    /// fine-heavy frame can't starve the never-black floor). Spreads the coarsest
    /// in-fill burst (e.g. a teleport) across frames; the displayed blanket persists
    /// via evict_margin and fog buries the in-fill edge (render-forever P2/P3).
    #[func]
    fn request_page_coarsest(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        self.request(level, gx, gz, RequestMode::EagerCoarsest)
    }

    #[func]
    fn set_max_coarsest_per_frame(&mut self, n: i64) {
        self.max_coarsest_per_frame = n as i32;
    }
```

- [ ] **Step 3: Build the DLL**

```powershell
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo build --manifest-path "D:\world gen 13\rust\gdext\Cargo.toml"
```

Expected: compiles clean (Codex's inert DEM edits compile too). If it fails on Codex's code, STOP and log — do not "fix" Codex's work.

- [ ] **Step 4: Wire world_view.gd to the new coarsest request**

In `world_view.gd` production loop (~line 132-133), change the coarsest branch:
```gdscript
				if level == coarsest:
					tex = _pool.request_page_eager(level, gx, gz)          # floor
```
to:
```gdscript
				if level == coarsest:
					tex = _pool.request_page_coarsest(level, gx, gz)       # floor, bounded+spread (P3)
```
Add the export by the others (~line 36):
```gdscript
@export var max_coarsest_per_frame: int = 16   # render-forever P3: spread the coarsest in-fill (own cap so it can't starve)
```
Push it to the pool in `_ready()` near `set_max_eager_per_frame` (~line 90):
```gdscript
	if _pool.has_method("set_max_coarsest_per_frame"):
		_pool.set_max_coarsest_per_frame(max_coarsest_per_frame)
```
(The `has_method` guard keeps world_view working even against an older DLL.)

- [ ] **Step 5: Run the never-black gate (THE Pillar-3 guardrail) + burst + suite**

```powershell
$g = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m1_9b_eager_spread_check.gd
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m1_5c_coverage_check.gd
& $g --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_6_burst_perf_check.gd
```

Expected: `m1_9b_eager_spread_check` PASS (never-black still holds with the coarsest now bounded — THE key assertion), `m1_5c_coverage_check` PASS, `m2_6_burst_perf_check` PASS (the burst that triggered this is now spread → back under budget). If never-black FAILS → the cap is too low / starving the floor → raise `max_coarsest_per_frame` (or widen `evict_margin`) and re-run; if it can't be made green in 3 honest tries, REVERT this task and log (do not stack fixes).

- [ ] **Step 6: Run the full 10-gate suite**

Same loop as Task 1 Step 3. Expected: all PASS. (m1_7a/b/c especially — the Rust change touches the pool collision/heights path indirectly via begin_frame counters; confirm no drift.)

- [ ] **Step 7: PARK-FOR-VISUAL — fly + teleport the frontier**

`run.ps1`. DRIFT_LOG PARKED: "Pillar 3: coarsest level bounded (own cap max_coarsest_per_frame=16). never-black gate GREEN, burst GREEN [numbers]. Believe continuous + teleport streaming now spreads with no hitch and no black. Awaiting human: turbo-fly and jump-teleport — any black flash at the frontier? any hitch? Did NOT proceed." STOP.

- [ ] **Step 8: Commit**

`git diff --cached --name-only` to CONFIRM what's staged. Stage our files; if Codex's inert page_pool edits are unavoidably included, NOTE it explicitly in the commit body.
```powershell
git add "rust/gdext/src/page_pool.rs" "wg-13/scripts/world_view.gd" "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md"
# d:/tmp/msg.txt: "[render-forever P3] bound coarsest level (own per-frame cap, can't starve floor); never-black gate green; burst spread under budget; parked for visual"
git commit -F d:/tmp/msg.txt
```

---

## Task 5: Close — update docs, final suite, milestone state

**Files:** `PROGRESS.md`, `DRIFT_LOG.md`, `04_CODE_MAP.md`, `HANDOFF.md` §3.

- [ ] **Step 1: Final full 10-gate suite (the banked-green confirmation)**

Run the full loop (Task 1 Step 3). Expected: all PASS. Quote the final `m2_6_burst_perf_check` number.

- [ ] **Step 2: Update PROGRESS.md**

Add the render-forever lines (P1 reach, P2 fog, P3 spread [or "skipped YAGNI"], P4 budget held) with the gate evidence. Mark the track done pending the human visual passes.

- [ ] **Step 3: Update 04_CODE_MAP.md**

Note the new num_levels=8 / reach ~195km and the fog/far ratios (and the new coarsest cap if Task 4 ran) so the next session sees the live config.

- [ ] **Step 4: Refresh HANDOFF.md §3**

New current state: render-forever shipped (range+fog+[spread]); gates green; visual gates parked for the human; next track TBD. Quote HEAD.

- [ ] **Step 5: Commit the docs close**

```powershell
git add "plans and docs/plans/PROGRESS.md" "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/04_CODE_MAP.md" "plans and docs/plans/HANDOFF.md"
# d:/tmp/msg.txt: "[render-forever] docs: range+fog+spread banked green; visual gates parked; handoff refreshed"
git commit -F d:/tmp/msg.txt
```

---

## Self-review notes (addressed inline)

- **Spec coverage:** P1 (Task 1), P2 (Task 2), P4 (Task 3, sequenced before P3 deliberately), P3 (Task 4, evidence-gated). Gate plan from the spec maps 1:1. Non-goals (camera-relative origin, finer far tex) correctly excluded unless a measured failure triggers them (noted as their own future step in Task 1 Step 5 / the spec).
- **The 0.85 ratio honesty:** Task 2 Step 3 confronts that the static coarsest ring edge (≈reach) EXCEEDS fog_end=0.85*reach, and resolves it honestly (flight-frontier ≈ coarsest_span IS inside fog; teleport edge relies on the persistent blanket + visual gate). This matches the spec's "0.85 is a starting point, confirm against the measurement; the gate's measurement is the source of truth."
- **Rust risk / Codex coordination:** Pillars 1/2/4 are GDScript-only (no rebuild, no Rust commit). Pillar 3's Rust change is isolated (new enum variant + field + func), `git diff` first, STOP-and-log if it can't be cleanly separated from Codex's edits.
- **Never-black:** the M1-foundational invariant is the explicit gate guardrail for Pillar 3 (`m1_9b_eager_spread_check`), with a revert-not-stack rule if it can't go green.
