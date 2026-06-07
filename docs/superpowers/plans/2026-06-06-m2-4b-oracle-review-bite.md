# M2.4b Oracle Review Bite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the GPU-portable per-cell oracle (`sample_cell`) as a reviewable static sheet AND a flyable 3D scene at playable scale, so the human can visually review — for the first time — the only scaffold path that can actually run in the live per-cell GPU field.

**Architecture:** The scaffold crate already has two generators: the window-port (`generate_fact_map_style`, neighbor-based, already reviewed) and the per-cell oracle (`sample_cell`, stateless, never rendered). This plan adds an **oracle data source** to the existing review tooling — a new `--source oracle|window` flag on the `review` and `export-godot` CLI commands — reusing the exact PNG/JSON writers and the existing `scaffold_3d_review.gd` Godot scene. No new render code, no touching the live field. A new oracle-at-playable-scale Godot scene + a smoke gate make the oracle reviewable and regression-safe.

**Tech Stack:** Rust (std-only, no deps — crate `structural_scaffold`), Godot 4.6.2-mono (GDScript review scene), Vulkan rendering driver (GPU gates can't run headless).

**Why this is the whole bite:** The spec (`docs/superpowers/specs/2026-06-06-m2-4b-oracle-validation-and-integration-design.md`) gates the expensive GLSL integration behind a cheap visual review of the oracle. This plan produces ONLY that review artifact. Integration is a separate, later plan written after the human takes a decision-gate branch.

**Procedural invariant (must hold throughout):** every oracle value is a pure function of `(seed, world_x, world_z)` — no file I/O, no stored tiles, no precompute. `sample_cell` already satisfies this; do not break it.

---

## File Structure

- **Modify** `rust/structural_scaffold/src/main.rs` — add a `--source oracle|window` flag to `review` and `export-godot`; route the per-cell map build through `sample_cell` when `oracle`. Add a shared `oracle_fact_map(...)` helper that mirrors `generate_fact_map_style`'s output shape but per-cell.
- **No change** to `rust/structural_scaffold/src/lib.rs` — `sample_cell` is already public and GPU-portable; we only call it. (If a tiny pub helper is genuinely needed, add it here, but prefer not to.)
- **Create** `wg-13/scenes/m2_4b_scaffold_oracle_playable_review.tscn` — same `scaffold_3d_review.gd` script, pointed at the oracle JSON, at playable-scale params.
- **Modify** `wg-13/tests/m2_4b_scaffold_3d_check.gd` — add the oracle scene to the smoke gate.
- **Modify** `rust/structural_scaffold/src/lib.rs` tests OR add to `main.rs` — a unit test proving the oracle map is deterministic and bounded (guards the procedural invariant for the new path).
- **Docs (live, per working method):** update `docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md`, `PROGRESS.md`, `HANDOFF.md`, `DRIFT_LOG.md` at the green gate.

---

## Task 1: Oracle fact-map helper (per-cell, deterministic)

**Files:**
- Modify: `rust/structural_scaffold/src/lib.rs` (add `oracle_fact_map` next to `generate_fact_map_style`)
- Test: `rust/structural_scaffold/src/lib.rs` (`#[cfg(test)] mod tests`)

**Context:** `generate_fact_map_style(seed, resolution, origin_x, origin_z, span_m, style)` returns `Vec<FactCell>` from the WINDOW path. We need the identical signature/shape from the PER-CELL path so the existing PNG/JSON/scene code consumes it unchanged. `sample_cell(seed, world_x, world_z) -> FactCell` already exists and is per-cell. The grid mapping mirrors `generate_fact_map_style`: `spacing = span_m / (resolution-1)`, `world = origin + cell*spacing`.

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `rust/structural_scaffold/src/lib.rs`:

```rust
    #[test]
    fn oracle_fact_map_is_deterministic_and_bounded() {
        let a = oracle_fact_map(177, 33, 0.0, 0.0, 64_000.0);
        let b = oracle_fact_map(177, 33, 0.0, 0.0, 64_000.0);
        assert_eq!(a.len(), 33 * 33);
        assert_eq!(a, b, "same seed/resolution/origin/span must be bit-identical");
        for cell in &a {
            assert!((0.0..=1.0).contains(&cell.range_mask));
            assert!((0.0..=1.0).contains(&cell.channel_mask));
            assert!(cell.preview_height_m.is_finite());
        }
    }

    #[test]
    fn oracle_fact_map_matches_sample_cell_at_grid_points() {
        let res = 17usize;
        let span = 64_000.0f32;
        let map = oracle_fact_map(177, res, 1000.0, -2000.0, span);
        let spacing = span / (res as f32 - 1.0);
        // spot-check a few grid points equal a direct sample_cell call
        for &(x, z) in &[(0usize, 0usize), (5, 11), (16, 16)] {
            let wx = 1000.0 + x as f32 * spacing;
            let wz = -2000.0 + z as f32 * spacing;
            let direct = sample_cell(177, wx, wz);
            assert_eq!(map[z * res + x], direct);
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cargo test --manifest-path rust\Cargo.toml -p structural_scaffold oracle_fact_map`
Expected: FAIL — `cannot find function 'oracle_fact_map' in this scope`.

- [ ] **Step 3: Write the minimal implementation**

Add to `rust/structural_scaffold/src/lib.rs` (public, near `generate_fact_map_style`):

```rust
/// Per-cell oracle fact map. Same output shape as `generate_fact_map_style`, but
/// every cell is a pure `sample_cell(seed, world_x, world_z)` call — no neighbor
/// access, no apron, no blur. This is the GPU-portable path (mirrors what would run
/// in `field_height.glsl`). Procedural invariant: pure fn of (seed, world coords).
pub fn oracle_fact_map(
    seed: u64,
    resolution: usize,
    origin_x: f32,
    origin_z: f32,
    span_m: f32,
) -> Vec<FactCell> {
    assert!(resolution >= 3, "resolution must be at least 3");
    assert!(
        span_m.is_finite() && span_m > 0.0,
        "span_m must be positive"
    );
    let spacing = span_m / (resolution as f32 - 1.0);
    let mut cells = Vec::with_capacity(resolution * resolution);
    for z in 0..resolution {
        for x in 0..resolution {
            let wx = origin_x + x as f32 * spacing;
            let wz = origin_z + z as f32 * spacing;
            cells.push(sample_cell(seed, wx, wz));
        }
    }
    cells
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cargo test --manifest-path rust\Cargo.toml -p structural_scaffold oracle_fact_map`
Expected: PASS (2 tests). Also run the whole crate to confirm no regression:
`cargo test --manifest-path rust\Cargo.toml -p structural_scaffold`
Expected: all PASS (the original 4 + 2 new).

- [ ] **Step 5: Commit**

```bash
git add rust/structural_scaffold/src/lib.rs
git commit -F - <<'EOF'
[M2.4b] add per-cell oracle_fact_map helper

Same output shape as generate_fact_map_style but every cell is a pure
sample_cell(seed, world_x, world_z) call (the GPU-portable path). Tests:
deterministic + bounded, and grid points equal direct sample_cell.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: `--source oracle|window` flag on the CLI

**Files:**
- Modify: `rust/structural_scaffold/src/main.rs` (`run_review`, `run_export_godot`, and the map-building call sites + a small source enum/parse)

**Context:** `main.rs` currently always calls `generate_fact_map_style(...)`. We add a source selector defaulting to `window` (preserves current behavior bit-for-bit) and switching to `oracle_fact_map(...)` when requested. The `review` command builds maps in `render_review` at `map_px` resolution; `export-godot` builds in `run_export_godot` at `resolution`. Both must honor the flag. `arg_value` already exists for flag parsing.

- [ ] **Step 1: Add a source parser + import**

In `rust/structural_scaffold/src/main.rs`, extend the `use` line and add a parser. Change:

```rust
use structural_scaffold::{
    channel_connectivity, generate_fact_map_style, generate_region, max_east_west_border_delta,
    max_south_north_border_delta, RegionConfig, StyleId,
};
```

to also import `oracle_fact_map`:

```rust
use structural_scaffold::{
    channel_connectivity, generate_fact_map_style, generate_region, max_east_west_border_delta,
    max_south_north_border_delta, oracle_fact_map, RegionConfig, StyleId,
};
```

Add near the other parse helpers:

```rust
#[derive(Clone, Copy, PartialEq)]
enum FactSource {
    Window,
    Oracle,
}

fn parse_source(args: &[String]) -> Result<FactSource, String> {
    match arg_value(args, "--source") {
        None | Some("window") => Ok(FactSource::Window),
        Some("oracle") => Ok(FactSource::Oracle),
        Some(other) => Err(format!("--source expects 'window' or 'oracle', got '{other}'")),
    }
}

fn build_fact_map(
    source: FactSource,
    seed: u64,
    resolution: usize,
    origin_x: f32,
    origin_z: f32,
    span_m: f32,
    style: StyleId,
) -> Vec<structural_scaffold::FactCell> {
    match source {
        FactSource::Window => {
            generate_fact_map_style(seed, resolution, origin_x, origin_z, span_m, style)
        }
        FactSource::Oracle => oracle_fact_map(seed, resolution, origin_x, origin_z, span_m),
    }
}
```

(Note: the oracle path ignores `style` — `sample_cell` derives style internally per-cell from world position. That is intentional and matches how it would behave live.)

- [ ] **Step 2: Route `export-godot` through the flag**

In `run_export_godot`, after parsing `span_m` and before building `maps`, add:

```rust
    let source = parse_source(args)?;
```

Then change the `maps` builder from:

```rust
    let maps = styles
        .iter()
        .map(|&style| generate_fact_map_style(seed, resolution, 0.0, 0.0, span_m, style))
        .collect::<Vec<_>>();
```

to:

```rust
    let maps = styles
        .iter()
        .map(|&style| build_fact_map(source, seed, resolution, 0.0, 0.0, span_m, style))
        .collect::<Vec<_>>();
```

- [ ] **Step 3: Route `review` through the flag**

In `run_review`, after parsing existing args add `let source = parse_source(args)?;`, then pass it into `render_review`. Change the signature:

```rust
fn render_review(seed: u64, radius: i32, tile_px: usize) -> Result<ReviewImage, String> {
```

to:

```rust
fn render_review(seed: u64, radius: i32, tile_px: usize, source: FactSource) -> Result<ReviewImage, String> {
```

Update the call in `run_review`:

```rust
    let review = render_review(seed, radius, tile_px, source)?;
```

And inside `render_review`, change the `style_maps` builder from:

```rust
    let style_maps = styles
        .iter()
        .map(|&style| {
            generate_fact_map_style(seed, map_px, world_min, world_min, world_span, style)
        })
        .collect::<Vec<_>>();
```

to:

```rust
    let style_maps = styles
        .iter()
        .map(|&style| build_fact_map(source, seed, map_px, world_min, world_min, world_span, style))
        .collect::<Vec<_>>();
```

- [ ] **Step 4: Update usage text**

In `print_usage`, change the two command lines to mention the flag:

```rust
fn print_usage() {
    println!(
        "usage:\n  cargo run -p structural_scaffold -- review [--seed N] [--radius N] [--tile-px N] [--source window|oracle] [--out PATH] [--report PATH]\n  cargo run -p structural_scaffold -- export-godot [--seed N] [--resolution N] [--span-m M] [--source window|oracle] [--out PATH]"
    );
}
```

- [ ] **Step 5: Verify it builds and the window path is unchanged**

Run: `cargo build --manifest-path rust\Cargo.toml -p structural_scaffold`
Expected: compiles clean (warnings ok).

Prove the default (window) output is byte-identical to before by regenerating into a temp path and diffing against the committed one:

Run:
```
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot --out d:\tmp\win_default.json
```
Then compare `d:\tmp\win_default.json` to the existing `wg-13\_captures\m2_4b_scaffold_3d.json` (they should match — same seed/resolution/span defaults, window source). Use Read on both, or:
`fc d:\tmp\win_default.json "wg-13\_captures\m2_4b_scaffold_3d.json"` (Windows `fc`; expect "no differences").
Expected: identical — confirms the flag did not change the default path.

- [ ] **Step 6: Commit**

```bash
git add rust/structural_scaffold/src/main.rs
git commit -F - <<'EOF'
[M2.4b] add --source window|oracle flag to scaffold CLI

review and export-godot now accept --source (default window, unchanged).
oracle routes the per-cell oracle_fact_map; window keeps the WG10 port.
Default output verified byte-identical to the prior window path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: Export the oracle JSON + 2D review sheet

**Files:**
- Generated artifacts only: `wg-13/_captures/m2_4b_scaffold_oracle_3d.json`, `wg-13/_captures/m2_4b_scaffold_oracle_review.png`, `..._oracle_review.md`

**Context:** These are review artifacts. `_captures/` is gitignored (per project facts), so they are NOT committed — they are produced on demand for the human to look at. This task just proves the oracle data source produces valid, non-degenerate output.

- [ ] **Step 1: Export the oracle 3D JSON at playable scale**

Run:
```
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot --source oracle --span-m 64000 --resolution 193 --out wg-13\_captures\m2_4b_scaffold_oracle_3d.json
```
Expected: prints `Wrote wg-13/_captures/m2_4b_scaffold_oracle_3d.json`.

- [ ] **Step 2: Sanity-check the JSON is non-degenerate**

Read the head of `wg-13/_captures/m2_4b_scaffold_oracle_3d.json`. Confirm:
- `"version": "m2_4b_scaffold_3d/v1"`, `"resolution": 193`, `"span_m": 64000.000`
- four `styles` entries (the export always writes 4 style panels; oracle ignores the style arg, so all four panels are the SAME oracle field — that is expected and fine for a single-panel playable review which reads panel 0)
- `height_min` != `height_max` (the field has relief, not flat)
Expected: all true. If `height_min == height_max`, STOP — the oracle produced a flat field; that is a real finding to report, not something to paper over.

- [ ] **Step 3: Render the oracle 2D review sheet (optional cross-check)**

Run:
```
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- review --source oracle --out wg-13\_captures\m2_4b_scaffold_oracle_review.png --report wg-13\_captures\m2_4b_scaffold_oracle_review.md
```
Expected: prints two `Wrote ...` lines. The `.md` report's "max channel response" and "mean channel density" give a cheap read on whether the oracle's drainage signal exists at all.

- [ ] **Step 4: No commit (artifacts are gitignored)**

Confirm with `git status --short` that no `_captures/` files appear staged/untracked-pending (they are ignored). Nothing to commit in this task.

---

## Task 4: Oracle playable-scale 3D review scene

**Files:**
- Create: `wg-13/scenes/m2_4b_scaffold_oracle_playable_review.tscn`

**Context:** Reuse `scripts/scaffold_3d_review.gd` unchanged. Point `data_path` at the oracle JSON and copy the playable-scale params from `m2_4b_scaffold_playable_scale_review.tscn` (`display_span_m=64000`, `height_scale=0.45`, single panel, fast fly). This gives a flyable oracle view at gameplay scale — the first time the oracle is seen in 3D.

- [ ] **Step 1: Create the scene file**

Create `wg-13/scenes/m2_4b_scaffold_oracle_playable_review.tscn` with:

```
[gd_scene load_steps=2 format=3 uid="uid://m24boracleplay"]

[ext_resource type="Script" path="res://scripts/scaffold_3d_review.gd" id="1_scaffold"]

[node name="M2_4b_ScaffoldOraclePlayableReview" type="Node3D"]
script = ExtResource("1_scaffold")
data_path = "res://_captures/m2_4b_scaffold_oracle_3d.json"
display_span_m = 64000.0
height_scale = 0.45
panel_gap_m = 0.0
style_count = 1
show_labels = false
fly_speed = 2200.0
camera_height_m = 1900.0
camera_target_height_m = 650.0
camera_distance_factor = 0.42
```

- [ ] **Step 2: Verify the scene loads + builds a non-blank mesh (smoke, manual)**

Ensure the oracle JSON from Task 3 exists. Run the existing review gate WON'T cover the new scene yet (that is Task 5), so do a one-off load check:

Run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path wg-13 --headless=false --quit-after 30 res://scenes/m2_4b_scaffold_oracle_playable_review.tscn
```
(If `--quit-after` is unavailable in this Godot build, just launch and close the window manually.)
Expected: a window shows shaded terrain (NOT sky-only). Note: GPU scenes cannot run `--headless` — use `--rendering-driver vulkan` (project gotcha). The editor must be closed if a Rust rebuild is pending (DLL lock) — not relevant here since no rebuild.

- [ ] **Step 3: Commit the scene**

```bash
git add wg-13/scenes/m2_4b_scaffold_oracle_playable_review.tscn
git commit -F - <<'EOF'
[M2.4b] add oracle playable-scale 3D review scene

Reuses scaffold_3d_review.gd pointed at the oracle JSON at playable scale
(64km span, 0.45 height). First flyable view of the GPU-portable per-cell
oracle. Review artifact only; not runtime-integrated.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 5: Add the oracle scene to the smoke gate

**Files:**
- Modify: `wg-13/tests/m2_4b_scaffold_3d_check.gd`

**Context:** The gate currently checks the macro (4 panels) and playable (1 panel) WINDOW scenes. Add the oracle scene (1 panel) so a future change that breaks the oracle render is caught. The gate asserts panel count, min vertices, and non-blank viewport. At resolution 193, one panel = 193*193 = 37249 vertices, same as the window playable scene, so reuse `min_vertices = 30000`.

**Precondition:** the oracle JSON (`wg-13/_captures/m2_4b_scaffold_oracle_3d.json`) must exist when the gate runs (Task 3 Step 1 produces it). Because `_captures/` is gitignored, the gate's run recipe must regenerate it first — document that in the gate header comment.

- [ ] **Step 1: Update the gate header recipe comment**

In `wg-13/tests/m2_4b_scaffold_3d_check.gd`, replace the header comment block (lines ~2-5) with:

```
# M2.4b static 3D review smoke gate.
# Run after exporting BOTH JSONs (window + oracle):
#   cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot
#   cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot --source oracle --span-m 64000 --resolution 193 --out wg-13\_captures\m2_4b_scaffold_oracle_3d.json
#   godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_scaffold_3d_check.gd
```

- [ ] **Step 2: Add the oracle scene constant**

After the `PLAYABLE_SCALE_SCENE` const, add:

```gdscript
const ORACLE_PLAYABLE_SCENE := "res://scenes/m2_4b_scaffold_oracle_playable_review.tscn"
```

- [ ] **Step 3: Check the oracle scene in `_run`**

Change `_run` from:

```gdscript
func _run() -> void:
	await _check_scene(MACRO_SCENE, 4, 100000)
	await _check_scene(PLAYABLE_SCALE_SCENE, 1, 30000)
	_finish()
```

to:

```gdscript
func _run() -> void:
	await _check_scene(MACRO_SCENE, 4, 100000)
	await _check_scene(PLAYABLE_SCALE_SCENE, 1, 30000)
	await _check_scene(ORACLE_PLAYABLE_SCENE, 1, 30000)
	_finish()
```

- [ ] **Step 4: Run the gate green**

Regenerate both JSONs, then run the gate:
```
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot --source oracle --span-m 64000 --resolution 193 --out wg-13\_captures\m2_4b_scaffold_oracle_3d.json
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_scaffold_3d_check.gd
```
Expected stdout includes:
```
PASS: res://scenes/m2_4b_scaffold_3d_review.tscn built 4 panels / 148996 vertices
PASS: res://scenes/m2_4b_scaffold_playable_scale_review.tscn built 1 panels / 37249 vertices
PASS: res://scenes/m2_4b_scaffold_oracle_playable_review.tscn built 1 panels / 37249 vertices
M2.4b scaffold 3D RESULT: PASS
```
Exit code 0.

- [ ] **Step 5: Commit**

```bash
git add wg-13/tests/m2_4b_scaffold_3d_check.gd
git commit -F - <<'EOF'
[M2.4b] cover oracle review scene in 3D smoke gate

Gate now checks the oracle playable scene (1 panel / 37249 verts /
non-blank) alongside the window macro + playable scenes. Header recipe
documents regenerating the oracle JSON (gitignored) before running.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 6: Human visual review + decision-gate branch (PARK)

**Files:**
- Modify (at the gate): `docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md`, `plans and docs/plans/PROGRESS.md`, `plans and docs/plans/HANDOFF.md`, `plans and docs/plans/DRIFT_LOG.md`

**Context:** This is a VISUAL gate — the agent cannot self-certify it (working method §2: unsupervised work crosses TEST gates only; a visual gate PARKS for the human). The point of the whole bite is the human seeing the oracle for the first time.

- [ ] **Step 1: Launch the oracle scene for the human**

Launch the oracle playable scene via the normal launch path (`run.ps1` if it supports a scene arg, else the Godot console exe with the scene path, windowed — NOT `--headless`, GPU). Also launch the window playable scene (`m2_4b_scaffold_playable_scale_review.tscn`) so the human can compare oracle vs the previously-liked window-port side by side, at the same scale.

- [ ] **Step 2: Capture the human's verdict against the decision gate**

Present the three pre-decided branches from the spec and record which one the human picks:
1. **Reads well** -> proceed to write the integration plan (separate plan, GLSL port + candidate lane).
2. **Close but off** -> tune `synthesize_cell` in fast Rust loops (dev opt-level=1), re-export, re-review (loop this task).
3. **Cannot capture the window-port's quality** -> STOP; escalate to the window-based GPU pipeline (Approach C) as its own milestone.

- [ ] **Step 3: Log the outcome in DRIFT_LOG.md (append-only) + update PROGRESS/HANDOFF**

Append a DRIFT_LOG entry: TYPE = VISUAL REVIEW; what was reviewed (oracle vs window at playable scale); the human verdict; which branch was taken; next step. Update `PROGRESS.md` M2.4 line and `HANDOFF.md` §3 current-state to reflect the branch taken. Update the M2.4b plan doc's "Immediate Next Implementation Bite" to the chosen branch.

- [ ] **Step 4: Commit the doc updates (only docs; no code in this task)**

```bash
git add "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/PROGRESS.md" "plans and docs/plans/HANDOFF.md" "docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md"
git commit -F - <<'EOF'
[M2.4b] oracle review verdict + decision-gate branch

Human reviewed the per-cell oracle at playable scale vs the window-port.
Verdict and chosen branch (proceed / tune / escalate) recorded in
DRIFT_LOG; PROGRESS, HANDOFF, and the M2.4b plan updated to match.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Self-Review

**1. Spec coverage:**
- Spec "What we build (cheap probe)" — Tasks 1-4 (oracle data source + JSON + scene). ✓
- Spec "decision gate (three branches)" — Task 6. ✓
- Spec "procedural guarantee" — Task 1 tests (determinism + bounded + matches `sample_cell`); invariant stated in plan header. ✓
- Spec "reuse exact same scene/PNG path, zero new render code" — Tasks 2 & 4 reuse `scaffold_3d_review.gd` and the existing writers; only a data-source flag added. ✓
- Spec "render at playable scale" — Task 3/4 use `--span-m 64000` + the playable scene params. ✓
- Spec "gates: review artifacts render non-blank (sky-only fails)" — Task 5 reuses `_viewport_has_visible_content`. ✓
- Spec "integration is a sketch, finalized later / not in this bite" — explicitly out of scope; Task 6 branch 1 routes to a SEPARATE integration plan. ✓

**2. Placeholder scan:** No TBD/TODO. Every code step shows the actual code. Commands have expected output. Task 6 is intentionally a human-park (visual gate) with concrete branch definitions, not a placeholder. ✓

**3. Type/name consistency:** `oracle_fact_map` (Task 1) is used verbatim in Task 2's import + `build_fact_map`. `FactSource`/`parse_source`/`build_fact_map` consistent across Task 2. Scene path `m2_4b_scaffold_oracle_playable_review.tscn` consistent across Tasks 4-5. `ORACLE_PLAYABLE_SCENE` const used in Task 5 `_run`. `data_path` matches `scaffold_3d_review.gd`'s `@export var data_path`. JSON path `m2_4b_scaffold_oracle_3d.json` consistent across Tasks 3-5. ✓

**Note for executor:** The Godot `--quit-after` flag (Task 4 Step 2) may not exist in 4.6.2; fallback is a manual window-close. The gate (Task 5) is the authoritative automated check; Task 4 Step 2 is just an early smoke.
