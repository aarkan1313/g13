# M2.4c Step 2 — GPU Macro Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `field_height.glsl` sample the cached macro layer — upload a `RegionMacro` (RAM) to R32F textures on FieldGpu's local RenderingDevice, bind the page's 2×2 region neighborhood into the compute dispatch, and produce `height = macro.height + per_cell_detail` under a new `terrain_mode == 2` (MACRO_CACHE), non-destructively.

**Architecture:** Step 1 gave us pure-Rust `crate::macro_cache` (RegionMacro, MacroBake, RegionCache). This step bridges it to the GPU: a `GpuRegionMacro` (R32F texture RIDs on the local RD, created once per region) + a GPU-resident map on FieldGpu (lockstep with RegionCache) + a macro-aware `dispatch_page` that binds the 2×2 neighborhood as `SAMPLER_WITH_TEXTURE` uniforms with hardware bilinear, + a GLSL `macro_sample` that selects the owning region by world coord and samples it. Synchronous bake-on-demand in `produce` (step 3 swaps it off-thread behind one function).

**Tech Stack:** Rust gdext (`wg13` crate, `field_gpu.rs`/`page_pool.rs`), GLSL compute (`field_height.glsl`), Godot 4.6.2 Vulkan local RenderingDevice. Spec: `docs/superpowers/specs/2026-06-07-m2-4c-step2-gpu-macro-bridge-design.md`.

**Scope:** Step 2 of 4. NO off-thread bake/prefetch (step 3), NO atlas, NO style routing. Synchronous bake hitch is accepted (step 3 fixes via the `ensure_macro_neighborhood` seam built here).

---

## CRITICAL: the one new mechanic (read before Task 1)

FieldGpu's compute dispatch today uses ONLY `STORAGE_BUFFER` uniforms (bindings 0=out, 1=params, 2=biome). This step introduces **sampled textures + a linear sampler on the LOCAL RenderingDevice** — new mechanics in this file. The exact gdext 0.5.3 call sequence is the highest-risk detail, so Task 1 is a SPIKE that proves the round-trip in isolation and PINS the working API signatures for later tasks.

Confirmed facts (from gdext docs + Godot RenderingDevice):
- Texture create: `rd.texture_create(format: Gd<RDTextureFormat>, view: Gd<RDTextureView>, data)` → `Rid`. Format needs `.set_width/.set_height`, `.set_format(DataFormat::R32_SFLOAT)`, `.set_usage_bits(SAMPLING_BIT | CAN_UPDATE_BIT)`. Data is `Array<PackedByteArray>` (one layer) of LE f32 bytes.
- Sampler: `rd.sampler_create(state: Gd<RDSamplerState>)` → `Rid`. State `.set_min_filter(SamplerFilter::LINEAR)`, `.set_mag_filter(LINEAR)`, repeat modes CLAMP_TO_EDGE.
- Uniform: `RdUniform` with `set_uniform_type(UniformType::SAMPLER_WITH_TEXTURE)`, then `add_id(sampler)` FIRST, then `add_id(texture)` — order matters.
- GLSL binding: `layout(set=0, binding=N) uniform sampler2D macro_x;` then `texture(macro_x, uv)`.
- The exact gdext builder method names (e.g. `RDTextureFormat::new_gd()`, setter spellings) MUST be verified against the installed gdext 0.5.3 in Task 1 — do not assume; the round-trip test compiling + passing IS the verification.

---

## File Structure

- **Create** `rust/gdext/src/macro_gpu.rs` — `GpuRegionMacro` (R32F texture RIDs for one region) + upload/free. Owns the texture-creation mechanics.
- **Modify** `rust/gdext/src/field_gpu.rs` — add the shared `sampler` RID + a `HashMap<(i32,i32), GpuRegionMacro>` resident map to `FieldGpu`; `ensure_region/has_region/evict_region`; extend `dispatch_page` to bind the 2×2 neighborhood; the round-trip test (Task 1) lives here or in macro_gpu.rs.
- **Modify** `rust/gdext/src/field_gpu.rs` `PageParams` — add the 2×2 neighborhood descriptor (4 region origins + bake_spacing + a "macro present" mask) so the shader maps world→UV and knows which regions are real.
- **Modify** `wg-13/shaders/field_height.glsl` — `terrain_mode == 2` branch; 4 `sampler2D` macro bindings + the neighborhood params; `macro_sample(world_xz)` (region select + UV + texture); `height = macro.height + detail`.
- **Modify** `rust/gdext/src/page_pool.rs` — `FieldConfig` gains macro tunables; `produce()` computes the neighborhood, `ensure_macro_neighborhood` (sync bake seam), passes it to dispatch; a `set_terrain_mode` already exists (accepts 2 now).
- **Modify** `rust/gdext/src/lib.rs` — `mod macro_gpu;`.
- **Modify** `wg-13/scripts/world_view.gd` — B-key cycles to MACRO_CACHE (mode 2).
- **Create** `wg-13/tests/m2_4c_macro_live_check.gd` — no-terracing + seam + determinism + regression gate.
- **Docs:** PROGRESS/HANDOFF/DRIFT_LOG at the green gate.

---

## Task 1: SPIKE — R32F texture upload + sample round-trip on the local RD

**Files:**
- Create: `rust/gdext/src/macro_gpu.rs` (the `GpuRegionMacro::upload`/`free` + a sampler helper)
- Modify: `rust/gdext/src/lib.rs` (`mod macro_gpu;`)
- Test: a `#[gditest]`-style test won't work (needs a live RD). Instead, a GDScript round-trip gate `wg-13/tests/m2_4c_macro_roundtrip_check.gd` that drives a new `FieldCompute` test method.

**Context:** This isolates the one risky mechanic. We upload a tiny known R32F texture to the local RD, sample it in a trivial compute dispatch, read it back, and assert the sampled values match (bilinear-exact at texel centers). If this passes, the texture/sampler API is PINNED for all later tasks. If gdext's texture path fights, we discover it here for ~one task's cost (fallback: storage-buffer + manual bilinear behind the same interface — but go textures-first).

This task is necessarily exploratory on exact gdext method names. The implementer MUST verify signatures against the installed `godot` 0.5.3 crate (read the gdext docs or the crate source under `~/.cargo/registry`), not assume. The deliverable is a PASSING round-trip, with the working signatures recorded in code comments.

- [ ] **Step 1: Write the round-trip gate (GDScript, drives a Rust test method)**

Create `wg-13/tests/m2_4c_macro_roundtrip_check.gd`:
```gdscript
extends SceneTree
# M2.4c step-2 SPIKE gate: prove an R32F texture can be created on FieldGpu's local
# RenderingDevice, sampled with a linear sampler in a compute dispatch, and read back.
# Drives FieldCompute.macro_roundtrip_probe (Rust). PASS = the texture/sampler bridge
# works -> the rest of step 2 can build on it.
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_macro_roundtrip_check.gd

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.has_method("macro_roundtrip_probe"):
		print("FAIL: FieldCompute / macro_roundtrip_probe missing")
		print("M2.4c roundtrip RESULT: FAIL"); quit(1); return
	# probe uploads a 2x2 R32F texture with known values, samples 4 texel centers,
	# returns the 4 sampled values. Compare to the source within tolerance.
	var got: PackedFloat32Array = fc.macro_roundtrip_probe()
	var want := [10.0, 20.0, 30.0, 40.0]
	var ok := got.size() == 4
	if ok:
		for i in range(4):
			if absf(got[i] - want[i]) > 0.01: ok = false
	if ok:
		print("PASS: texture round-trip exact at texel centers ", got)
	else:
		print("FAIL: round-trip mismatch got=", got, " want=", want)
	print("M2.4c roundtrip RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
```

- [ ] **Step 2: Run to verify it fails**

Run (PowerShell; the Godot editor must be CLOSED for the wg13 rebuild that adds the method):
```
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo build --manifest-path "rust\Cargo.toml" -p wg13
& "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_macro_roundtrip_check.gd
```
Expected: FAIL — `macro_roundtrip_probe` missing (method not added yet).

- [ ] **Step 3: Implement GpuRegionMacro texture mechanics + the probe**

Create `rust/gdext/src/macro_gpu.rs` with: a `linear_sampler(rd) -> Rid` helper, a `create_r32f_texture(rd, width, height, &[f32]) -> Rid` helper (the pinned mechanic), and `pub struct GpuRegionMacro` (skeleton — full fields in Task 3; for the spike just the helpers are needed). Implement using the gdext API; VERIFY method names against the installed crate. Reference shape (ADAPT names to real gdext 0.5.3 — the implementer confirms each):
```rust
//! M2.4c: GPU-side macro region — R32F textures on FieldGpu's LOCAL RenderingDevice,
//! created once per region, sampled with hardware bilinear by field_height.glsl.

use godot::classes::rendering_device::{
    DataFormat, SamplerFilter, SamplerRepeatMode, TextureUsageBits, UniformType,
};
use godot::classes::{RdSamplerState, RdTextureFormat, RdTextureView, RenderingDevice};
use godot::prelude::*;

/// Create a CLAMP_TO_EDGE linear sampler on the local RD (one shared sampler).
pub fn linear_sampler(rd: &mut Gd<RenderingDevice>) -> Rid {
    let mut st = RdSamplerState::new_gd();
    st.set_min_filter(SamplerFilter::LINEAR);
    st.set_mag_filter(SamplerFilter::LINEAR);
    st.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
    st.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
    rd.sampler_create(&st)
}

/// Create an R32F sampled texture on the local RD from row-major f32 data.
pub fn create_r32f_texture(rd: &mut Gd<RenderingDevice>, width: u32, height: u32, data: &[f32]) -> Rid {
    let mut fmt = RdTextureFormat::new_gd();
    fmt.set_width(width);
    fmt.set_height(height);
    fmt.set_format(DataFormat::R32_SFLOAT);
    fmt.set_usage_bits(TextureUsageBits::SAMPLING_BIT | TextureUsageBits::CAN_UPDATE_BIT);
    let view = RdTextureView::new_gd();
    let bytes = PackedByteArray::from(
        data.iter().flat_map(|f| f.to_le_bytes()).collect::<Vec<u8>>().as_slice(),
    );
    let layers = varray![bytes];
    rd.texture_create(&fmt, &view, &layers)
}
```
Then add a probe method to `FieldCompute` (in `field_compute.rs`) — `#[func] fn macro_roundtrip_probe(&mut self) -> PackedFloat32Array`. It must: build a 2×2 R32F texture with values [10,20,30,40], create the sampler, build a TINY throwaway compute shader (inline GLSL string) that for 4 invocations samples the texture at the 4 texel centers (uv = (x+0.5)/2, (z+0.5)/2) and writes to an output storage buffer, dispatch, read back, return the 4 values. (This proves SAMPLER_WITH_TEXTURE binding end-to-end.) The probe may live in field_compute.rs using its existing `gpu`/`rd` access; if FieldCompute doesn't expose the rd, add the probe to FieldGpu and call through. The implementer chooses the cleanest wiring and records it.

NOTE on the throwaway sampler shader: keep it minimal — `layout(set=0,binding=0) uniform sampler2D src; layout(set=0,binding=1,std430) writeonly buffer Out { float o[]; };` sampling 4 fixed UVs. This is scaffolding for the spike; it can be deleted once the real macro path (Task 4) works, OR kept as the round-trip test's fixture. Keep it — it backs the permanent round-trip gate.

- [ ] **Step 4: Run to verify it passes**

Run the same two commands as Step 2.
Expected: `PASS: texture round-trip exact at texel centers [10, 20, 30, 40]` and `M2.4c roundtrip RESULT: PASS`, exit 0. If it FAILS on a gdext API mismatch, fix the signatures (verify against the crate) — this is the spike's whole job. If the texture path fundamentally won't work after genuine effort, STOP and report BLOCKED with the specific gdext error (the fallback is storage-buffer+manual-bilinear, a design change to escalate).

- [ ] **Step 5: Commit**

Temp-file message + `git commit -F` (here-strings piped to git break in this repo):
```
$msg = @'
[M2.4c] step2 spike: R32F texture upload+sample round-trip on local RD

Proves the one new mechanic (sampled textures + linear sampler on
FieldGpu's local RenderingDevice) end-to-end: upload a 2x2 R32F texture,
sample 4 texel centers in a compute dispatch, read back exact. Pins the
gdext 0.5.3 texture_create/sampler_create/SAMPLER_WITH_TEXTURE API for the
rest of step 2. macro_gpu.rs holds the texture/sampler helpers.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t1.txt" -Value $msg -Encoding ascii
git add rust/gdext/src/macro_gpu.rs rust/gdext/src/lib.rs rust/gdext/src/field_compute.rs wg-13/tests/m2_4c_macro_roundtrip_check.gd
git commit -F "d:\tmp\s2t1.txt"
```

---

## Task 2: GpuRegionMacro (full) + FieldGpu resident map

**Files:**
- Modify: `rust/gdext/src/macro_gpu.rs` (complete `GpuRegionMacro`)
- Modify: `rust/gdext/src/field_gpu.rs` (add `sampler: Rid` + `macro_resident: HashMap<(i32,i32), GpuRegionMacro>` to FieldGpu; `ensure_region/has_region/evict_region`)

**Context:** Now that the texture mechanic is pinned, build the per-region GPU resource and the resident map. For step 2 we sample a SUBSET of fields (height is essential; range/channel for material/biome bias can come later — to keep the bridge minimal, upload `height` + `range_mask` + `channel_mask` now, the three the shader uses in Task 4; the others are easy to add). GpuRegionMacro holds those texture RIDs + (rx,rz) + resolution.

- [ ] **Step 1: Complete `GpuRegionMacro`**

In `macro_gpu.rs` add:
```rust
use crate::macro_cache::RegionMacro;

/// One region's macro fields as R32F textures on the local RD (created once,
/// reused by every page touching the region). RIDs are freed on eviction.
pub struct GpuRegionMacro {
    pub region_x: i32,
    pub region_z: i32,
    pub resolution: u32,
    pub height_tex: Rid,
    pub range_tex: Rid,
    pub channel_tex: Rid,
}

impl GpuRegionMacro {
    pub fn upload(rd: &mut Gd<RenderingDevice>, rm: &RegionMacro) -> Self {
        let w = rm.resolution as u32;
        Self {
            region_x: rm.region_x,
            region_z: rm.region_z,
            resolution: w,
            height_tex: create_r32f_texture(rd, w, w, &rm.height),
            range_tex: create_r32f_texture(rd, w, w, &rm.range_mask),
            channel_tex: create_r32f_texture(rd, w, w, &rm.channel_mask),
        }
    }
    pub fn free(&self, rd: &mut Gd<RenderingDevice>) {
        rd.free_rid(self.height_tex);
        rd.free_rid(self.range_tex);
        rd.free_rid(self.channel_tex);
    }
}
```

- [ ] **Step 2: Add resident map + sampler to FieldGpu (write the test first)**

Because this needs a live RD, the test is a GDScript probe extension. Add to the round-trip gate (or a new gate) a check that `ensure_region` then `has_region` returns true and an out-of-set region returns false. But the cleaner unit-level check: add a Rust-side method count. Simplest: extend `macro_roundtrip_probe` is wrong scope. Instead add `#[func] fn macro_resident_count(&self) -> i64` to whatever owns the map and assert via a small gate. To keep this task self-contained, add a GDScript gate `wg-13/tests/m2_4c_resident_check.gd` that: instantiates the pool/FieldCompute, calls a new test hook `macro_ensure_test(rx,rz,seed,spacing,super_m)` that bakes+ensures a region and returns the resident count, asserts it goes 0->1 and a second ensure of the same region stays 1.

Write `wg-13/tests/m2_4c_resident_check.gd`:
```gdscript
extends SceneTree
# M2.4c step-2: FieldGpu macro-resident map ensure/has/evict.
func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize("res://shaders/field_height.glsl"):
		print("FAIL: init"); print("M2.4c resident RESULT: FAIL"); quit(1); return
	if not fc.has_method("macro_ensure_test") or not fc.has_method("macro_resident_count"):
		print("FAIL: hooks missing"); print("M2.4c resident RESULT: FAIL"); quit(1); return
	var c0: int = fc.macro_resident_count()
	fc.macro_ensure_test(0, 0, 177.0, 256.0, 8000.0)
	var c1: int = fc.macro_resident_count()
	fc.macro_ensure_test(0, 0, 177.0, 256.0, 8000.0)  # same region again
	var c2: int = fc.macro_resident_count()
	var ok := c0 == 0 and c1 == 1 and c2 == 1
	print("resident counts: ", c0, " ", c1, " ", c2)
	print("M2.4c resident RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
```

- [ ] **Step 3: Implement the resident map**

Add to `FieldGpu` struct: `sampler: Rid` (created in `new` via `linear_sampler`), `macro_resident: std::collections::HashMap<(i32,i32), GpuRegionMacro>`. In `new`, after pipeline creation: `let sampler = crate::macro_gpu::linear_sampler(&mut rd);` and init the map empty. Add methods:
```rust
pub fn has_region(&self, rx: i32, rz: i32) -> bool {
    self.macro_resident.contains_key(&(rx, rz))
}
pub fn ensure_region(&mut self, rm: &crate::macro_cache::RegionMacro) {
    let key = (rm.region_x, rm.region_z);
    if !self.macro_resident.contains_key(&key) {
        let g = crate::macro_gpu::GpuRegionMacro::upload(&mut self.rd, rm);
        self.macro_resident.insert(key, g);
    }
}
pub fn evict_region(&mut self, rx: i32, rz: i32) {
    if let Some(g) = self.macro_resident.remove(&(rx, rz)) {
        g.free(&mut self.rd);
    }
}
pub fn macro_resident_count(&self) -> usize { self.macro_resident.len() }
```
Then add the FieldCompute test hooks (`field_compute.rs`): `#[func] fn macro_resident_count(&self) -> i64` (delegates to gpu) and `#[func] fn macro_ensure_test(&mut self, rx: i64, rz: i64, seed: f32, spacing: f32, super_m: f32)` which builds a `MacroBakeConfig`, calls `MacroBake::bake_region`, and `gpu.ensure_region(&rm)`. (FieldCompute holds `gpu: Option<FieldGpu>` like the pool — read field_compute.rs to confirm the field name and access.)

- [ ] **Step 4: Run both gates green**

```
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo build --manifest-path "rust\Cargo.toml" -p wg13
& "C:\Godot\...console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_macro_roundtrip_check.gd
& "C:\Godot\...console.exe" --rendering-driver vulkan --path wg-13 --script res://tests/m2_4c_resident_check.gd
```
Expected: both PASS (round-trip still green; resident counts 0 1 1). Use the full console exe path from earlier tasks.

- [ ] **Step 5: Commit**
```
$msg = @'
[M2.4c] GpuRegionMacro + FieldGpu resident macro map

GpuRegionMacro uploads a region's height/range/channel as R32F textures on
the local RD (created once per region). FieldGpu gains a shared linear
sampler + a (rx,rz)->GpuRegionMacro resident map with ensure/has/evict/
count. Gate: ensure is idempotent (0->1->1). Round-trip still green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t2.txt" -Value $msg -Encoding ascii
git add rust/gdext/src/macro_gpu.rs rust/gdext/src/field_gpu.rs rust/gdext/src/field_compute.rs wg-13/tests/m2_4c_resident_check.gd
git commit -F "d:\tmp\s2t2.txt"
```

---

## Task 3: PageParams macro neighborhood + macro-aware dispatch_page

**Files:**
- Modify: `rust/gdext/src/field_gpu.rs` (`PageParams` + `dispatch_page`)
- Modify: `wg-13/shaders/field_height.glsl` (Params block: neighborhood fields + 4 sampler2D bindings — DECLARATIONS only; the sampling logic is Task 4)

**Context:** Extend the dispatch to bind the page's 2×2 region neighborhood. The page passes 4 region keys; dispatch binds each region's height/range/channel textures (or a placeholder for not-resident regions) as SAMPLER_WITH_TEXTURE uniforms at bindings 3..14 (4 regions × 3 fields), plus the neighborhood descriptor in the params block (4 region origins + bake_spacing + a present-mask). std430 alignment: the params block grows — recompute its size and update the byte-length test.

This task wires the binding + params plumbing; the SHADER still uses composition/oracle for height (Task 4 adds the macro_sample + mode-2 branch). So after this task, mode 0/1 still work and the new uniforms are bound-but-unused (declared in GLSL so the uniform set matches).

- [ ] **Step 1: Decide the neighborhood representation + grow PageParams**

The 2×2 neighborhood = the page's base region (rx,rz) and the 3 positive neighbors? No — a page can straddle in any direction. Represent it as the 2×2 block whose lower corner is the region containing the page's MIN corner: `r0 = floor(page_min / region_core_span)`, covering r0, r0+1 in each axis. Add to PageParams:
```rust
    // M2.4c macro neighborhood: the 2x2 region block covering this page.
    pub macro_origin_x: f32,   // world X of region (r0x,*) core origin = r0x*core_span
    pub macro_origin_z: f32,
    pub macro_core_span: f32,  // region core span (res-1)*bake_spacing
    pub macro_present_mask: u32, // bit b (b=dz*2+dx) set if region (r0x+dx, r0z+dz) is resident
```
Append these to `to_byte_vec` (4 more 4-byte values) and update the GLSL Params block + the `page_params_is_*_bytes` test to the new length (was 80; +16 = 96). DO update both sides together (std430).

- [ ] **Step 2: Update the byte-length test (RED)**

Change the existing `page_params_is_80_bytes` test in field_gpu.rs to `page_params_is_96_bytes` asserting `to_byte_vec().len() == 96`, and add the 4 new fields to the test's PageParams literal (`macro_origin_x: 0.0, macro_origin_z: 0.0, macro_core_span: 1.0, macro_present_mask: 0`). Run: `cargo test -p wg13 page_params` → FAIL (struct lacks fields).

- [ ] **Step 3: Add the fields + to_byte_vec lines + GLSL Params**

Add the 4 fields to `PageParams` (after scaffold_seed). Add to `to_byte_vec` after the scaffold_seed line:
```rust
        v.extend_from_slice(&self.macro_origin_x.to_le_bytes());
        v.extend_from_slice(&self.macro_origin_z.to_le_bytes());
        v.extend_from_slice(&self.macro_core_span.to_le_bytes());
        v.extend_from_slice(&self.macro_present_mask.to_le_bytes());
```
In `field_height.glsl` Params block, after `scaffold_seed`, add:
```glsl
    float macro_origin_x;
    float macro_origin_z;
    float macro_core_span;
    uint  macro_present_mask;
```
And after the BiomeTable declaration, add the 4 region × 3 field sampler bindings (12 samplers, bindings 3..14). Use a clear naming `macro_h_00, macro_r_00, macro_c_00, macro_h_10, ...` for (dx,dz) in {0,1}²:
```glsl
layout(set = 0, binding = 3)  uniform sampler2D macro_h_00;
layout(set = 0, binding = 4)  uniform sampler2D macro_r_00;
layout(set = 0, binding = 5)  uniform sampler2D macro_c_00;
layout(set = 0, binding = 6)  uniform sampler2D macro_h_10;
layout(set = 0, binding = 7)  uniform sampler2D macro_r_10;
layout(set = 0, binding = 8)  uniform sampler2D macro_c_10;
layout(set = 0, binding = 9)  uniform sampler2D macro_h_01;
layout(set = 0, binding = 10) uniform sampler2D macro_r_01;
layout(set = 0, binding = 11) uniform sampler2D macro_c_01;
layout(set = 0, binding = 12) uniform sampler2D macro_h_11;
layout(set = 0, binding = 13) uniform sampler2D macro_r_11;
layout(set = 0, binding = 14) uniform sampler2D macro_c_11;
```
Run: `cargo test -p wg13 page_params` → PASS (96 bytes).

- [ ] **Step 4: Bind the neighborhood in dispatch_page**

`dispatch_page` gains a parameter: the 4 region keys (the pool passes them). For each of the 4 (dx,dz) slots, look up `self.macro_resident.get(&key)`; if present bind its 3 textures, else bind a 1×1 placeholder texture (create one shared placeholder R32F at init, value 0) so the uniform set is always complete. Build 12 SAMPLER_WITH_TEXTURE uniforms (sampler + texture each), bindings 3..14, add to the `uniforms` array, create the set, dispatch as today, free the set after (placeholder + region textures are NOT freed — region ones are cached, placeholder is persistent). The `macro_present_mask` in params tells the shader which slots are real (Task 4 uses it).

Signature: change `dispatch_page(&mut self, params: PageParams)` to `dispatch_page(&mut self, params: PageParams, neighborhood: [(i32,i32); 4])`. Update FieldCompute's callers (produce_page etc.) to pass a default neighborhood `[(0,0);4]` with `macro_present_mask=0` (mode 0/1 ignore macro), so existing gates stay green.

- [ ] **Step 5: Build + run ALL existing gates (mode 0/1 must be unchanged)**

```
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo test --manifest-path "rust\Cargo.toml" --workspace
& godot ... m2_1_climate_check ; m2_2_biome_check ; m2_3_composition_check ; m1_7a_heights_check ; m2_4b_oracle_live_check ; m2_4c_macro_roundtrip_check ; m2_4c_resident_check
```
Expected: workspace green (incl. page_params_is_96_bytes); all GPU gates PASS. Mode-0 height still bit-identical (the macro uniforms are bound but the shader doesn't read them yet). The 12 new samplers being declared-but-unused in GLSL is fine (they're in the uniform set).

- [ ] **Step 6: Commit**
```
$msg = @'
[M2.4c] PageParams macro neighborhood + macro-aware dispatch_page

PageParams grows 80->96 bytes: 2x2 region neighborhood (origins, core span,
present-mask), std430-aligned (test updated). dispatch_page binds the 4
regions x 3 fields as SAMPLER_WITH_TEXTURE (bindings 3..14), placeholder
1x1 for not-resident slots so the set is always complete. GLSL declares the
12 samplers + neighborhood params (unused until Task 4). Mode 0/1 unchanged
(default empty neighborhood); full gate suite green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t3.txt" -Value $msg -Encoding ascii
git add rust/gdext/src/field_gpu.rs rust/gdext/src/field_compute.rs wg-13/shaders/field_height.glsl
git commit -F "d:\tmp\s2t3.txt"
```

---

## Task 4: macro_sample + terrain_mode 2 (the shader)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl` (`macro_sample`, mode-2 branch in main)

**Context:** Now the shader reads the bound macro. `macro_sample(world_xz)` maps the world point to its region within the 2×2 block, computes that region's local UV in [0,1], samples height/range/channel via the right slot's samplers. `height = macro.height + per_cell_detail`. per_cell_detail = a SMALL reuse of the existing value_fbm detail (the gentle high-freq roughness, NOT the oracle's sharp channels) so walked ground isn't perfectly smooth.

- [ ] **Step 1: Write `macro_sample` + helpers in GLSL**

Add before `main()`:
```glsl
// M2.4c: sample the cached macro layer (bound 2x2 region neighborhood). Selects the
// region the world point falls in, computes its local UV, hardware-bilinear samples.
// macro_origin_* = world origin of slot (0,0); each region spans macro_core_span.
struct MacroCell { float height; float range; float channel; bool present; };

MacroCell macro_sample(vec2 world_xz) {
    vec2 local = (world_xz - vec2(macro_origin_x, macro_origin_z)) / macro_core_span;
    // slot index in {0,1}^2 (clamp: points just past a region edge use the apron overlap
    // of the nearest bound region; the present-mask gates validity).
    int dx = int(clamp(floor(local.x), 0.0, 1.0));
    int dz = int(clamp(floor(local.y), 0.0, 1.0));
    vec2 uv = clamp(local - vec2(float(dx), float(dz)), 0.0, 1.0); // within-region [0,1]
    uint bit = uint(dz * 2 + dx);
    bool present = (macro_present_mask & (1u << bit)) != 0u;
    MacroCell m;
    m.present = present;
    // select the slot's samplers (GLSL can't index samplers by var -> branch).
    if (dx == 0 && dz == 0) { m.height = texture(macro_h_00, uv).r; m.range = texture(macro_r_00, uv).r; m.channel = texture(macro_c_00, uv).r; }
    else if (dx == 1 && dz == 0) { m.height = texture(macro_h_10, uv).r; m.range = texture(macro_r_10, uv).r; m.channel = texture(macro_c_10, uv).r; }
    else if (dx == 0 && dz == 1) { m.height = texture(macro_h_01, uv).r; m.range = texture(macro_r_01, uv).r; m.channel = texture(macro_c_01, uv).r; }
    else { m.height = texture(macro_h_11, uv).r; m.range = texture(macro_r_11, uv).r; m.channel = texture(macro_c_11, uv).r; }
    return m;
}

// Gentle per-cell detail on top of the macro (reuses the existing value_fbm; NOT the
// oracle's sharp channels). Small amplitude so walked ground has texture, not terraces.
float macro_detail(vec2 world_xz, uint seed) {
    float d = value_fbm(world_xz * 0.0016, seed ^ 0x4d414344u, 4u, 2.0, 0.5) - 0.5;
    return d * 2.0 * 70.0;  // +/-70m fine roughness (matches composition DETAIL_AMP)
}
```

- [ ] **Step 2: Branch main() for mode 2**

In `main()`, extend the terrain_mode branch:
```glsl
    float h;
    if (terrain_mode == 2u) {
        MacroCell m = macro_sample(world_xz);
        if (m.present) {
            h = m.height + macro_detail(world_xz, uint(seed));
        } else {
            h = composition_height(world_xz, uint(seed)); // REFERENCE fallback (never-black)
        }
    } else if (terrain_mode == 1u) {
        h = oracle_height(world_xz, uint(scaffold_seed));
    } else {
        h = composition_height(world_xz, uint(seed));
    }
```

- [ ] **Step 3: Verify compile (shader compiles on dispatch)**

The shader compiles when FieldGpu dispatches. Run the resident gate (it dispatches): if there's a GLSL compile error it prints `shader compile error`. For now just confirm `cargo build -p wg13` + the resident gate still PASS (the shader compiles; mode-2 path isn't exercised until Task 5 wires the pool). Watch for GLSL reserved words (we hit `coherent` before — avoid `sample`, `filter`, etc.).
Run: `cargo build -p wg13` then the roundtrip + resident gates. Expected: build clean, gates PASS, no shader compile error in stdout.

- [ ] **Step 4: Commit**
```
$msg = @'
[M2.4c] field_height.glsl: macro_sample + terrain_mode 2 (MACRO_CACHE)

macro_sample selects the owning region in the bound 2x2 block, computes
local UV, hardware-bilinear samples height/range/channel. main() mode 2:
height = macro.height + macro_detail (gentle value_fbm, not sharp channels);
falls back to composition_height where the macro isn't present (never-black).
Mode 0/1 unchanged. Compiles clean.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t4.txt" -Value $msg -Encoding ascii
git add wg-13/shaders/field_height.glsl
git commit -F "d:\tmp\s2t4.txt"
```

---

## Task 5: page_pool wiring + world_view toggle

**Files:**
- Modify: `rust/gdext/src/page_pool.rs` (`FieldConfig` macro tunables; `produce` neighborhood + `ensure_macro_neighborhood`; pass to dispatch)
- Modify: `wg-13/scripts/world_view.gd` (B-key cycles to mode 2)

**Context:** Wire the live producer. `produce()` computes the page's 2×2 neighborhood, ensures those regions baked+resident (SYNCHRONOUS — the step-3 swap seam), fills the macro params, calls the macro-aware dispatch.

- [ ] **Step 1: Add macro tunables to FieldConfig**

Add `macro_bake_spacing_m: f32` (default 256.0), `macro_super_region_m: f32` (default 30000.0), `macro_cache_cap: usize` (default 256) to FieldConfig + Default. Add a `RegionCache` instance to PagePool (`region_cache: RegionCache` field, `RegionCache::new(cap)` in init). Add `#[func] set_macro_config(spacing, super_m, cap)`.

- [ ] **Step 2: Implement `ensure_macro_neighborhood` (the step-3 swap seam)**

In page_pool.rs:
```rust
// M2.4c step-2: ensure the 2x2 region block covering this page is baked + GPU-resident.
// STEP-2 = synchronous (bakes on the main thread -> hitch into fresh regions). STEP 3
// swaps the body to off-thread + returns Pending for not-ready regions; the call site
// and the shader's present-mask fallback do NOT change.
fn ensure_macro_neighborhood(&mut self, r0x: i32, r0z: i32) -> u32 {
    let cfg = MacroBakeConfig { bake_spacing_m: self.cfg.macro_bake_spacing_m, super_region_m: self.cfg.macro_super_region_m };
    let mut mask = 0u32;
    for dz in 0..2 { for dx in 0..2 {
        let (rx, rz) = (r0x + dx, r0z + dz);
        if self.region_cache.get(rx, rz).is_none() {
            let rm = MacroBake::bake_region(self.cfg.seed as u64, rx, rz, cfg);
            self.region_cache.insert(rm);
        }
        // upload to GPU if not resident
        if let Some(rm) = self.region_cache.get(rx, rz) {
            if let Some(gpu) = self.gpu.as_mut() { gpu.ensure_region(rm); }
            mask |= 1u32 << (dz * 2 + dx) as u32;
        }
    }}
    mask
}
```
(Borrow note: `region_cache.get` returns `&RegionMacro` while needing `self.gpu` mutably — may need to clone the small key or restructure to avoid double-borrow; the implementer resolves the borrow cleanly, e.g. bake/insert first, then a second loop that gets+ensures, or take the region out. Keep it correct.)

- [ ] **Step 3: Compute neighborhood in produce + pass to dispatch**

In `produce`, when `terrain_mode == 2`, compute the region core span and the page's r0:
```rust
let core_span = (MacroBakeConfig { bake_spacing_m: self.cfg.macro_bake_spacing_m, super_region_m: self.cfg.macro_super_region_m }).core_span_m();
let r0x = (params.origin_x / core_span).floor() as i32;
let r0z = (params.origin_z / core_span).floor() as i32;
let mask = self.ensure_macro_neighborhood(r0x, r0z);
params.macro_origin_x = r0x as f32 * core_span;
params.macro_origin_z = r0z as f32 * core_span;
params.macro_core_span = core_span;
params.macro_present_mask = mask;
let neighborhood = [(r0x,r0z),(r0x+1,r0z),(r0x,r0z+1),(r0x+1,r0z+1)];
```
For mode 0/1, set macro_present_mask=0 and neighborhood `[(0,0);4]`. Pass `neighborhood` to `dispatch_page`. (params must be `mut` in produce.)

- [ ] **Step 4: world_view B-key -> mode 2**

In world_view.gd, change `TERRAIN_MODE_NAMES` to include mode 2: `["REFERENCE (M2.3)", "SCAFFOLD_CANDIDATE (oracle)", "MACRO_CACHE"]`. The existing B handler already does `(_terrain_mode + 1) % size` and `set_terrain_mode` + `_force_regen_all_pages` — so it now cycles through 3 modes. No other change needed.

- [ ] **Step 5: Build + full regression + manual smoke**

```
$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"; cargo build --manifest-path "rust\Cargo.toml" -p wg13
cargo test --manifest-path "rust\Cargo.toml" --workspace
# all GPU gates: climate/biome/composition/heights/oracle-live/roundtrip/resident
```
Expected: workspace green; all gates PASS; mode 0/1 bit-identical. Manual: launch demo.tscn, press B twice to reach MACRO_CACHE, confirm terrain renders (may hitch flying into fresh regions — expected). Don't gate on the manual look here; that's Task 6.

- [ ] **Step 6: Commit**
```
$msg = @'
[M2.4c] page_pool macro wiring + world_view MACRO_CACHE toggle

produce() (mode 2) computes the page's 2x2 region neighborhood, bakes+
uploads it via ensure_macro_neighborhood (synchronous - the step-3 swap
seam), fills the macro params, calls the macro-aware dispatch. FieldConfig
gains macro tunables (spacing/super/cap) + a RegionCache. B key now cycles
REFERENCE -> oracle -> MACRO_CACHE. Mode 0/1 unchanged; gates green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t5.txt" -Value $msg -Encoding ascii
git add rust/gdext/src/page_pool.rs wg-13/scripts/world_view.gd
git commit -F "d:\tmp\s2t5.txt"
```

---

## Task 6: Live gate (no-terracing + seam + determinism) + human walk-test park

**Files:**
- Create: `wg-13/tests/m2_4c_macro_live_check.gd`
- Docs at the gate.

**Context:** The output-provable gate proves the quality decision (no terracing) and that macro fixes the oracle's 1km-wall failure (bounded seam step). Then the human visual gate parks.

- [ ] **Step 1: Write the live gate**

Create `wg-13/tests/m2_4c_macro_live_check.gd`. Use `FieldCompute` with a new `#[func] produce_macro_page(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude)` that sets terrain_mode=2, computes+ensures the neighborhood, and returns the height channel (add this hook in field_compute.rs in this task — it mirrors produce_oracle_page but mode 2 + neighborhood). The gate asserts:
- determinism: same page twice -> identical.
- finite + non-flat (relief > 100m over a wide scan).
- NO-TERRACING: max adjacent-cell step on a level-0 (fine, spacing 8) page is SMOOTH — assert max step < (a threshold that catches 256m terraces but allows real slopes), e.g. < 60m per 8m cell (steep but continuous), and CRUCIALLY assert there is NO cluster of identical values followed by a jump (sample a row; assert consecutive deltas vary, not 64-cell plateaus). Simpler robust check: produce the SAME world strip at spacing 8 and assert the height curve is C0-smooth (max second-difference bounded) — i.e. no step discontinuities.
- seam: a page straddling a region boundary has bounded max adjacent step (< the oracle's 1076m; assert < 600m like the composition no-cliff gate).
Write concrete asserts mirroring m2_3_composition_check's style (avg/max step helpers).

- [ ] **Step 2: Run the live gate green**

`& godot ... m2_4c_macro_live_check`. Expected: PASS (determinism, relief, no-terracing, seam all green), exit 0. If no-terracing FAILS (terraces present), the bilinear isn't working — debug the sampler/UV (do NOT loosen the threshold; terracing is the exact artifact this gate exists to catch).

- [ ] **Step 3: Full regression**

Run every gate (m2_1/m2_2/m2_3/m1_7a/m1_7c/m2_4b_oracle_live/roundtrip/resident/macro_live) + `cargo test --workspace`. All PASS; mode 0/1 bit-identical.

- [ ] **Step 4: Commit the gate**
```
$msg = @'
[M2.4c] live macro gate: no-terracing + seam + determinism (PASS)

produce_macro_page hook + m2_4c_macro_live_check: macro-cache height is
deterministic, finite, non-flat, C0-smooth across fine cells (proves
hardware bilinear - no 256m terraces), and seam-bounded across region
borders (< 600m vs the oracle's 1076m walls). Full regression green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
'@
Set-Content -Path "d:\tmp\s2t6.txt" -Value $msg -Encoding ascii
git add wg-13/tests/m2_4c_macro_live_check.gd rust/gdext/src/field_compute.rs
git commit -F "d:\tmp\s2t6.txt"
```

- [ ] **Step 5: Human walk-test (PARK) + docs**

Launch demo.tscn for the human; B to MACRO_CACHE; fly + walk. Capture verdict: does the macro terrain read as believable smoothed ranges/valleys + drainage, no terracing, no walls, traversable? (Accept the fly-into-fresh-region hitch — step 3 fixes.) Then update DRIFT_LOG/PROGRESS/HANDOFF with the verdict and next (step 3 = async scheduler/prefetch) and commit docs. This is the visual gate — agent parks, does not self-certify.

---

## Self-Review

**1. Spec coverage:**
- 2x2 binding, select-not-blend — Task 3 (bind) + Task 4 (select by world coord). ✓
- R32F textures + hardware bilinear — Task 1 (spike) + Task 2 (GpuRegionMacro). ✓
- GPU-resident map lockstep w/ RegionCache — Task 2 + Task 5 (cache + ensure). ✓
- mode-gated additive height (terrain_mode 2) — Task 4 + Task 5. ✓
- 2x2 region descriptor in params (origins + spacing + present-mask) — Task 3. ✓
- REFERENCE fallback / never-black — Task 3 (placeholder bind) + Task 4 (present-mask -> composition). ✓
- ensure_macro_neighborhood swap seam — Task 5. ✓
- synchronous bake (accepted) — Task 5. ✓
- no-terracing gate + seam gate + determinism + regression — Task 6. ✓
- human walk-test park — Task 6 Step 5. ✓
- non-goals (no async/atlas/style) — none of the tasks build them. ✓

**2. Placeholder scan:** Task 1 is intentionally exploratory on exact gdext signatures (the spike's purpose) — it gives reference code + instructs verification against the installed crate, not a blank. Everything else has concrete code. No TBD/TODO.

**3. Type/name consistency:** `GpuRegionMacro`, `ensure_region/has_region/evict_region/macro_resident_count`, `macro_present_mask`, `macro_origin_x/z`, `macro_core_span`, `ensure_macro_neighborhood`, `produce_macro_page`, terrain_mode==2, sampler binding names `macro_{h,r,c}_{00,10,01,11}` (bindings 3..14) consistent across tasks. PageParams 80->96 bytes consistent (Task 3). `MacroBakeConfig`/`MacroBake`/`RegionCache` from step 1 used consistently.

**Executor notes:**
- Task 1 is the spike — if the gdext texture API genuinely fights after real effort, STOP/BLOCKED (fallback = storage-buffer+manual-bilinear, a design escalation).
- Editor CLOSED for every wg13 build; GPU gates need `--rendering-driver vulkan` (no headless).
- Borrow-checker care in `ensure_macro_neighborhood` (cache `&` vs gpu `&mut`) — restructure, don't clone the big RegionMacro; cloning the (rx,rz) key + a short second loop is fine.
- Watch GLSL reserved words in new shader code (we hit `coherent` before).
- Mode 0/1 bit-identical is the non-negotiable regression bar at every task.
