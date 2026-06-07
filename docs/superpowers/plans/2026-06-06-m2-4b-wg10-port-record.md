# M2.4b WG10 Port Record

## Purpose

Record exactly how the accepted M2.4b static scaffold sheet was made, so the
next agent can reproduce it and avoid drifting back into scalar DEM tuning or
the rejected line-segment scaffold.

This is an offline/prototype lane. It does not replace the accepted M2.3 live
terrain and it is not runtime-integrated yet.

## Source Material

Primary WG10 sources used:

- `D:\workflows\worldgen10\tools\dem_pack\mountain_synthesis.py`
- `D:\workflows\worldgen10\tools\dem_pack\render_mountain_synthesis.py`
- `D:\workflows\worldgen10\tools\dem_pack\render_worldgen.py`
- `D:\workflows\worldgen10\wg-10\rust\src\recipe_noise.rs`
- `D:\workflows\worldgen10\wg-10\rust\src\array_ops.rs`
- `D:\workflows\worldgen10\wg-10\rust\src\recipes.rs`
- `D:\workflows\worldgen10\wg-10\rust\src\recipes\helpers.rs`
- `D:\workflows\worldgen10\wg-10\rust\src\recipes\mountain.rs`

Visual target:

- `D:\world gen 13\archive\from_D_tmp\wg10_mountain_synthesis\mountain_synthesis_200km.png`
- `D:\world gen 13\archive\from_D_tmp\wg10_mountain_synthesis\mountain_synthesis_200km_debug.png`

## What Was Copied

The following WG10 Rust modules were copied into `rust/structural_scaffold` and
kept offline-only:

- `src/recipe_noise.rs`: bit-close WG10 noise primitives.
- `src/array_ops.rs`: WG10 whole-array Gaussian and MFD flow accumulation ops.
- `src/recipes.rs`: recipe wrapper and helper module layout.
- `src/recipes/helpers.rs`: affine remap, smoothstep, apron meshgrid, flow channel helper.
- `src/recipes/mountain.rs`: seam-safe WG10 mountain synthesis.

The copied recipe was adapted in `src/recipes/mountain.rs`:

- added all four WG10 mountain styles, not just `ALPINE_BRANCHING`;
- added `MountainFields`, a diagnostic return payload containing height, ranges,
  range envelope, lowland, primary/tributary channels, massif, valley mask, and
  floor mask;
- preserved the original `generate_seamsafe(...) -> Vec<f64>` entry point for
  height-only callers;
- added `generate_seamsafe_fields(...) -> MountainFields` so WG13 can derive
  explicit region facts from the same fields that make the image.

## WG13 Fact Mapping

`rust/structural_scaffold/src/lib.rs` now runs the WG10 recipe over an
apron-padded grid and maps fields into `FactCell`:

- `range_mask` comes from WG10 `range_envelope`.
- `ridge_axis` comes from WG10 `ranges`.
- `channel_mask` comes from max(primary channels, tributaries * 0.65).
- `pass_floor` comes from max(floor mask, lowland * 0.35).
- `material.rock` blends range/ridge/massif.
- `material.snow` derives from preview height plus range mask.
- `material.valley_floor` derives from channel, pass, and valley masks.
- `preview_height_m` maps normalized WG10 height with `1050 + height * 520`.

Default `RegionConfig.region_span_m` changed to `30000.0`, so the 3x3 region
report corresponds to a 90 km region-fact audit while the visual review sheet
uses a separate 200 km comparison span.

## Review Renderer

`rust/structural_scaffold/src/main.rs` now renders the review sheet as four
height-shaded panels:

1. alpine branching;
2. sierra block;
3. pamir chains;
4. dissected highlands.

The renderer was aligned to the archived WG10 synthesis sheet:

- default seed: `177`;
- review span: `200000` m;
- four side-by-side style panels;
- panel-local height normalization before hillshade;
- WG10-style hillshade based on `render_worldgen.py::hillshade`.

Generated artifacts:

- `wg-13/_captures/m2_4b_scaffold_review.png`
- `wg-13/_captures/m2_4b_scaffold_review.md`
- `wg-13/_captures/m2_4b_scaffold_3d.json`

Generation command:

```powershell
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- review
```

3D data export command:

```powershell
cargo run --manifest-path rust\Cargo.toml -p structural_scaffold -- export-godot
```

Latest report metrics:

- preview height range: `-831.4` to `2253.9` m;
- max east/west seam fact delta: `0.00000000`;
- max south/north seam fact delta: `0.00000000`;
- max channel response: `1.000`;
- mean channel density: `0.025`;
- minimum largest high-discharge component at threshold `0.18`: `10` cells.

## Gates

Rust workspace gate:

```powershell
cargo test --manifest-path rust\Cargo.toml --workspace
```

Status: PASS.

Known warning: `dem_distill::sidecar::Sidecar` fields `width` and `height` are
still unused. This warning predates the WG10 port and is unrelated to the
scaffold.

Structural scaffold unit coverage now checks:

- deterministic same-seed region output;
- adjacent-region border agreement;
- nontrivial sparse WG10-style drainage signal;
- bounded finite fact values.

## 3D Review Scene

The first 3D review is deliberately static and separate from the accepted M2.3
runtime page pool:

- `wg-13/scenes/m2_4b_scaffold_3d_review.tscn`
- `wg-13/scripts/scaffold_3d_review.gd`
- `wg-13/tests/m2_4b_scaffold_3d_check.gd`

The scene reads `res://_captures/m2_4b_scaffold_3d.json`, builds four
`ArrayMesh` terrain panels, and spawns the standard `fly_camera.gd` free-fly
camera. It uses vertex colors derived from rock/snow/valley/channel facts, so
the 3D pass exercises more than grayscale height. The review camera has an
explicit long far clip for the multi-kilometer panels, and the material is
double-sided so the static review is not dependent on triangle winding.

3D smoke command:

```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_4b_scaffold_3d_check.gd
```

Latest 3D smoke result: PASS, `4` panels / `148996` vertices, plus rendered
viewport variance check so a sky-only frame fails.

Launch command:

```powershell
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64.exe" --rendering-driver vulkan --path "D:\world gen 13\wg-13" res://scenes/m2_4b_scaffold_3d_review.tscn
```

## What Not To Do

- Do not resume scalar DEM-character tuning as the main M2.4 path.
- Do not tune the old line-segment scaffold; that output was visually rejected.
- Do not replace M2.3 terrain by default.
- Do not treat this as M2.4 visual acceptance. It is a good static baseline and
  now needs a separate 3D/runtime candidate review.

## Next Step

Build a separate 3D review/candidate lane that samples these WG10-derived facts
without disturbing the accepted M2.3 baseline. The first 3D pass should prove
scale, framing, and fly/readability before the scaffold enters the live page
producer.
