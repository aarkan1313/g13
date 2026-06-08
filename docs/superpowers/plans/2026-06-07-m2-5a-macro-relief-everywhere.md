# M2.5a — Macro relief everywhere — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Retune the `composition_height` uplift so the world has believable landforms EVERYWHERE (ranges + valleys + rolling lowland) instead of ~95% flat with rare isolated ranges — the approved "between P1.3 and P1.6" feel from the live vista captures.

**Architecture:** A pure constant retune inside `field_height.glsl::composition_height` (the GPU world-math source of truth). No new field channels, no Rust change, no contract change. Heights stay analytic + continuous so the M2.4 analytic normal and M1.7 collision keep working. The change touches two DEPENDENT systems whose gates must be re-verified and adjusted as deliberate decisions: the m2_3 no-cliff threshold and the climate altitude-cooling window.

**Tech Stack:** GLSL compute (the field), Godot 4.6.2 GDScript gates, run via the `_console` Godot exe with `--rendering-driver vulkan`. No `cargo` rebuild (shader-only).

**Spec:** `docs/superpowers/specs/2026-06-07-m2-5-terrain-everywhere-biome-shape-design.md`

**Toolchain reminders (01_TOOLCHAIN):** GPU gates need `--rendering-driver vulkan` (NOT `--headless`). No rebuild needed (GLSL change, hot). Commit messages ASCII via `git commit -F` tempfile. Godot console exe:
`C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe`

---

### Task 1: Retune the macro uplift knobs

**Files:**
- Modify: `wg-13/shaders/field_height.glsl:186-197` (the `composition_height` const block)

- [ ] **Step 1: Capture the pre-change gate baseline (so we can attribute any gate change to THIS edit)**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_3_composition_check.gd"
```
Expected: `M2.3 RESULT: PASS`, and note the printed `INFO: ... spread=NN` and `PASS: no cliff — max step NN within 600`. Record the max-step number — the retune will raise it.

- [ ] **Step 2: Apply the approved knob retune**

In `wg-13/shaders/field_height.glsl`, in `composition_height`, change these consts. (Values = the locked "between P1.3 and P1.6" feel. Keep all OTHER consts unchanged.)

```glsl
    const float UPLIFT_FREQ  = 0.000075; // range placement (~13 km regions) — landforms everywhere (was 0.000025/~40km)
    const float UPLIFT_LO    = 0.25;     // much more land stands up (was 0.45)
    const float UPLIFT_HI    = 0.59;     // narrower flat gap -> ranges everywhere with valleys between (was 0.70)
```
and
```glsl
    const float RELIEF_AMP   = 1975.0;   // taller peaks (was 1600)
```
and
```glsl
    const float BASE_AMP     = 300.0;    // more rolling everywhere, even lowland (was 180)
```

- [ ] **Step 3: Run the composition gate; expect spread PASS, cliff likely FAIL (taller terrain)**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_3_composition_check.gd"
```
Expected: `PASS: structure — wide relief spread` (spread should stay >0.5 — likely HIGHER now). The `no cliff` check MAY now FAIL with `cliff: max step NN > 600` because relief went 1600->1975 and lowland base 180->300 (more vertical change per cell). This is EXPECTED and handled in Task 2 — do not "fix" it by reverting the retune.

- [ ] **Step 4: Commit the retune (gate state recorded honestly in the message)**

```
cd "D:\world gen 13"
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile with ASCII message>
```
Message body:
```
[M2.5a] macro uplift retune: landforms everywhere (approved vista feel)

composition_height uplift retuned to the live-capture-approved "between P1.3
and P1.6" feel: UPLIFT_FREQ 0.000025->0.000075 (ranges ~13km not ~40km),
UPLIFT_LO/HI 0.45/0.70 -> 0.25/0.59 (much more land stands up, valleys between),
RELIEF_AMP 1600->1975, BASE_AMP 180->300. World now has believable relief
everywhere instead of ~95% flat with rare isolated ranges (the "view not far /
not Skyrim" root cause, proven by vista captures -- it was composition, not reach).

Pure constant retune, GLSL-only, no Rust/contract change; heights stay analytic
+ continuous (M2.4 normal + M1.7 collision intact). m2_3 spread PASS; the no-cliff
gate threshold is addressed next (taller relief raised max adjacent step).
```

---

### Task 2: Re-verify / adjust the dependent no-cliff gate threshold (deliberate decision)

**Files:**
- Modify (only if needed): `wg-13/tests/m2_3_composition_check.gd:67` (the `> 600.0` cliff threshold)

- [ ] **Step 1: Read the actual max-step the retune produced**

From Task 1 Step 3 output, read the `max step NN` value. If the gate PASSED (max step still <=600), SKIP this task entirely — go to Task 3.

- [ ] **Step 2: Decide — is the new max-step a believable slope or a real cliff?**

The gate exists to catch a regression to "vertical walls / octave-sum garbage", not to forbid tall mountains. A level-0 cell is `spacing`=4m wide. Max step S over 4m = slope atan(S/4). Compute it:
- 600m/4m was already ~89.6deg (basically the gate is "no near-vertical wall per cell at the FINEST spacing"). NOTE the gate samples the ORIGIN page at the gate's own RES/spacing — read the gate to confirm the cell width it uses before judging the angle.
- If the new max-step reflects taller-but-still-sloped terrain (not a true vertical wall), raise the threshold to a value that still catches walls but allows the new relief. Recommended: set it to ~1.3x the observed max-step, rounded, and document WHY in the gate comment.

- [ ] **Step 3: If raising the threshold, edit the gate**

In `wg-13/tests/m2_3_composition_check.gd`, line ~67, change:
```gdscript
	if ms > 600.0: _fail("cliff: max step %.1f > 600" % ms)
	else: print("PASS: no cliff — max step %.1f within 600" % ms)
```
to (substitute NEW_THRESHOLD = your chosen value, e.g. 900.0):
```gdscript
	# M2.5a: raised 600->NEW_THRESHOLD. The macro retune (RELIEF_AMP 1600->1975,
	# BASE_AMP 180->300) makes taller terrain with bigger but still-sloped steps;
	# this threshold still catches a vertical-wall / octave-sum regression while
	# allowing the approved relief. (Cell width unchanged; this is a height-scale bump.)
	if ms > NEW_THRESHOLD: _fail("cliff: max step %.1f > NEW_THRESHOLD" % ms)
	else: print("PASS: no cliff — max step %.1f within NEW_THRESHOLD" % ms)
```

- [ ] **Step 4: Re-run the composition gate, expect full PASS**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_3_composition_check.gd"
```
Expected: `M2.3 RESULT: PASS` (both structure and no-cliff).

- [ ] **Step 5: Commit**

```
cd "D:\world gen 13"
git add wg-13/tests/m2_3_composition_check.gd
git commit -F <tempfile>
```
Message: `[M2.5a] m2_3 no-cliff threshold 600->NEW_THRESHOLD (taller relief, still catches walls)`

---

### Task 3: Re-verify climate + biome gates still pass under taller terrain

**Files:**
- Modify (only if a gate trips): `wg-13/shaders/field_height.glsl:241` (climate `alt_norm` window)

- [ ] **Step 1: Run the climate gate**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_1_climate_check.gd"
```
Expected: `M2.1 RESULT: PASS`. The climate `alt_norm = clamp((height-150.0)/200.0, 0,1)` saturates at height=350m; taller terrain just means MORE ground reads as fully-cooled high ground, which is correct (high = cold). The gate checks range[0,1]/determinism/latitude gradient — none depend on the height scale — so this should PASS unchanged.

- [ ] **Step 2: Run the biome gate**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m2_2_biome_check.gd"
```
Expected: `M2.2 RESULT: PASS`. Biomes classify from `macro_altitude` (a SEPARATE low-freq field, unchanged by this retune) + climate, NOT the render height — so biome contiguity/validity is unaffected. If it FAILS, STOP and report (it would mean an unexpected coupling); do NOT patch around it.

- [ ] **Step 3: (Only if Step 1 climate FAILED) widen the alt window — else skip**

If and only if m2_1 failed on an altitude-related assertion, in `field_height.glsl:241` widen the cooling window so the taller range maps sensibly:
```glsl
    float alt_norm = clamp((height - 150.0) / 400.0, 0.0, 1.0);  // M2.5a: widen for taller relief
```
Re-run Step 1; expect PASS. (If it passed in Step 1, do nothing.)

- [ ] **Step 4: Commit only if a change was made in Step 3**

```
cd "D:\world gen 13"
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile>
```
Message: `[M2.5a] widen climate alt-cool window for taller relief (m2_1 PASS)`

---

### Task 4: Re-verify collision/height contract (M1.7) still holds

**Files:** none (verification only)

- [ ] **Step 1: Run the heights/no-drift gate**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m1_7a_heights_check.gd"
```
Expected: `M1.7a RESULT: PASS` (collision heights == independent FieldCompute of the same params; the retune is just different constants in the same one source).

- [ ] **Step 2: Run the stand-on-terrain collision gate**

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/m1_7c_stand_check.gd"
```
Expected: `M1.7c RESULT: PASS`. If it FAILS on steep terrain (capsule can't stand / slides), that is CHARACTER-CONTROLLER work (M2.7), NOT a terrain problem — log it in DRIFT_LOG as an M2.7 follow-up and do NOT roll back the terrain. (The spec names this explicitly.)

- [ ] **Step 3: Run the streaming-policy + origin gates (sanity, retune touches none of them)**

Run each:
```
... --script "res://tests/m1_5d_rust_streaming_check.gd"
... --script "res://tests/m1_8_origin_rebase_check.gd"
```
Expected: both `RESULT: PASS`.

---

### Task 5: Human visual gate (the real acceptance) + DRIFT_LOG + PROGRESS

**Files:**
- Modify: `plans and docs/plans/DRIFT_LOG.md` (prepend an entry)
- Modify: `plans and docs/plans/PROGRESS.md` (M2.5a line)

- [ ] **Step 1: Launch the production scene for the human fly/walk**

Run:
```
& "D:\world gen 13\run.ps1"
```
This launches `demo.tscn` (production `world_view`). Hand to the human with the questions:
1. Are there believable landforms EVERYWHERE — ranges, valleys, rolling — with something always on the horizon? (the M2.5a goal)
2. Does it still read believable up close on a walk (G), not noisy/garbage?
3. Walk steep terrain — can you traverse it? (If not, that's M2.7, logged, not a terrain rollback.)

- [ ] **Step 2: On human PASS, append a DRIFT_LOG entry (TYPE: visual PASS) summarizing the retune, the gate-threshold decision, and the result.**

- [ ] **Step 3: Update PROGRESS.md — add the M2.5a line marked done with the gate evidence + human PASS.**

- [ ] **Step 4: Commit the docs**

```
cd "D:\world gen 13"
git add "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/PROGRESS.md"
git commit -F <tempfile>
```
Message: `[M2.5a] docs: macro-relief-everywhere visual PASS + gates green`

- [ ] **Step 5: Flag the next steps to the human**

Remind: M2.5b (biomes-are-terrain per-biome detail) is the next gated milestone (own brainstorm + captures). Also surface the user's request to REVIEW and consider pulling erosion (M6) + water (M5) earlier now that terrain has real relief.

---

## Notes for the executor

- This is shader-only — do NOT `cargo build`; GLSL changes hot-reload. If the open editor is running, it does not lock the shader (only the dll).
- The retune values are the locked FEEL, but exact numbers are tunable: if the human says "a bit more/less dramatic," nudge UPLIFT_LO/HI (coverage) and RELIEF_AMP/BASE_AMP (height) — that is tuning, not a redesign.
- NEVER silently loosen a gate. Task 2/3 thresholds change only as a stated decision with a code comment explaining why, and only when the new value still catches the regression the gate guards.
- If 2+ gates fail in unexpected ways, STOP and report — do not stack fixes (systematic-debugging: revert, don't pile on).
