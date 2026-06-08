# M2.5b — Regional-archetype terrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the binary "mountains-or-plains" terrain with a journey through distinct regions — each region its own landform archetype (plains / forest-hills / alpine / swamp / mesa / highlands) blended by macro climate, plus sparse one-off landmark peaks — with biome COLOR matched to the archetype.

**Architecture:** Rewrite ONLY `composition_height` in the GPU field shader (the framework — streaming, climate classifier, analytic-normal seam fix, collision — is kept). Region character is chosen from MACRO climate (macro_altitude + macro temp/moisture, NOT detailed height) so there is no circular dependency. The proven prototype already exists at `wg-13/shaders/field_height_probe.glsl` (committed reference) — this plan PORTS it into production `field_height.glsl`, then refines + matches biome color, gated.

**Tech Stack:** GLSL compute (the field, source of truth), Godot 4.6.2 GDScript gates run via the `_console` exe with `--rendering-driver vulkan`. No `cargo` rebuild (shader-only). Captures via a vista script (provided).

**Spec:** `docs/superpowers/specs/2026-06-07-m2-5b-regional-archetype-terrain-design.md`
**Reference (proven probe):** `wg-13/shaders/field_height_probe.glsl`, `wg-13/captures/journey_vista.gd`

**Toolchain (01_TOOLCHAIN):**
- Console exe: `C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe`
- Gate: `& "<console>" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/<gate>.gd"` -> prints `... RESULT: PASS|FAIL`.
- Kill Godot first: `Get-Process Godot* -ErrorAction SilentlyContinue | Stop-Process -Force`
- Commit ASCII via tempfile: `git -C "D:\world gen 13" commit -F <tempfile>`; end body with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- NO `cargo build` (GLSL only, hot). The open editor does NOT lock the shader.

**HARD RULES:** Never silently loosen a gate (change a threshold only as a stated decision + code comment, only when it still catches the regression). Never roll back terrain to pass a gate — steep-terrain walkability failures are M2.7, logged. If 2+ gates fail unexpectedly, STOP and report (don't stack fixes).

---

### Task 1: Port the regional composition into production field_height.glsl

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (replace `composition_height` + add the archetype helpers ABOVE it; keep the `main()` and its 4 analytic-normal neighbor calls unchanged)
- Reference (read, copy from): `wg-13/shaders/field_height_probe.glsl` (the helpers + composition are lines ~179-292 in the probe — `macro_climate`, `arch_*`, `band`, `lone_peaks`, `composition_height`, and the `float macro_altitude(...)` forward decl)

- [ ] **Step 1: Baseline-record the current gates (attribute later changes to THIS task)**

Run and record each RESULT line:
```
... --script "res://tests/m2_3_composition_check.gd"   # record spread + max step
... --script "res://tests/m1_4_seam_check.gd"
... --script "res://tests/m2_6_burst_perf_check.gd"     # record median + median-of-maxes
```
Expected: all PASS. (m2_6_burst still uses production world_view — this is the perf baseline to beat after the rewrite.)

- [ ] **Step 2: Copy the archetype block from the probe into production**

In `wg-13/shaders/field_height.glsl`, locate the current `composition_height` (the M2.5a version: a `const` block + `uplift_field`/`ridged_fbm`/`valley_carve` composition, ~lines 179-211). REPLACE the entire `composition_height` function AND insert ABOVE it the helper block from the probe. Copy VERBATIM from `field_height_probe.glsl` the section that begins with the comment `// M2.5b PROBE — REGIONAL-ARCHETYPE terrain` through the end of `composition_height`. That block contains, in order: the `float macro_altitude(vec2, uint);` forward declaration, `macro_climate`, `arch_plains`, `arch_forest_hills`, `arch_alpine`, `arch_swamp`, `arch_mesa`, `arch_highlands`, `band`, `lone_peaks`, and the new `composition_height`.

CRITICAL: `composition_height` calls `macro_altitude`, which is DEFINED LATER in the file (~line 261). The forward declaration `float macro_altitude(vec2 world_xz, uint seed);` MUST be present before `composition_height` or it won't compile. (The probe includes it — keep it.)

Update the block's lead comment from "PROBE ... throwaway, judged by vista capture" to "M2.5b: regional-archetype terrain" (it's production now, not a probe).

- [ ] **Step 3: Remove now-dead M2.3 machinery ONLY if unreferenced**

After the replace, search the file for remaining uses of `uplift_field`, `valley_carve`. Run:
```
Select-String -Path "D:\world gen 13\wg-13\shaders\field_height.glsl" -Pattern "uplift_field|valley_carve"
```
If each appears ONLY at its own definition (no caller), delete its definition (dead code = slop). If `ridged_fbm`/`value_fbm`/`domain_warp` are still used by the archetypes (they are), KEEP them. If anything is still referenced, leave it. Do not remove `macro_altitude`, `climate`, `biome_id`, `value_noise`, `hash_u`, `fade`, `hash2`.

- [ ] **Step 4: Compile-check via a gate (a gate run compiles the shader)**

Run:
```
... --script "res://tests/m1_4_seam_check.gd"
```
Expected: `M1.4 RESULT: PASS`. If it prints a shader COMPILATION error (e.g. "macro_altitude not declared", "redefinition"), the forward-decl or a duplicate is wrong — fix and re-run. m1_4 passing also proves seam-free heights hold (the analytic normal re-derives from the new continuous composition_height by construction).

- [ ] **Step 5: Run the composition + climate + biome + collision gates**

Run each, record RESULT:
```
... --script "res://tests/m2_3_composition_check.gd"   # spread should be HIGH (varied); max step may rise
... --script "res://tests/m2_1_climate_check.gd"
... --script "res://tests/m2_2_biome_check.gd"
... --script "res://tests/m1_7a_heights_check.gd"
... --script "res://tests/m1_7c_stand_check.gd"
```
Expected: structure PASS (spread > 0.5). The m2_3 no-cliff (`max step > 600`) MAY trip now (alpine + lone_peaks are taller/steeper than M2.5a). If it does, go to Task 2. m2_1/m2_2 should PASS (climate/biome read macro fields unchanged here). If m1_7c fails on steep terrain, that's M2.7 — log it, do not revert.

- [ ] **Step 6: PERF — re-run the burst gate (the named top risk)**

Run:
```
... --script "res://tests/m2_6_burst_perf_check.gd"
```
Expected: compare median-of-maxes to the Step 1 baseline. The new composition_height sums 6 archetypes and is called 4x/cell for normals, so production cost WILL rise. ACCEPTABLE if still `0/720 over budget` (or within a few). If it blew the budget materially (e.g. median-of-maxes jumped >1.5x and frames go over 16.6), go to Task 3 (perf optimization) BEFORE committing. If within budget, proceed.

- [ ] **Step 7: Commit**

```
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile>
```
Message: `[M2.5b] composition_height -> regional archetypes (ported from proven probe)` + body noting: regions blended by macro climate, lone-peak landmarks, framework/seam-fix kept, gate results (spread, max step, burst median-of-maxes vs baseline).

---

### Task 2: (Conditional) Re-decide the no-cliff threshold for taller archetypes

**Files:**
- Modify (only if Task 1 Step 5 tripped it): `wg-13/tests/m2_3_composition_check.gd` (the `if ms > 600.0` cliff check, ~line 67)

- [ ] **Step 1: If the no-cliff check PASSED in Task 1, SKIP this task. Else read the new max-step value from Task 1 Step 5.**

- [ ] **Step 2: Judge: real wall or believable steep range?**

The gate guards against vertical-wall / octave-sum garbage at the FINEST spacing. Alpine ridges + lone-peak cones are STEEP but sloped, not vertical. If the new max-step reflects steep-but-sloped terrain, raise the threshold to ~1.3x the observed value, rounded. (If it's a literal vertical wall — e.g. a lone_peaks cone with a discontinuity — that's a real bug in the archetype; fix the archetype instead, do NOT raise the threshold.)

- [ ] **Step 3: If raising, edit the gate with a documented reason**

In `wg-13/tests/m2_3_composition_check.gd` ~line 67, change `600.0` to NEW value (e.g. 1200.0) in BOTH the `if` and the message, and add a comment:
```gdscript
	# M2.5b: raised from M2.5a's value -> NEW. Alpine ridges + lone-peak landmarks
	# are steep-but-sloped (not vertical walls); this still catches a true wall /
	# octave-sum regression while allowing the taller regional archetypes. Cell
	# width unchanged.
	if ms > NEW: _fail("cliff: max step %.1f > NEW" % ms)
	else: print("PASS: no cliff — max step %.1f within NEW" % ms)
```

- [ ] **Step 4: Re-run, expect PASS; commit**

```
... --script "res://tests/m2_3_composition_check.gd"   # expect M2.3 RESULT: PASS
git add wg-13/tests/m2_3_composition_check.gd
git commit -F <tempfile>   # "[M2.5b] m2_3 no-cliff threshold for steeper archetypes (still catches walls)"
```

---

### Task 3: (Conditional) Perf — only evaluate significant-weight archetypes

**Files:**
- Modify (only if Task 1 Step 6 blew the budget): `wg-13/shaders/field_height.glsl` (`composition_height`)

- [ ] **Step 1: If burst was within budget in Task 1, SKIP this task.**

- [ ] **Step 2: Gate each archetype eval behind a weight threshold**

The cost is 6 archetype evals x4 (normals). Most cells are dominated by 1-2 archetypes; the rest contribute ~0. In `composition_height`, after computing the weights, skip near-zero ones. Replace the unconditional weighted sum:
```glsl
    float h = macro_base + (
          w_alpine   * arch_alpine(world_xz, seed)
        + w_highland * arch_highlands(world_xz, seed)
        + w_forest   * arch_forest_hills(world_xz, seed)
        + w_mesa     * arch_mesa(world_xz, seed)
        + w_swamp    * arch_swamp(world_xz, seed)
        + w_plains   * arch_plains(world_xz, seed)
    ) / wsum;
```
with guarded accumulation (a weight below EPS contributes negligibly; skipping it changes the result by <EPS/wsum, imperceptible, and is deterministic — same threshold every cell):
```glsl
    const float WEPS = 0.02;   // below this a region barely contributes; skip its eval
    float acc = 0.0;
    if (w_alpine   > WEPS) acc += w_alpine   * arch_alpine(world_xz, seed);
    if (w_highland > WEPS) acc += w_highland * arch_highlands(world_xz, seed);
    if (w_forest   > WEPS) acc += w_forest   * arch_forest_hills(world_xz, seed);
    if (w_mesa     > WEPS) acc += w_mesa     * arch_mesa(world_xz, seed);
    if (w_swamp    > WEPS) acc += w_swamp    * arch_swamp(world_xz, seed);
    if (w_plains   > WEPS) acc += w_plains   * arch_plains(world_xz, seed);
    float h = macro_base + acc / wsum;
```
NOTE: branching in a compute shader can cost on divergent warps, but skipping 4 of 6 fbm evals on most cells is a net win. If it does NOT help (measure!), revert this and instead reduce octave counts in the archetypes (e.g. alpine RIDGE_OCT 6->5). Do not stack both — try one, measure, keep the winner (systematic-debugging).

- [ ] **Step 3: Re-run seam + burst; both must hold**

```
... --script "res://tests/m1_4_seam_check.gd"            # heights still continuous (WEPS is deterministic)
... --script "res://tests/m2_6_burst_perf_check.gd"      # median-of-maxes should drop toward baseline
```
Expected: m1_4 PASS, burst back within budget (0/720 or close). If still over, report — do not keep stacking.

- [ ] **Step 4: Commit**

```
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile>   # "[M2.5b] perf: skip near-zero-weight archetype evals (burst back in budget)"
```

---

### Task 4: Tune each archetype to read believable (vista + walk gates)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (the `arch_*` recipe constants)
- Use: `wg-13/captures/journey_vista.gd` (already committed; renders a 5-spot transect to `_captures/journey_N.png`)

- [ ] **Step 1: Render the journey vistas of the PRODUCTION terrain**

The capture currently points at the probe shader. Edit `wg-13/captures/journey_vista.gd`: change the two occurrences of `field_height_probe.glsl` to `field_height.glsl` (so it captures production). Then:
```
... --script "res://captures/journey_vista.gd"
```
Open `wg-13/_captures/journey_0.png` .. `journey_4.png`. Judge each region against the spec: plains should read as plains (NOT dune-ish — the probe's `arch_plains` was flagged), forest-hills rolling, alpine rugged, swamp low/wet, mesa terraced, highlands medium-rocky.

- [ ] **Step 2: Fix the dune-ish plains (the one flagged in the spec)**

In `arch_plains`, the probe used a single low-freq fbm that reads dune-like. Make it flatter + less wavy:
```glsl
float arch_plains(vec2 p, uint seed) {
    // very gentle, long-wavelength only -> reads as open plain, not dunes
    float roll = value_fbm(p * 0.00008, seed ^ 0x504c4149u, 2u, 2.0, 0.5) * 90.0;
    float micro = (value_fbm(p * 0.0012, seed ^ 0x706c6e32u, 2u, 2.0, 0.5) - 0.5) * 2.0 * 18.0;
    return roll + micro;
}
```
Re-render (Step 1 command), re-judge. Iterate amplitude/freq until plains read flat-but-natural.

- [ ] **Step 3: Spot-check the wetter/drier regions exist**

The 5 default transect spots may not land on swamp/mesa. Temporarily add 3 spots to `SPOTS` in `journey_vista.gd` chosen to hit them — find them by sampling: a swamp needs low macro_alt + high moisture, mesa needs dry+hot. If you cannot find a swamp/mesa region in a reasonable search, that means the weight bands rarely co-occur — widen `w_swamp`/`w_mesa` bands in `composition_height` so those regions actually appear. Re-render, confirm each archetype is reachable somewhere.

- [ ] **Step 4: Commit the tuned archetypes**

```
git add wg-13/shaders/field_height.glsl wg-13/captures/journey_vista.gd
git commit -F <tempfile>   # "[M2.5b] tune archetypes: flatter plains, ensure swamp/mesa regions appear"
```

---

### Task 5: Match biome COLOR to the archetype regions

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (only if choosing option B — re-tune classifier inputs) OR `rust/gdext/src/page_pool.rs` BIOME_CENTROIDS (option B) — **prefer option A, no Rust change**
- Reference: `wg-13/shaders/ring_displace.gdshader` (the BIOME_COLORS table the display uses)

- [ ] **Step 1: Diagnose the mismatch**

Render a journey vista in BIOME view (the capture uses default view_mode 0 = height shading). To see biome color, the capture would need `view_mode` 3. Simpler: launch the live scene (`& "D:\world gen 13\run.ps1"`), press V to biome mode, fly the regions. Confirm the problem: e.g. a swamp-SHAPED region is colored as something non-swampy, because biome classification (M2.2: temp/moist/macro_alt -> nearest centroid) is independent of the archetype weights.

- [ ] **Step 2: Option A (preferred, no Rust) — drive display biome from the SAME archetype weights**

The archetypes already correspond to biome intent (alpine=rock, swamp=swamp, forest=forest...). Output the DOMINANT archetype as the biome id directly, so color == shape by construction. In `composition_height`'s caller path: currently `main()` computes `bid = biome_id(temp,moist,alt)`. Instead, expose the dominant archetype. Add a function that returns the dominant archetype index mapped to the matching BIOME_COLORS index (in `ring_displace.gdshader`: 0 snow,1 tundra,2 taiga,3 rock,4 grassland,5 forest,6 rainforest,7 desert,8 savanna,9 tropical). Map: alpine->3 (rock) or 0 (snow if cold), highlands->3/4, forest_hills->5, plains->4 (grassland), swamp->6 or 9 (wet), mesa->7 (desert). Implement `archetype_biome(weights, temp) -> float id` and set `bid` from it in `main()` (replace the `biome_id(...)` call). Keep `biome_id` defined (other gates/tools may use it) but the render path uses the archetype mapping.

  Concretely, after the weights are computed in `composition_height`, you need them in `main()`. Cleanest: make `composition_height` ALSO return the dominant biome id via an `out` param, or add a small `dominant_biome(world_xz, seed)` that recomputes the weights (cheap — it's the band() math, no fbm) and returns the mapped id. Use `dominant_biome` in `main()`:
```glsl
// after macro_alt/temp/moist as in composition: pick the max-weight archetype -> color id
float dominant_biome(vec2 world_xz, uint seed) {
    vec2 rp = domain_warp(world_xz, seed ^ 0x52454749u, 3000.0, 0.00003);
    float macro_alt = macro_altitude(rp, seed);
    vec2 mc = macro_climate(rp, seed, macro_alt);
    float w_alpine=band(macro_alt,0.85,0.16), w_high=band(macro_alt,0.62,0.14),
          w_for=band(macro_alt,0.45,0.16)*band(mc.y,0.6,0.35),
          w_mesa=band(macro_alt,0.5,0.2)*band(mc.y,0.15,0.18)*band(mc.x,0.8,0.3),
          w_swamp=band(macro_alt,0.28,0.12)*band(mc.y,0.85,0.25), w_plain=band(macro_alt,0.32,0.18);
    // map dominant -> BIOME_COLORS index; alpine cold-> snow(0) else rock(3)
    float bestw=w_plain; float id=4.0;            // grassland default
    if (w_for>bestw){bestw=w_for; id=5.0;}        // forest
    if (w_high>bestw){bestw=w_high; id=3.0;}      // rock
    if (w_mesa>bestw){bestw=w_mesa; id=7.0;}      // desert
    if (w_swamp>bestw){bestw=w_swamp; id=9.0;}    // tropical/wet (greenest wet color)
    if (w_alpine>bestw){bestw=w_alpine; id = (mc.x < 0.35) ? 0.0 : 3.0;}  // snow if cold else rock
    return id;
}
```
   Then in `main()` replace `float bid = biome_id(c.x, c.y, alt);` with `float bid = dominant_biome(world_xz, uint(seed));`.

- [ ] **Step 3: Verify color == shape**

Re-run the biome gate (it asserts valid ids + contiguity):
```
... --script "res://tests/m2_2_biome_check.gd"
```
Expected: PASS (ids are valid [0,10), and dominant-archetype is contiguous because the weight bands are low-frequency/continuous). If contiguity fails, the band frequencies are too high — they share `macro_altitude`'s low frequency, so this should hold; if not, report.
Then live: `run.ps1`, press V to biome, fly — confirm a swamp-shaped region is swamp-colored, alpine is rock/snow, etc.

- [ ] **Step 4: Commit**

```
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile>   # "[M2.5b] biome color = dominant archetype (color matches shape)"
```

---

### Task 6: Tune lone-peak landmarks (density, size, far-LOD)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (`lone_peaks` constants)

- [ ] **Step 1: Judge landmark frequency from the journey vistas + a far view**

From Task 4's captures, count lone peaks. Spec wants RARE + memorable, not a polka-dot field. The probe used `present > 0.82` (~18% of 22km tiles). If too frequent, raise the threshold (e.g. `> 0.90` ~10%); if too sparse, lower it. Also render a HIGH far vista (eye ~4000m) to confirm peaks don't read as thin spikes at distance:

Temporarily set one `journey_vista.gd` spot's eye height to 4000m and look at a known peak; re-render; confirm the cone has believable shoulders at range (the probe smooths the cone — verify).

- [ ] **Step 2: Adjust `lone_peaks` constants as judged**

Tune in `lone_peaks`: `present >` threshold (density), `radius` mix range (footprint), `peak` mix range (height). Keep the `cone*cone*(3-2*cone)` smoothing + the `rough` flank modulation (they prevent ice-cream-cone look). Re-render until rare + believable near AND far.

- [ ] **Step 3: Re-run seam + no-cliff (peaks must not punch vertical walls)**

```
... --script "res://tests/m1_4_seam_check.gd"           # PASS
... --script "res://tests/m2_3_composition_check.gd"    # no-cliff still within threshold
```
If a peak trips no-cliff, its cone is too steep near the apex — widen min `radius` or lower max `peak`; do NOT raise the gate threshold for a peak (a peak that trips a per-cell wall check at 4m spacing IS too steep).

- [ ] **Step 4: Commit**

```
git add wg-13/shaders/field_height.glsl
git commit -F <tempfile>   # "[M2.5b] tune lone-peak landmarks (rare, believable near+far)"
```

---

### Task 7: Human journey acceptance + docs + roadmap review

**Files:**
- Modify: `plans and docs/plans/DRIFT_LOG.md`, `plans and docs/plans/PROGRESS.md`

- [ ] **Step 1: Full gate sweep (regression guard)**

Run all and confirm PASS:
```
m1_4_seam_check, m1_7a_heights_check, m1_7c_stand_check, m1_5d_rust_streaming_check,
m1_8_origin_rebase_check, m2_1_climate_check, m2_2_biome_check, m2_3_composition_check,
m2_6_burst_perf_check, m2_6_vram_check
```

- [ ] **Step 2: Launch for the human journey fly/walk (the real gate)**

```
& "D:\world gen 13\run.ps1"
```
Human questions: (1) Flying a long line, do you pass THROUGH distinct regions — range, plain, lone peak, swamp, forest — a journey, not uniform? (2) Walk (G) in a few regions — believable up close? (3) V -> biome: does color match shape (swamp looks swampy)? (4) Steep regions walkable? (if not -> M2.7, logged, not a rollback).

- [ ] **Step 3: On human PASS — DRIFT_LOG entry**

Prepend a DRIFT_LOG entry (TYPE: visual PASS) summarizing M2.5b: regional archetypes + landmarks + color-match, gate results, any threshold decisions, any M2.7 walkability follow-ups.

- [ ] **Step 4: PROGRESS.md**

Add the M2.5b line marked done with the gate evidence + human PASS. Mark M2.4/M2.5 shape work resolved by the regional-archetype approach.

- [ ] **Step 5: Decommission the probe (it's now production)**

The probe served its purpose. Either delete `wg-13/shaders/field_height_probe.glsl` (it's in git history) or leave it with a header note "superseded by field_height.glsl M2.5b". Prefer DELETE (no dead duplicate shader = no slop). Commit.

- [ ] **Step 6: Commit docs + raise the roadmap review**

```
git add "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/PROGRESS.md"
git commit -F <tempfile>   # "[M2.5b] docs: regional terrain visual PASS; gates green"
```
Then surface to the human: terrain shape is now in a good place — REVIEW whether to pull **M5 (water)** and **M6 (erosion)** earlier, per their request (erosion carves the new relief; water settles in the valleys/swamps). That review is its own brainstorm, not part of this plan.

---

## Notes for the executor

- Shader-only — do NOT `cargo build`. GLSL hot-reloads.
- The probe (`field_height_probe.glsl`) is your source of truth for the recipe code in Task 1 — copy from it, don't re-derive.
- Tasks 2 and 3 are CONDITIONAL (only if a gate trips / perf blows). Skip if not triggered; note in the commit log that they were N/A.
- Tuning tasks (4, 6) are visual-judgment loops — capture, look, adjust, repeat. The numbers given are starting points, not final.
- If perf (Task 3) and steepness (Task 2) BOTH bite hard, that's a signal the archetype amplitudes are too aggressive — consider lowering RELIEF on alpine/lone_peaks rather than fighting both gates. Stated decision, logged.
- NEVER silently loosen a gate; NEVER roll back terrain for a walkability fail (that's M2.7).
