# M2.4d — DEM-driven terrain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live macro terrain's CHARACTER come from the real DEMs (offline-distilled, never a `.tif` at runtime) blended with procedural composition, so it reads as believable terrain instead of a noise fest — while reusing the M2.4c GPU bridge verbatim.

**Architecture:** Three layers. (1) **Eval-surface foundation** — make the CURRENT macro judgeable: km-scale color ramp, structure-gated per-cell detail (gate by the macro's range/channel masks the shader already carries), and debug visual lanes. (2) **Offline DEM kernel library** — extend `dem_distill` to emit a compact per-archetype surface-kernel asset; a measured SPIKE resolves the kernel representation (the #1 risk). (3) **DEM-driven bake** — extend `MacroBake` so the macro = procedural composition structure × real-DEM surface character, archetype-routed; first cut mountain + grassland. The M2.4c bridge/cache/sampling are unchanged.

**Tech Stack:** Rust (`wg13` gdext crate: `macro_cache`, `field_compute`, `page_pool`; `dem_distill` offline tool; `structural_scaffold` window-port), GLSL compute (`field_height.glsl`) + spatial (`ring_displace.gdshader`), GDScript (`world_view.gd`), Godot 4.6.2 Vulkan. Spec: `docs/superpowers/specs/2026-06-07-m2-4d-dem-driven-terrain-design.md`.

**Hard invariant (00 §6):** the runtime NEVER opens a `.tif`. All DEM reading is offline in `dem_distill`; the runtime reads only the distilled binary asset.

---

## PLAN STRUCTURE — staged, spike-gated (read before executing)

This plan is in TWO PHASES because the DEM-bake task shape DEPENDS on a measurement that hasn't been made yet (the kernel representation — spec §5.1, risk #1). Writing concrete bake tasks now would be fiction.

- **PHASE A (Tasks 1–4): fully specified here.** The eval-surface foundation (knowable, independent of DEMs) + the offline kernel SPIKE (bounded exploration with a decision output). Phase A is executable end-to-end as written.
- **PHASE B (Tasks 5+): planned AFTER the spike (Task 4) resolves the kernel representation.** Task 4 ends by appending the Phase-B tasks to this file (DEM-driven `MacroBake` for mountain → +grassland/routing → tune). The shape is sketched in §"Phase B sketch" so the intent is locked, but the bite-sized tasks are written once the representation is known.

Each VISUAL gate PARKS for the human walk-test (the real success criterion — the agent does not self-certify the look). Each step ends green; commit at green. Editor CLOSED for wg13 builds; GPU gates need `--rendering-driver vulkan` (no headless); `$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"` for every cargo command. Commit messages via temp file + `git commit -F` (ASCII).

---

## File Structure

**Phase A:**
- **Modify** `wg-13/shaders/ring_displace.gdshader` — km-scale `height_lo`/`height_hi` ramp; a `view_mode` for the range/channel mask overlay (debug lane). Display-only.
- **Modify** `wg-13/shaders/field_height.glsl` — `macro_detail` becomes STRUCTURE-GATED: suppress on valley/channel floors, carry on ranges, using the macro's `range`/`channel` already sampled in `macro_sample` (mode 2 only; modes 0/1 untouched).
- **Modify** `wg-13/scripts/world_view.gd` — extend `VIEW_MODE_NAMES` with a "macro mask" lane; (ramp uniforms set where other per-page params bind).
- **Create** `rust/dem_distill/src/kernel.rs` — the offline surface-kernel extractor (detrend, normalize, tile-cut). Owns the kernel data type + extraction.
- **Modify** `rust/dem_distill/src/main.rs` — emit the kernel asset alongside `dem_fingerprints.json`.
- **Create** `rust/dem_distill/tests/kernel_spike.rs` — the measured spike (size, smoothness, non-repeat).

**Phase B (written after Task 4):**
- **Modify** `rust/gdext/src/macro_cache/` — load the kernel asset; `MacroBake` blends procedural structure × DEM surface; archetype routing.
- **Modify** `wg-13/data/` — the baked kernel asset (tracked or regenerated — Task 4 decides).

---

## Task 1: Km-scale color ramp (make the macro readable)

**Why first:** the normal-view ramp maps 60–360 m while macro terrain is kilometre-scale, so everything clamps to pale highland and shape is unreadable. We are relying on the human visual gate — fix the lens before judging anything. Display-only; zero effect on height/collision/gates.

**Files:**
- Modify: `wg-13/shaders/ring_displace.gdshader` (the `height_lo`/`height_hi` uniforms + their use in `fragment()`)
- Modify: `wg-13/scripts/world_view.gd` (where per-page shader params are bound — set the ramp to terrain-mode-appropriate values)

- [ ] **Step 1: Read the current ramp + where it's bound**

Read `ring_displace.gdshader` lines 56–57 (`height_lo=60.0`, `height_hi=360.0`) and the `fragment()` normal branch (~line 139–144: `t = clamp((v_height - height_lo)/(height_hi - height_lo), 0,1)`). Read `world_view.gd` `_make_page_instance` (grep `set_shader_parameter`) to find where `height_lo`/`height_hi`/`view_mode`/`cell_spacing` get set per page. Confirm the exact function + param names.

- [ ] **Step 2: Make the ramp terrain-mode-aware in world_view.gd**

The macro (mode 2) and oracle (mode 1) are km-scale (~0–2500 m); REFERENCE (mode 0) is ~0–1850 m. A single wide ramp reads all of them. Where the per-page params are bound (Step 1's function), set:
```gdscript
mat.set_shader_parameter("height_lo", 0.0)
mat.set_shader_parameter("height_hi", 2600.0)
```
(Replace the existing 60/360 binding if present; if the shader defaults are used and never set in GDScript, change the DEFAULTS in the shader instead — Step 3.) Keep it a single named pair so it's one tunable. If the ramp is currently NOT set in GDScript (uses shader defaults), do Step 3 only.

- [ ] **Step 3: Update the shader defaults to km-scale**

In `ring_displace.gdshader`:
```glsl
uniform float height_lo = 0.0;     // m — macro/oracle terrain is km-scale (was 60)
uniform float height_hi = 2600.0;  // m — full ramp green->tan over real relief (was 360)
```
(Comment why. The green→tan mix is unchanged; only the normalization range.)

- [ ] **Step 4: Build (none needed — shader/GDScript only) + relaunch + park**

No Rust change → no `cargo build`. Shader/GDScript reload on run. Launch for the human:
```
& "D:\world gen 13\run.ps1"
```
PARK: ask the human to press B to MACRO_CACHE and confirm the terrain is now READABLE (shape visible, not a pale wash) — purely "can we see it now," not "is it good." This unblocks judging Tasks 2+. (Agent does not self-certify; this is a visibility check the human confirms.)

- [ ] **Step 5: Commit**
```
$msg = @'
[M2.4d] km-scale color ramp so macro/oracle terrain is readable

The normal-view height ramp mapped 60-360m while macro terrain is km-scale,
so everything clamped to pale highland and shape was unreadable. Widen the
ramp to 0-2600m (display-only; height/collision/gates untouched). Foundation
for judging the DEM-driven work by eye.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\m24d_t1.txt" -Value $msg -Encoding ascii
git add wg-13/shaders/ring_displace.gdshader wg-13/scripts/world_view.gd
git commit -F "d:\tmp\m24d_t1.txt"
```

---

## Task 2: Structure-gated per-cell detail (kill the "busy everywhere" look)

**Why:** `macro_detail` adds ±70 m fBm UNIFORMLY — valley floors, slopes, peaks alike — which reads as "busy/melted." The macro already carries `range` (highland) and `channel` (drainage) masks, and `macro_sample` already reads them into `MacroCell`. Gate the detail by them: suppress roughness on valley/channel floors, carry more on ranges. Mode 2 only; modes 0/1 byte-identical.

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (`macro_detail` + the mode-2 branch in `main`)

- [ ] **Step 1: Read the current mode-2 branch + macro_detail**

Read `field_height.glsl` `macro_sample` (returns `MacroCell { height, range, channel, present }`), `macro_detail(world_xz, seed)` (~line 589, returns ±70 m), and the mode-2 branch (~line 605: `h = m.height + macro_detail(world_xz, uint(seed))`). Confirm `m.range`/`m.channel` are available at the call site (they are — `m` is the MacroCell).

- [ ] **Step 2: Make macro_detail structure-gated**

Change the mode-2 height assembly so detail amplitude follows structure. `range` ∈ [0,1] = highland mass; `channel` ∈ [0,1] = drainage/valley. Replace the mode-2 `if (m.present)` line:
```glsl
        if (m.present) {
            // M2.4d: gate detail by structure. Ridges carry roughness; valley/
            // channel floors stay smooth (uniform detail read as "busy/melted").
            // detail_gate in [~0.15, ~1.0]: high on range, suppressed on channel.
            float detail_gate = clamp(0.15 + 0.85 * m.range - 0.65 * m.channel, 0.0, 1.0);
            h = m.height + macro_detail(world_xz, uint(seed)) * detail_gate;
        } else {
            h = composition_height(world_xz, uint(seed));
        }
```
(The constants 0.15/0.85/0.65 are tunable look-levers — comment them as such. `macro_detail` itself is unchanged.)

- [ ] **Step 3: Verify mode 0/1 untouched + shader compiles**

The change is INSIDE the `terrain_mode == 2u` branch only. Run (editor closed for any rebuild — here GLSL-only, but the gate dispatches the shader):
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_3_composition_check.gd
& "...console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_macro_live_check.gd
```
Expected: `M2.3 RESULT: PASS` (mode-0 unchanged), `M2.4c macro live RESULT: PASS` (mode-2 still deterministic/finite/seam-bounded; the gate samples a fine interior so the gate value moves little — that's fine). No shader compile error.

- [ ] **Step 4: Relaunch + park**

`& "D:\world gen 13\run.ps1"`. PARK: human presses B to MACRO_CACHE, judges whether valleys now read as smooth corridors and ridges carry the roughness (less "busy everywhere"). Capture the verdict; tune the 0.15/0.85/0.65 levers if the human wants (re-run this task's steps). Do NOT self-certify.

- [ ] **Step 5: Commit**
```
$msg = @'
[M2.4d] structure-gated per-cell detail (mode 2)

macro_detail was painted uniformly (valleys, slopes, peaks) -> "busy/melted".
Gate it by the macro's range/channel masks (already in MacroCell): ridges
carry roughness, valley/channel floors stay smooth. detail_gate =
clamp(0.15 + 0.85*range - 0.65*channel, 0, 1). Mode 2 only; modes 0/1
byte-identical (change is inside the terrain_mode==2 branch). Levers tunable.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\m24d_t2.txt" -Value $msg -Encoding ascii
git add wg-13/shaders/field_height.glsl
git commit -F "d:\tmp\m24d_t2.txt"
```

---

## Task 3: Debug visual lane — macro mask overlay

**Why:** to tune the DEM work we need to SEE the layers in isolation (per the review's "lanes" recommendation). Add a view mode that paints the macro's range/channel masks as color so structure is visible independent of height/detail. Debug-only, default off.

**Files:**
- Modify: `wg-13/shaders/ring_displace.gdshader` (a new `view_mode` branch reading a per-page mask texture)
- Modify: `wg-13/scripts/world_view.gd` (`VIEW_MODE_NAMES` + bind the mask texture per page)
- Modify: `rust/gdext/src/page_pool.rs` (expose the macro range/channel as a per-page texture, like the biome texture)

**Context:** This needs the macro masks reaching the display shader. `page_pool` already packs height/climate/biome textures per `ResidentPage`. Add a macro-mask texture (range in R, channel in G) the same way. NOTE: this only has data in mode 2 (the macro path); in modes 0/1 the masks are 0 → the lane shows flat (acceptable; it's a mode-2 debug aid).

- [ ] **Step 1: Read the per-page texture packing pattern**

Read `page_pool.rs` `produce()` + `ResidentPage` (grep `biome_tex`, `rg32f_texture`, `r32f_texture`): see how `temp`/`moisture` pack into one RG32F and `biome` into R32F. The `FieldPage` from `dispatch_page` carries `heights/temp/moisture/biome` — confirm whether range/channel are returned. **They are NOT** (the shader writes only [h,t,m,biome]). So this task FIRST needs the field shader to OUTPUT range/channel for mode 2.

DECISION for the implementer: the cleanest minimal path is — in `field_height.glsl` mode 2, write the macro `m.range`/`m.channel` into a spare output (the page is [h,t,m,biome]; there's no spare channel). Rather than grow the page to 6 channels (touches the M1.7 contract + all gates), make this lane a SEPARATE small debug dispatch OR derive the masks in the display shader from height slope. SIMPLEST that respects scope: derive a proxy in the display shader (steep = range-like, flat-low = channel-like) for the debug lane only. If that proxy is too weak to be useful, escalate to a real macro-mask texture as its own task. Implementer: try the slope-proxy first (no Rust/page-format change); only grow the page if the human needs true masks.

- [ ] **Step 2: Add the mask-overlay view mode (slope-proxy first)**

In `ring_displace.gdshader`, add `view_mode == 4` (after biome=3):
```glsl
    } else if (view_mode == 4) {
        // M2.4d debug: macro structure proxy from local slope. Steep -> range
        // (red), flat -> channel/floor (blue), mid -> grey. Mode-2 tuning aid.
        float slope = length(vec2(
            sample_h(UV + vec2(0.004, 0.0)) - sample_h(UV - vec2(0.004, 0.0)),
            sample_h(UV + vec2(0.0, 0.004)) - sample_h(UV - vec2(0.0, 0.004))));
        float s = clamp(slope * 0.02, 0.0, 1.0);
        ALBEDO = mix(vec3(0.15, 0.35, 0.85), vec3(0.85, 0.25, 0.20), s) * page_tint;
        ROUGHNESS = 0.95;
    }
```
In `world_view.gd`, add `"MACRO MASK"` to `VIEW_MODE_NAMES`.

- [ ] **Step 3: Verify + park**

GLSL/GDScript only; run `m2_4c_macro_live_check` (dispatches the shader → catches compile errors): `RESULT: PASS`. Launch; human presses V to reach "MACRO MASK" in MACRO_CACHE mode and confirms structure (ridges vs valleys) is visible. Tuning aid — not a quality gate.

- [ ] **Step 4: Commit**
```
$msg = @'
[M2.4d] debug visual lane: macro structure proxy (view_mode 4)

V cycles to a MACRO MASK lane painting a slope-derived structure proxy
(steep=range/red, flat=channel/blue) so the macro's structure is visible
independent of height/detail while tuning. Slope-proxy (no page-format
change); escalate to a real macro-mask texture only if proxy is too weak.
Debug-only, default off.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\m24d_t3.txt" -Value $msg -Encoding ascii
git add wg-13/shaders/ring_displace.gdshader wg-13/scripts/world_view.gd
git commit -F "d:\tmp\m24d_t3.txt"
```

---

## Task 4: Offline DEM kernel SPIKE — resolve the kernel representation (#1 RISK)

**Why this is a spike:** the spec's central risk is "blend finite real DEM patches into an infinite, non-repeating, seamless world." The kernel REPRESENTATION (raw detrended patch atlas vs. an exemplar/spectral form) determines feasibility, asset size, and the whole Phase-B bake design. We resolve it by MEASUREMENT on the real data before committing — not by assuming. This task's deliverable is a DECISION (with numbers), the extractor that implements it, and the Phase-B tasks appended to this plan.

**Files:**
- Create: `rust/dem_distill/src/kernel.rs` (the kernel data type + extraction: detrend, normalize, tile-cut)
- Modify: `rust/dem_distill/src/main.rs` (emit the kernel asset)
- Create: `rust/dem_distill/tests/kernel_spike.rs` (the measured assertions)

**Context:** `dem_distill` already reads `.tif` → f32 (`read_tif_f32` in main.rs), groups by archetype (`archetype::archetype_of`), and emits per-archetype `Fingerprint`s. EXTEND it. The DEMs are at `archive/from_workflows_worldgen9/dems/opentopo/` (gitignored, on disk). Start with the **mountain** and **grassland** archetypes only (the first-cut pair).

- [ ] **Step 1: Define the kernel data type + extraction (kernel.rs)**

Create `rust/dem_distill/src/kernel.rs`. A surface kernel = a real DEM patch with the continental trend removed (so it carries TEXTURE: ridges, drainage, fluting — not absolute elevation), normalized to [0,1], at a fixed patch size (e.g. 256×256 samples). Detrend = subtract a low-pass (large-sigma blur) of the patch. Write the type + a `extract_kernels(heights, w, ht, patch, stride) -> Vec<Kernel>` that tiles the source DEM into patches, detrends + normalizes each, and rejects degenerate (flat/nodata) patches. Reuse `analyze`'s spacing/blur helpers where possible.
```rust
//! M2.4d: offline DEM surface-kernel extraction. A "kernel" is a real DEM patch
//! with the continental trend removed + normalized -> the SURFACE CHARACTER
//! (ridges/drainage/fluting) the runtime macro blends in. OFFLINE ONLY (no .tif
//! at runtime; the runtime reads only the distilled asset this emits).
pub struct Kernel {
    pub archetype: String,
    pub size: usize,            // side length (samples)
    pub data: Vec<f32>,         // detrended+normalized [0,1], row-major
}
// extract_kernels: tile the DEM into `patch`-sized cells (stride apart), detrend
// (subtract a large-sigma blur), normalize each to [0,1], drop flat/nodata patches.
```
(Exact detrend sigma + patch size + reject threshold are the spike's to TUNE by the Step-3 measurements — pick sensible starts, e.g. patch 256, stride 128, detrend sigma = patch/4.)

- [ ] **Step 2: Write the spike test (measured assertions) — RED**

Create `rust/dem_distill/tests/kernel_spike.rs`. This is the spike's DECISION instrument: it bakes kernels from the mountain + grassland DEMs and MEASURES (a) asset size per archetype, (b) that detrended kernels are SMOOTH-base-free (no continental ramp — mean-centered), (c) that two different kernels from the same archetype are statistically similar but not identical (diversity for non-repeat). If the DEM dir is absent (CI), the test SKIPS with a clear message (not a failure) — it's a real-data spike.
```rust
// Measures: kernels extract, are detrended ([0,1], no continental trend),
// diverse (so blending won't visibly repeat), and the asset is small enough to
// ship. Prints the numbers (the spike's evidence). SKIPS if the DEM dir absent.
```
Run: `cargo test -p dem_distill kernel_spike -- --nocapture` → FAIL (extractor not wired) or SKIP (no DEMs). Get it to the point where, WITH DEMs present, it RUNS and prints measurements.

- [ ] **Step 3: Run the spike, record the MEASUREMENTS, make the DECISION**

Run the extractor over mountain + grassland (via the test or a `main.rs` subcommand). Record, in a comment block at the top of `kernel.rs` AND in the commit message:
- kernels/archetype, patch size, **total asset bytes** for the 2 archetypes (extrapolate to 12).
- detrend quality (does a kernel still carry ridge/drainage texture after detrend? eyeball one via a printed ASCII histogram or min/max/mean).
- diversity (correlation between two same-archetype kernels — want <~0.9 so blends vary).
DECISION (write it down): **raw patch atlas** (ship the patches) vs **exemplar/spectral** (ship a synthesis seed) — based on the size + diversity numbers. If raw atlas is small enough (<~a few MB for 12 archetypes) and diverse, choose it (simplest, most faithful). If too big or too repetitive, choose the lighter form. This decision drives Phase B.

- [ ] **Step 4: Emit the kernel asset (main.rs)**

Wire `main.rs` to write the chosen kernel asset (e.g. `wg-13/data/dem_kernels.bin` + a small JSON index) alongside `dem_fingerprints.json`. Binary, compact, NOT a `.tif`. Decide tracked-vs-regenerated by the size from Step 3 (note it in the index header). Run the tool over the real DEMs; confirm the asset writes + the spike test passes WITH the asset.

- [ ] **Step 5: Append the Phase-B tasks to THIS plan**

Now that the representation is known, write the concrete bite-sized Phase-B tasks (mountain bake → +grassland/routing → tune) into this file under "## Phase B" using the resolved kernel type. (This is the planning hand-off the staged structure requires — Phase B was deliberately not fiction-written before the spike.) Then commit Task 4 + the appended plan together.

- [ ] **Step 6: Commit**
```
$msg = @'
[M2.4d] DEM kernel spike: representation resolved by measurement

Extend dem_distill with offline surface-kernel extraction (detrend + normalize
real DEM patches into [0,1] texture kernels). Measured on mountain + grassland:
<N kernels/archetype, <SIZE> asset bytes, diversity <CORR>>. DECISION:
<raw-atlas | exemplar>, <tracked | regenerated>. Emits wg-13/data/dem_kernels.*
(binary, never a .tif at runtime, section 6). Phase-B bake tasks appended to the plan.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\m24d_t4.txt" -Value $msg -Encoding ascii
git add rust/dem_distill/src/kernel.rs rust/dem_distill/src/main.rs rust/dem_distill/tests/kernel_spike.rs docs/superpowers/plans/2026-06-07-m2-4d-dem-driven-terrain.md
git commit -F "d:\tmp\m24d_t4.txt"
```

---

## Phase B sketch (locked intent; bite-sized tasks written by Task 4 Step 5)

After the spike resolves the kernel representation, Phase B builds the DEM-driven bake. Intended tasks (shape locked by the spec; exact code written post-spike against the resolved kernel type):

- **Task 5 — Load the kernel asset into the runtime + a `MacroBake` blend hook.** `macro_cache` loads `dem_kernels.*` once (read the binary asset — NOT a `.tif`); add a `kernel_surface(world_xz, archetype, seed)` that samples/blends the kernels (domain-warped, multi-patch-mixed) for a region. Unit-test: deterministic, finite, [0,1]-ish, non-repeating across a wide scan.
- **Task 6 — DEM-driven `MacroBake` for MOUNTAIN.** Replace the single-alpine height assembly: structure from the composition machine (calibrated by the mountain fingerprint — slope_p95/ridge/spectrum), surface character from `kernel_surface`. Keep `base + carves`, drop the jagged procedural detail bands (the kernels replace them). Gate: determinism, seam <1 m, real relief, mode 0/1 bit-identical. PARK: human walk-test mountains.
- **Task 7 — Add GRASSLAND + archetype routing/transition.** Route archetype from the biome/climate field (mountain where high+steep, grassland where low+moderate); blend two banks across the transition. Gate + PARK: human walk-test the contrast + transition (the seamless-blend proof).
- **Task 8 — Tune to AAA-ish by eye.** Iterate kernel-mix amplitude, structure calibration, detail gating using the visual lanes. PARK: human final visual gate → if it passes, M2.4d closes; update PROGRESS/DRIFT_LOG/HANDOFF.

Risks carried into Phase B (from the spec §9): seamless non-repeating blend (the spike de-risks the representation; Task 5 proves the blend), archetype-boundary seams (Task 7), over-smooth-vs-noise balance (Task 8 by eye). The async-BakeScheduler carry-forwards (HANDOFF §3) are a SEPARATE later step, not M2.4d.

---

## Self-Review

**1. Spec coverage:**
- §5.3 eval-surface (km ramp, structure-gated detail, visual lanes) → Tasks 1, 2, 3. ✓
- §5.1 offline kernel library (extend dem_distill, no .tif at runtime) → Task 4. ✓
- §5.1 kernel-representation risk resolved by measurement → Task 4 is an explicit measured spike. ✓
- §5.2 DEM-driven bake (structure × surface, archetype-routed, reuse bridge) → Phase B (Tasks 6–7), written post-spike. ✓ (intent locked in the sketch)
- §2 first cut mountain + grassland → Task 4 (spike on both), Tasks 6–7. ✓
- §8 verification (mode 0/1 bit-identical, seam, human visual gate primary) → every task's gate/park. ✓
- §3 no .tif at runtime → Task 4 (offline only) + Task 5 (reads the binary asset). ✓

**2. Placeholder scan:** Phase A (Tasks 1–4) is fully concrete (code shown, commands + expected output, commits). Phase B is DELIBERATELY a sketch, not placeholder fiction — its bite-sized tasks are written by Task 4 Step 5 once the spike resolves the representation (writing them now would be guessing the kernel type). This staging is stated up front and is the honest structure for a spike-gated plan. Task 1 Step 2/3 has a real branch (ramp set in GDScript vs shader default) the implementer resolves by reading — concrete, not vague. Task 3 Step 1 gives the implementer a real decision (slope-proxy first, escalate only if needed) with the rule — not a TODO.

**3. Type/name consistency:** `MacroCell{height,range,channel,present}` (existing), `macro_detail`, `detail_gate`, `view_mode` 4 = MACRO MASK, `Kernel{archetype,size,data}`, `extract_kernels`, `kernel_surface` (Phase B) — consistent across tasks. `height_lo`/`height_hi` match the shader. Gate names (`m2_3_composition_check`, `m2_4c_macro_live_check`) match the repo.

**Executor notes:**
- Phase A is independent of the DEMs (Tasks 1–3) except Task 4 (needs the on-disk DEM dir; the spike SKIPS cleanly if absent, but the DECISION needs real data — run it where the DEMs are).
- Every VISUAL step PARKS for the human; the agent never self-certifies the look (the project's signature trap).
- Mode 0/1 bit-identical is the regression bar on every shader change (Tasks 2, 3 touch only mode-2 / display).
- Editor CLOSED for wg13 builds; `--rendering-driver vulkan` for GPU gates; `$env:CARGO_TARGET_DIR` set every cargo command.
