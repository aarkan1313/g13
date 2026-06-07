# M2.4b Oracle Live Integration Plan (candidate lane)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live, walkable `demo.tscn` world able to render the GPU-portable per-cell oracle (`synthesize_cell`) as a TOGGLEABLE terrain mode beside the accepted M2.3 composition machine, so the human can fly AND walk it with real collision and V/key-toggle compare — the spec's Branch 1.

**Architecture:** Port the Rust per-cell oracle (`structural_scaffold::synthesize_cell`, already stateless and pure-`(seed,x,z)`) into `field_height.glsl` as a new `oracle_height()` function. Add a `terrain_mode` uint param to the field's `Params` block; `main()` selects M2.3 `composition_height` (mode 0 = REFERENCE) or the oracle (mode 1 = SCAFFOLD_CANDIDATE). Plumb `terrain_mode` + the oracle's scalar style constants through the existing Rust param pipeline (`PageParams` -> `to_bytes()` std430 -> `FieldConfig` -> `produce`), and expose a `set_terrain_mode` `#[func]` toggled live from `world_view.gd`. The height path stays channel-0; climate/biome/collision contracts are unchanged (they read height additively). NO neighbor ops, NO apron, NO blur — the oracle is per-cell by construction, which is the whole reason it fits this shader.

**Tech Stack:** GLSL compute (`field_height.glsl`), Rust gdext (`field_gpu.rs`, `page_pool.rs`, `field_compute.rs`), GDScript (`world_view.gd`), Godot 4.6.2-mono, Vulkan (GPU gates can't run headless).

**Shared-foundation note (why this is worth doing even if Approach C is later needed):** the candidate-mode toggle, the Rust->shader param plumbing, the GLSL per-cell primitives (segment distance, fbm, ridged_fbm, style selection), and the collision/biome contract are ALL needed by Approach C too. Only the analytic sine-curve channels (~20%) would be replaced by C's real flow routing. So this plan builds the shared base on the cheap per-cell version first and yields a real walk-test.

**Procedural invariant (must hold):** every oracle value is a pure function of `(seed, world_x, world_z)`. No file I/O, no stored tiles, no precompute. The GLSL port must be a faithful translation of `synthesize_cell` — same math, same constants.

---

## CRITICAL HAZARD: std430 alignment of the Params block

The field `Params` block (`field_height.glsl` lines ~44-71) is a flat std430 storage buffer. Rust `PageParams::to_bytes()` (`field_gpu.rs:50`) writes it field-by-field as LE bytes; the GLSL struct reads it field-by-field. **The byte order and count MUST match exactly between the two, or every page reads garbage.** The current block is documented as 20 floats = 80 bytes (8 height + 5 climate + 5 biome + 2 pad). There are two trailing pads (`_biome_pad0`, `_biome_pad1`).

Strategy for adding params WITHOUT breaking alignment:
- All fields in this block are 4-byte (f32 or u32). std430 for a buffer of all-4-byte scalars is just tight packing — no vec padding surprises — so appending 4-byte scalars at the END is safe as long as Rust and GLSL append the SAME fields in the SAME order.
- We will REPLACE the two existing trailing pads with `terrain_mode` (u32) + one oracle param, then APPEND the remaining oracle params after, updating BOTH sides together in one task, and re-verify byte length.
- After the change, the block grows from 20 to N floats; assert `to_bytes()` produces `N*4` bytes in a unit test.

The oracle needs these scalar style constants (from `structural_scaffold::style_params`, but the oracle SELECTS style per-cell internally, so we pass the WHOLE-WORLD constants the oracle already hardcodes — see Task 2). To keep the block small and the port faithful, the GLSL port HARDCODES the same per-style constant tables the Rust oracle hardcodes (they are compile-time constants in `lib.rs`, not runtime params). Therefore the ONLY new runtime params are: `terrain_mode` (u32) and `scaffold_seed` (f32, allowing the oracle to use a seed independent of the M1 height seed if desired — default = same as `seed`). This keeps the std430 change minimal: replace the 2 pads with `terrain_mode` + `scaffold_seed`. Net float count stays 20. **No length change — lowest-risk path.**

---

## File Structure

- **Modify** `wg-13/shaders/field_height.glsl` — add `terrain_mode` + `scaffold_seed` to `Params`; port `synthesize_cell` -> `oracle_height()` + its helpers (segment distance, style select, range field, channel distance) translated from `lib.rs`; branch in `main()`.
- **Modify** `rust/gdext/src/field_gpu.rs` — `PageParams`: replace `_pad` usage with `terrain_mode: u32` + `scaffold_seed: f32`; update `to_bytes()`; assert 80-byte length in a test.
- **Modify** `rust/gdext/src/page_pool.rs` — `FieldConfig`: add `terrain_mode`, `scaffold_seed`; default mode 0; `produce` passes them; new `#[func] set_terrain_mode(mode: i64)`.
- **Modify** `rust/gdext/src/field_compute.rs` — mirror the new params so the test oracle stays consistent (height bit-identical in mode 0).
- **Modify** `wg-13/scripts/world_view.gd` — a key (proposed: `B`) cycles terrain_mode REFERENCE<->SCAFFOLD_CANDIDATE live, pushing to the pool; on-screen note.
- **Create** `wg-13/tests/m2_4b_oracle_live_check.gd` — gate: mode 0 height bit-identical to M2.3 baseline (regression), mode 1 produces DIFFERENT, finite, non-flat height; determinism per mode.
- **Docs (live):** PROGRESS, HANDOFF, DRIFT_LOG, the M2.4b plan at the green gate.

---

## Task 1: Reference the Rust oracle math to port (read-only orientation)

**Files:** none modified — this task produces a porting map.

**Context:** The GLSL port must faithfully mirror `structural_scaffold::synthesize_cell` (`rust/structural_scaffold/src/lib.rs` ~line 365) and its helpers. Translating Rust f32 math to GLSL is mechanical but error-prone; a side-by-side map prevents drift.

- [ ] **Step 1: Build the porting map**

Read and list, from `rust/structural_scaffold/src/lib.rs`, the exact bodies of: `synthesize_cell`, `style_at`, `style_params` (the 4 `StyleParams` rows), `domain_warp`, `range_field`, `range_segment`, `primary_channel_distance`, `tributary_channel_distance`, `rotate2`, `point_segment_distance`, `ridged_fbm`, `fbm`, `value_noise`, `rand01_i`, `mix64`, `smoothstep`, `smootherstep`, `lerp`. Note each function's exact constants. This is the translation source of truth for Task 2.

Output: a checklist of every function to port, with its constants, kept in this task's notes (or a scratch file) for Task 2 to follow line-by-line.

- [ ] **Step 2: Note the GLSL hash divergence risk**

`field_height.glsl` already has a hash/value-noise (`hash_u`, `hash2`, `value_noise`) but it is a DIFFERENT algorithm from the Rust oracle's (`mix64` + `rand01_i` + `value_noise`). The oracle port MUST use its OWN translated hash (`mix64`/`rand01_i`), NOT the shader's existing `value_noise`, or the terrain will differ from the reviewed Rust oracle. Name the ported functions distinctly (e.g. `osc_value_noise`, `osc_rand01`, `osc_mix64`) to avoid collision with the M2.3 functions. Record this constraint.

- [ ] **Step 3: Commit the porting map (if a scratch file was used)**

If a scratch porting-map file was created under `docs/superpowers/plans/`, commit it; otherwise this task has no commit (it informs Task 2).

```bash
git add docs/superpowers/plans/2026-06-06-m2-4b-oracle-port-map.md
git commit -F - <<'EOF'
[M2.4b] oracle->GLSL port map (translation source of truth)

Lists every structural_scaffold function + constants to translate, and
the hash-divergence constraint (port mix64/rand01_i, not the shader's
existing value_noise) so the live terrain matches the reviewed oracle.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: Port `synthesize_cell` into `field_height.glsl` as `oracle_height()`

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (add ported functions + `oracle_height`; do NOT call it yet)

**Context:** Translate every function from Task 1's map into GLSL, prefixed `osc_` to avoid name collisions. GLSL has no `u64`; the Rust oracle uses `u64` seeds and `mix64` (64-bit). **This is the single biggest porting risk.** Translate `mix64` using `uvec2` (hi/lo 32-bit halves) or accept a documented precision reduction by using a 32-bit hash that reproduces the Rust output closely enough for visual parity. DECISION for this plan: implement a `uvec2`-based 64-bit mix (`osc_mix64`) so the hash matches Rust bit-for-bit; this is the only way to guarantee the live terrain equals the reviewed oracle. (If `uvec2` 64-bit mul proves too painful, fall back to a 32-bit hash and ACCEPT that mode-1 live terrain is a close cousin of, not identical to, the reviewed sheet — record which path was taken.)

- [ ] **Step 1: Add a failing GLSL-side smoke (via the Rust test oracle)**

The shader itself can't be unit-tested directly. The gate is `field_compute.rs` (test oracle) producing mode-1 height. Defer the real assertion to Task 6's gate; here, just add `oracle_height` so later tasks compile. Mark this step done when the function exists and the shader still compiles (verified in Task 3 when first dispatched).

- [ ] **Step 2: Add the ported helper functions**

In `field_height.glsl`, after the existing M2.3 primitives (after `composition_height`, before the climate section), add the `osc_`-prefixed ports. Translate EXACTLY from Task 1's map. Skeleton (fill bodies from the Rust source — every constant must match):

```glsl
// --- M2.4b oracle (per-cell scaffold), ported from structural_scaffold::synthesize_cell.
// FAITHFUL translation: same math + constants as the reviewed Rust oracle. Uses its
// OWN hash (osc_mix64/osc_rand01) — NOT the shader's value_noise — so live terrain
// equals the reviewed sheet. Pure fn of (world coords, seed): no neighbors, no state.

uvec2 osc_mix64(uvec2 x) {
    // 64-bit splitmix-style mix on (hi,lo). Mirror rust mix64 exactly.
    // ... implement 64-bit ops via uvec2 (carry-aware mul/shift) ...
    return x; // REPLACE with faithful port
}

float osc_rand01(uint seed_hi, uint seed_lo, int x, int z, uint salt) {
    // mirror rand01_i: combine seed^salt*K ^ x*K2 ^ z*K3, mix64, take (h>>40)/2^24
    return 0.0; // REPLACE
}

float osc_value_noise(uint sh, uint sl, float x, float z, float freq) { return 0.0; } // REPLACE
float osc_fbm(uint sh, uint sl, float x, float z, float freq, int oct, float lac, float gain) { return 0.0; } // REPLACE
float osc_ridged_fbm(uint sh, uint sl, float x, float z, float freq, int oct) { return 0.0; } // REPLACE
// ... style_at, style_params (as a switch returning a struct of floats), domain_warp,
//     range_field, range_segment, primary_channel_distance, tributary_channel_distance,
//     rotate2, point_segment_distance ...
```

NOTE: GLSL has no u64 literals — split each Rust `u64` seed/constant into `uvec2(hi, lo)`. The master `seed` arrives as a float param; convert with `uint(seed)` and pair as `uvec2(0u, uint(seed))` unless the Rust path uses the full 64-bit seed (it does via `u64`); to match, derive `osc` seeds the same way the Rust does. Document any reduction.

- [ ] **Step 3: Add `oracle_height(vec2 world_xz, uint seed)`**

Translate `synthesize_cell`'s height assembly (the `preview_height_m` computation, lib.rs ~432) into a GLSL `float oracle_height(vec2 world_xz, uint seed)`. Return the same value `synthesize_cell` puts in `preview_height_m`. Do NOT wire it into `main()` yet.

- [ ] **Step 4: Verify the shader still compiles**

Compilation is verified when the pool first dispatches it (Task 3). For now, eyeball-check GLSL syntax (no `u64`, no Rust-only syntax, all functions declared before use). Mark done.

- [ ] **Step 5: Commit**

```bash
git add wg-13/shaders/field_height.glsl
git commit -F - <<'EOF'
[M2.4b] port per-cell oracle into field_height.glsl (oracle_height)

Faithful GLSL translation of structural_scaffold::synthesize_cell + its
helpers (osc_-prefixed, own 64-bit-via-uvec2 hash so live terrain matches
the reviewed oracle). Not wired into main() yet. Procedural: pure fn of
(world coords, seed); no neighbors/apron/blur.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: Add `terrain_mode` + `scaffold_seed` to the Params block (both sides, aligned)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (Params block + `main()` branch)
- Modify: `rust/gdext/src/field_gpu.rs` (`PageParams` + `to_bytes` + length test)

**Context:** Replace the two trailing pads with `terrain_mode` (u32) and `scaffold_seed` (f32). Net float count stays 20 = 80 bytes (lowest-risk; see HAZARD section). Both sides must change together.

- [ ] **Step 1: Write the failing byte-length test**

In `rust/gdext/src/field_gpu.rs`, add a test module (or extend one) asserting the params serialize to exactly 80 bytes:

```rust
#[cfg(test)]
mod params_tests {
    use super::*;
    #[test]
    fn page_params_is_80_bytes() {
        let p = PageParams {
            origin_x: 0.0, origin_z: 0.0, spacing: 1.0, seed: 1.0,
            page_res: 8, octaves: 5, base_freq: 0.001, amplitude: 1.0,
            climate_lat_scale: 1.0, climate_temp_freq: 1.0, climate_temp_noise: 0.1,
            climate_lapse: 0.3, climate_moist_freq: 1.0,
            biome_count: 1, biome_w_temp: 1.0, biome_w_moist: 1.0, biome_w_alt: 1.0,
            biome_alt_freq: 1.0, terrain_mode: 0, scaffold_seed: 1.0,
        };
        assert_eq!(p.to_bytes().len(), 80);
    }
}
```

Run: `cargo test --manifest-path rust\Cargo.toml -p gdext page_params_is_80_bytes`
Expected: FAIL — `PageParams` has no `terrain_mode`/`scaffold_seed` fields yet.

- [ ] **Step 2: Add the fields to `PageParams`**

In `field_gpu.rs`, replace the end of the struct. Change:

```rust
    pub biome_alt_freq: f32, // macro-altitude frequency (continental, low)
}
```

to:

```rust
    pub biome_alt_freq: f32, // macro-altitude frequency (continental, low)
    // --- M2.4b terrain mode + scaffold seed (replaces the 2 former pads) ---
    pub terrain_mode: u32,   // 0 = REFERENCE (M2.3 composition), 1 = SCAFFOLD_CANDIDATE (oracle)
    pub scaffold_seed: f32,  // oracle seed (default = `seed`); kept separate for future tuning
}
```

- [ ] **Step 3: Update `to_bytes()`**

In `to_bytes()`, replace the two pad lines:

```rust
        v.extend_from_slice(&0f32.to_le_bytes());   // _biome_pad0
        v.extend_from_slice(&0f32.to_le_bytes());   // _biome_pad1
```

with:

```rust
        v.extend_from_slice(&self.terrain_mode.to_le_bytes());  // was _biome_pad0
        v.extend_from_slice(&self.scaffold_seed.to_le_bytes()); // was _biome_pad1
```

- [ ] **Step 4: Run the byte-length test green**

Run: `cargo test --manifest-path rust\Cargo.toml -p gdext page_params_is_80_bytes`
Expected: PASS (still 80 bytes — we swapped pads for real fields, no size change).

- [ ] **Step 5: Update the GLSL Params block + branch main()**

In `field_height.glsl`, replace the two pad lines in the `Params` block:

```glsl
    float _biome_pad0;         // pad block to 20 floats (80 bytes)
    float _biome_pad1;
```

with:

```glsl
    uint  terrain_mode;        // M2.4b: 0 = REFERENCE (composition), 1 = SCAFFOLD_CANDIDATE (oracle)
    float scaffold_seed;       // M2.4b: oracle seed (defaults to seed)
```

Then in `main()`, replace:

```glsl
    float h = composition_height(world_xz, uint(seed));
```

with:

```glsl
    float h;
    if (terrain_mode == 1u) {
        h = oracle_height(world_xz, uint(scaffold_seed));
    } else {
        h = composition_height(world_xz, uint(seed));
    }
```

- [ ] **Step 6: Commit**

```bash
git add rust/gdext/src/field_gpu.rs wg-13/shaders/field_height.glsl
git commit -F - <<'EOF'
[M2.4b] add terrain_mode + scaffold_seed params (std430-aligned)

Replaces the 2 trailing Params pads with terrain_mode (u32) + scaffold_seed
(f32) on BOTH sides; net block stays 80 bytes (test asserts it). main()
now branches: mode 1 -> oracle_height, mode 0 -> composition_height
(unchanged default). Mode still 0 everywhere until the pool plumbs it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 4: Plumb `terrain_mode` through `FieldConfig` / `produce` + `set_terrain_mode`

**Files:**
- Modify: `rust/gdext/src/page_pool.rs` (`FieldConfig`, `Default`, `produce`, new `#[func]`)
- Modify: `rust/gdext/src/field_compute.rs` (mirror, so the test oracle matches)

**Context:** `FieldConfig` holds runtime params; `produce` builds `PageParams` from it; `configure_*` `#[func]`s set them from GDScript. Add `terrain_mode` (default 0) + `scaffold_seed` (default = seed) and a setter.

- [ ] **Step 1: Add fields to `FieldConfig`**

In `page_pool.rs`, change the end of `struct FieldConfig`:

```rust
    biome_alt_freq: f32,
}
```

to:

```rust
    biome_alt_freq: f32,
    // M2.4b candidate terrain mode (0 = M2.3 reference, 1 = oracle) + oracle seed.
    terrain_mode: u32,
    scaffold_seed: f32,
}
```

- [ ] **Step 2: Add defaults**

In `impl Default for FieldConfig`, before the closing `}` of the `Self { ... }`, add:

```rust
            terrain_mode: 0,
            scaffold_seed: 1234.0,   // mirrors the default seed; world_view can sync it
```

(Place after `biome_alt_freq: BIOME_ALT_FREQ,`.)

- [ ] **Step 3: Pass through in `produce`**

In `produce`, add to the `PageParams { ... }` literal, after `biome_alt_freq: self.cfg.biome_alt_freq,`:

```rust
            terrain_mode: self.cfg.terrain_mode,
            scaffold_seed: self.cfg.scaffold_seed,
```

- [ ] **Step 4: Add the `set_terrain_mode` #[func]**

After `configure_climate` (or near `set_max_eager_per_frame`), add:

```rust
    /// M2.4b: switch live terrain between REFERENCE (0 = M2.3 composition) and
    /// SCAFFOLD_CANDIDATE (1 = per-cell oracle). Toggled from world_view. Pages
    /// produced after this use the new mode; call clear/regen to refresh resident
    /// pages (world_view re-requests on toggle).
    #[func]
    fn set_terrain_mode(&mut self, mode: i64) {
        self.cfg.terrain_mode = if mode == 1 { 1 } else { 0 };
    }

    /// M2.4b: set the oracle seed (defaults to the world seed). Optional tuning hook.
    #[func]
    fn set_scaffold_seed(&mut self, seed: f32) {
        self.cfg.scaffold_seed = seed;
    }

    /// M2.4b introspection for the HUD/gate.
    #[func]
    fn terrain_mode(&self) -> i64 {
        self.cfg.terrain_mode as i64
    }
```

- [ ] **Step 5: Mirror in `field_compute.rs`**

Read `field_compute.rs`; wherever it constructs `PageParams` (the test oracle's `produce_page` / `produce_climate_page`), add `terrain_mode: 0` and `scaffold_seed: <its seed>` so it compiles and mode-0 stays bit-identical. If `field_compute` should also produce mode-1 for the gate, add a `produce_oracle_page` that sets `terrain_mode: 1` (Task 6 uses it).

- [ ] **Step 6: Build + run existing gates (regression)**

Close the Godot editor first (DLL lock on `wg13.dll`). Then:
```
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"
cargo build --manifest-path rust\Cargo.toml -p gdext
cargo test --manifest-path rust\Cargo.toml --workspace
```
Expected: builds clean; all existing Rust tests PASS (the params change is additive, mode defaults to 0).

- [ ] **Step 7: Commit**

```bash
git add rust/gdext/src/page_pool.rs rust/gdext/src/field_compute.rs
git commit -F - <<'EOF'
[M2.4b] plumb terrain_mode + scaffold_seed through pool + test oracle

FieldConfig gains terrain_mode (default 0) + scaffold_seed; produce passes
them; set_terrain_mode / set_scaffold_seed / terrain_mode #[func]s added.
field_compute mirrors the params (mode 0 bit-identical) + a mode-1
produce_oracle_page for the gate. Workspace tests green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 5: Live toggle key in `world_view.gd`

**Files:**
- Modify: `wg-13/scripts/world_view.gd` (input handler + pool call + page refresh)

**Context:** Add a key (proposed `B` — "biome" is V, "B" for the scaffold/build terrain toggle; confirm no conflict by reading world_view.gd's input). On press: flip terrain_mode on the pool, then force resident pages to regenerate (evict/clear so new pages produce with the new mode) so the change is visible immediately, not only on newly streamed pages.

- [ ] **Step 1: Read world_view.gd input + page-request path**

Read `wg-13/scripts/world_view.gd`. Find the `_input`/`_unhandled_input` (the V view-mode toggle is there) and the page request/clear path (how pages are requested from the pool, and whether there's a clear/regen call). Confirm `B` is free.

- [ ] **Step 2: Add the toggle**

In the input handler, alongside the V handling, add (adapt names to the actual pool node reference + clear method found in Step 1):

```gdscript
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		_terrain_mode = 1 - _terrain_mode
		_pool.set_terrain_mode(_terrain_mode)
		_force_regen_all_pages()   # evict resident + drop instances so pages re-produce in the new mode
		print("TERRAIN MODE: ", "SCAFFOLD_CANDIDATE (oracle)" if _terrain_mode == 1 else "REFERENCE (M2.3)")
```

Add `var _terrain_mode: int = 0` to the script's state. Implement `_force_regen_all_pages()` using whatever clear/evict the pool exposes (e.g. iterate levels and `evict_outside` with radius -1, or a dedicated clear) + drop the view's mesh instances so they rebuild. If a full clear helper doesn't exist, the minimal version: clear `_instances` + free meshes + let the normal streaming re-request (document the approach taken).

- [ ] **Step 3: Sync scaffold_seed to the world seed (optional, 1 line)**

Where `world_view` calls `_pool.configure(...)` with the seed, also call `_pool.set_scaffold_seed(seed)` so the oracle uses the same world seed by default.

- [ ] **Step 4: Smoke — launch and toggle**

Launch `demo.tscn` (windowed, Vulkan). Confirm: starts in REFERENCE (M2.3 terrain, unchanged), pressing B switches to oracle terrain and the world visibly changes, pressing B again returns to M2.3. No black, no crash. (This is a manual smoke; the gate in Task 6 is the automated check.)

- [ ] **Step 5: Commit**

```bash
git add wg-13/scripts/world_view.gd
git commit -F - <<'EOF'
[M2.4b] B key toggles live terrain REFERENCE<->SCAFFOLD_CANDIDATE

world_view pushes set_terrain_mode to the pool and regens resident pages
so the switch is immediate. Starts in REFERENCE (M2.3 unchanged). Lets the
human fly AND walk the oracle and compare live. scaffold_seed synced to
the world seed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 6: Live integration gate (regression + oracle-distinct + determinism)

**Files:**
- Create: `wg-13/tests/m2_4b_oracle_live_check.gd`

**Context:** Output-provable gate. Uses the pool/test-oracle to assert: (a) mode 0 height is bit-identical to the pre-integration M2.3 baseline for a known page (regression — the candidate lane did not disturb the reference), (b) mode 1 produces FINITE, NON-FLAT height that DIFFERS from mode 0, (c) determinism per mode. This proves the integration is safe and the oracle is actually live, without a human.

- [ ] **Step 1: Write the gate**

Create `wg-13/tests/m2_4b_oracle_live_check.gd` (SceneTree script, mirrors existing gates' structure). It should, via the pool or `FieldCompute`:
- produce a fixed page (e.g. level 0, gx=0, gz=0) in mode 0 twice -> assert bit-identical (determinism) AND assert it matches the known M2.3 values (capture the baseline once from the current build);
- produce the same page in mode 1 twice -> assert bit-identical (determinism), all finite, and max-min spread > a threshold (non-flat), and assert mode-1 != mode-0 on at least one cell (oracle is actually different/live).

Use the same run pattern as `m2_2_biome_check.gd` / `m2_3_composition_check.gd` (read one for the exact harness API).

- [ ] **Step 2: Run the gate green**

Close the editor; build if needed; run:
```
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4b_oracle_live_check.gd
```
Expected: `M2.4b oracle live RESULT: PASS`, exit 0.

- [ ] **Step 3: Run the FULL regression suite**

Run every existing gate (m2_1, m2_2, m2_3, m1_7a, m1_7c, the frametime + never-black gates) to prove the candidate lane broke nothing. Expected: all PASS, mode-0 paths bit-identical.

- [ ] **Step 4: Commit**

```bash
git add wg-13/tests/m2_4b_oracle_live_check.gd
git commit -F - <<'EOF'
[M2.4b] live integration gate: mode-0 regression + mode-1 distinct/finite

Asserts mode 0 stays bit-identical to the M2.3 baseline (candidate lane
didn't disturb reference), mode 1 is deterministic, finite, non-flat, and
actually differs from mode 0. Full existing gate suite re-run green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 7: Human fly + walk visual gate (PARK)

**Files:** docs at the gate (PROGRESS, HANDOFF, DRIFT_LOG, M2.4b plan).

**Context:** THE point of the whole effort. The agent cannot self-certify a visual gate (working method §2). Human flies AND walks the oracle live, toggling B against M2.3.

- [ ] **Step 1: Launch demo.tscn for the human**

Launch via `run.ps1` (windowed). Tell the human: starts in REFERENCE; press B to switch to the oracle; fly it, then drop to walk (G) and walk the oracle terrain; toggle B to compare feel; watch for the "strange roughness"/sine-corduroy the spec warned about.

- [ ] **Step 2: Capture verdict against the decision gate**

Record which branch:
1. Oracle walks well -> M2.4 candidate ACCEPTED; next decide promote-to-default vs keep-as-toggle, then per-biome/erosion later.
2. Close but off -> tune `synthesize_cell` (Rust) in fast loops, re-port the changed constants to GLSL, re-gate, re-review.
3. Oracle's faked drainage feels wrong -> escalate to Approach C (window-based GPU pipeline) as its own milestone, now WITH a walk-test as evidence.

- [ ] **Step 3: Log + update docs**

DRIFT_LOG entry (TYPE: VISUAL gate, verdict, branch, next). Update PROGRESS M2.4 line, HANDOFF §3, the M2.4b plan's next-bite. Commit docs only.

```bash
git add "plans and docs/plans/DRIFT_LOG.md" "plans and docs/plans/PROGRESS.md" "plans and docs/plans/HANDOFF.md" "docs/superpowers/plans/2026-06-06-m2-4b-dem-structural-scaffold.md"
git commit -F - <<'EOF'
[M2.4b] live oracle walk-test verdict + branch

Human flew + walked the oracle candidate live vs M2.3 (B toggle). Verdict
and chosen branch recorded in DRIFT_LOG; PROGRESS/HANDOFF/plan updated.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Self-Review

**1. Spec coverage:**
- Spec Section 4 "port synthesize_cell -> GLSL" — Task 2. ✓
- Spec "terrain-mode switch REFERENCE/SCAFFOLD_CANDIDATE" — Tasks 3-5. ✓
- Spec "wire scaffold params through Rust like climate/biome" — Tasks 3-4. ✓
- Spec "height-path contract intact; collision reads channel-0; climate/biome unchanged" — Task 6 mode-0 regression gate. ✓
- Spec "determinism check GLSL oracle vs Rust oracle within tolerance" — Task 6 (determinism per mode; faithful port targets bit-match, with documented fallback). ✓
- Spec "human visual pass at playable scale in demo.tscn = the real gate" — Task 7. ✓
- Procedural invariant — Task 2 (faithful pure-fn port, no I/O). ✓

**2. Placeholder scan:** Task 2's GLSL bodies are skeletons with REPLACE markers — this is INTENTIONAL and unavoidable: the faithful port is a mechanical line-by-line translation of ~15 Rust functions whose source is named exactly (Task 1 builds the map). Reproducing ~250 lines of translated GLSL inline here would be more error-prone than instructing a careful translation against the cited source. Every function to port, its location, and its constraints (own hash, u64-via-uvec2, exact constants) ARE specified. This is the one place where "show the exact code" yields to "translate this exact named source faithfully" — flagged honestly rather than hidden.

**3. Type/name consistency:** `terrain_mode`/`scaffold_seed` consistent across PageParams (Task 3), FieldConfig (Task 4), GLSL Params (Task 3), set_terrain_mode (Task 4), world_view (Task 5). `oracle_height` defined Task 2, called Task 3 main(). 80-byte assertion (Task 3) matches the swap-pads-no-size-change strategy. `osc_` prefix convention stated Task 1/2, used Task 2. ✓

**Executor notes:**
- The u64->GLSL hash port (Task 2) is the highest-risk step. If bit-exact match to the Rust oracle proves impractical, the documented fallback (32-bit hash, accept "close cousin" not identical) keeps the plan moving — but RECORD which path was taken, because it changes whether Task 6 can assert GLSL==Rust bit-equality or only "non-flat + deterministic + distinct."
- Editor must be CLOSED for any `cargo build -p gdext` (wg13.dll lock). GLSL/GDScript-only changes need no rebuild.
- All GPU gates need `--rendering-driver vulkan` (no headless).
