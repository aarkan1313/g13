//! `FieldCompute` — the test oracle for the GPU field (M1.2/M1.4 gates).
//!
//! A thin Godot-callable wrapper over `field_gpu::FieldGpu`: produce a page and
//! return its heights (or an R32F texture). Used by determinism/continuity/seam
//! tests. The runtime uses `PagePool` (also over `FieldGpu`); both share the one
//! GPU-dispatch implementation, so there is no duplicated field code (00 §4).

use crate::field_gpu::{FieldGpu, FieldPage, PageParams, BIOME_STRIDE};
use godot::classes::image::Format;
use godot::classes::{Image, ImageTexture};
use godot::prelude::*;

/// Continental climate defaults for the test oracle, matching
/// `PagePool`'s `FieldConfig::default` so a FieldCompute production reproduces
/// the runtime climate exactly (the M2.1 gate relies on this). Order matches the
/// GLSL Params block: lat_scale, temp_freq, temp_noise, lapse, moist_freq.
const CLIMATE_DEFAULT: [f32; 5] = [60000.0, 0.00002, 0.15, 0.35, 0.000025];

/// M2.2 biome roster + weights for the test oracle, matching PagePool's
/// BIOME_CENTROIDS / weights so a FieldCompute production reproduces the runtime
/// biome ids exactly (the M2.2 gate relies on this). Centroids: [t,m,a,_pad] × N.
const BIOME_CENTROIDS: [[f32; BIOME_STRIDE]; 10] = [
    [0.15, 0.50, 0.95, 0.0],
    [0.18, 0.35, 0.55, 0.0],
    [0.35, 0.62, 0.50, 0.0],
    [0.50, 0.30, 0.85, 0.0],
    [0.58, 0.30, 0.30, 0.0],
    [0.55, 0.70, 0.35, 0.0],
    [0.50, 0.92, 0.35, 0.0],
    [0.88, 0.15, 0.25, 0.0],
    [0.85, 0.45, 0.30, 0.0],
    [0.90, 0.90, 0.30, 0.0],
];
const BIOME_WEIGHTS: [f32; 3] = [1.0, 1.0, 1.2];   // temp, moist, alt
const BIOME_ALT_FREQ: f32 = 0.000033;              // macro-altitude freq (match PagePool)

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct FieldCompute {
    base: Base<RefCounted>,
    gpu: Option<FieldGpu>,
}

#[godot_api]
impl IRefCounted for FieldCompute {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, gpu: None }
    }
}

#[godot_api]
impl FieldCompute {
    /// Create the local RD + compile the field shader, and push the default
    /// biome centroid table (matching PagePool). Returns true on success.
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        if let Some(gpu) = self.gpu.as_mut() {
            let flat: Vec<f32> = BIOME_CENTROIDS.iter().flatten().copied().collect();
            gpu.set_biome_centroids(&PackedFloat32Array::from(flat.as_slice()));
        }
        self.gpu.is_some()
    }

    /// Build PageParams with the default continental climate + biome roster (so
    /// heights match the M1 path exactly — climate/biome never feed back into
    /// height — and climate/biome reproduce the runtime). Mirrors the GLSL block.
    fn params(origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
              page_res: i64, octaves: i64, base_freq: f32, amplitude: f32) -> PageParams {
        PageParams {
            origin_x, origin_z, spacing, seed,
            page_res: page_res as u32, octaves: octaves as u32, base_freq, amplitude,
            climate_lat_scale: CLIMATE_DEFAULT[0],
            climate_temp_freq: CLIMATE_DEFAULT[1],
            climate_temp_noise: CLIMATE_DEFAULT[2],
            climate_lapse: CLIMATE_DEFAULT[3],
            climate_moist_freq: CLIMATE_DEFAULT[4],
            biome_count: BIOME_CENTROIDS.len() as u32,
            biome_w_temp: BIOME_WEIGHTS[0],
            biome_w_moist: BIOME_WEIGHTS[1],
            biome_w_alt: BIOME_WEIGHTS[2],
            biome_alt_freq: BIOME_ALT_FREQ,
            // M2.4b: default REFERENCE mode so every existing gate's height path
            // stays bit-identical to M2.3; scaffold_seed mirrors seed.
            terrain_mode: 0,
            scaffold_seed: seed,
            // M2.4c: no macro neighborhood for the test oracle (mode 0/1 ignore it).
            // core_span defaults to 1.0 (not 0.0) to avoid divide-by-zero in Task 4.
            macro_origin_x: 0.0,
            macro_origin_z: 0.0,
            macro_core_span: 1.0,
            macro_present_mask: 0,
        }
    }

    /// Produce one page; return PAGE_RES*PAGE_RES heights row-major.
    #[func]
    fn produce_page(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        let p = Self::params(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        // M2.4c: empty macro neighborhood (mask stays 0 from defaults) — mode 0/1
        // don't read the macro; the 4 slots bind the placeholder.
        gpu.dispatch_page(p, [(0, 0); 4]).map(|fp| fp.heights).unwrap_or_default()
    }

    /// M2.1: produce one page and return its CLIMATE channels interleaved
    /// [temp, moisture] per cell (2*page_res*page_res floats, row-major). Used by
    /// the m2_1_climate gate to prove determinism / low-freq / range on the real
    /// GPU output. Empty on failure. (Height is via produce_page; this avoids a
    /// Dictionary return so the gate reads a plain typed array.)
    #[func]
    fn produce_climate_page(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        let p = Self::params(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        let Some(FieldPage { temp, moisture, .. }) = gpu.dispatch_page(p, [(0, 0); 4]) else {
            return PackedFloat32Array::new();
        };
        let n = temp.len();
        let mut out = PackedFloat32Array::new();
        out.resize(n * 2);
        let dst = out.as_mut_slice();
        let t = temp.as_slice();
        let m = moisture.as_slice();
        for i in 0..n {
            dst[i * 2] = t[i];
            dst[i * 2 + 1] = m[i];
        }
        out
    }

    /// M2.2: produce one page and return its BIOME-ID channel (float-encoded int,
    /// page_res*page_res floats, row-major). Used by the m2_2_biome gate to prove
    /// determinism / contiguity / valid-id on the real GPU output. Empty on fail.
    #[func]
    fn produce_biome_page(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        let p = Self::params(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        gpu.dispatch_page(p, [(0, 0); 4]).map(|fp| fp.biome).unwrap_or_default()
    }

    /// M2.4b: produce one page's HEIGHT channel in SCAFFOLD_CANDIDATE mode (the
    /// per-cell oracle), page_res*page_res floats row-major. Same params as
    /// produce_page but terrain_mode=1, so the m2_4b_oracle_live gate can prove the
    /// oracle path is live, deterministic, finite, non-flat, and distinct from the
    /// REFERENCE (mode 0) height. scaffold_seed mirrors seed.
    #[func]
    fn produce_oracle_page(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        let mut p = Self::params(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        p.terrain_mode = 1;
        p.scaffold_seed = seed;
        gpu.dispatch_page(p, [(0, 0); 4]).map(|fp| fp.heights).unwrap_or_default()
    }

    /// M2.4c step-2 Task 6: produce one page's HEIGHT channel in MACRO_CACHE mode
    /// (terrain_mode = 2), page_res*page_res floats row-major. Same params as
    /// produce_page, but this hook also BAKES + ENSURES the page's 2x2 macro
    /// region neighborhood so the gate exercises the REAL macro-sampling path
    /// (hardware-bilinear over the resident R32F textures), not the placeholder.
    /// The macro bake config matches PagePool's FieldConfig defaults so the gate
    /// proves the live macro params; it re-bakes every call (no cache here — fine
    /// for a bounded test hook, and ensure_region is idempotent so repeated
    /// ensures are cheap). Used by m2_4c_macro_live_check.
    #[func]
    fn produce_macro_page(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        // Macro bake config (matches PagePool's FieldConfig defaults so the gate
        // exercises the live macro params; tunable there, fixed here for the gate).
        let mcfg = crate::macro_cache::MacroBakeConfig { bake_spacing_m: 256.0, super_region_m: 30000.0 };
        let core_span = mcfg.core_span_m();
        // r0 = region containing the page origin (min corner). The 2x2 block r0..r0+1.
        let r0x = (origin_x / core_span).floor() as i32;
        let r0z = (origin_z / core_span).floor() as i32;
        // Bake + ensure the 4 regions; build the present-mask.
        let mut mask = 0u32;
        for dz in 0..2i32 {
            for dx in 0..2i32 {
                let (rx, rz) = (r0x + dx, r0z + dz);
                let rm = crate::macro_cache::MacroBake::bake_region(seed as u64, rx, rz, mcfg);
                gpu.ensure_region(&rm);
                mask |= 1u32 << (dz * 2 + dx) as u32;
            }
        }
        let mut p = Self::params(origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        p.terrain_mode = 2;
        p.macro_origin_x = r0x as f32 * core_span;
        p.macro_origin_z = r0z as f32 * core_span;
        p.macro_core_span = core_span;
        p.macro_present_mask = mask;
        // Slot order (0,0),(1,0),(0,1),(1,1) MUST match dz*2+dx and the GLSL binding order.
        let neighborhood = [(r0x, r0z), (r0x + 1, r0z), (r0x, r0z + 1), (r0x + 1, r0z + 1)];
        gpu.dispatch_page(p, neighborhood).map(|fp| fp.heights).unwrap_or_default()
    }

    /// M2.4c step-2 SPIKE gate: prove the R32F-texture + linear-sampler path on
    /// FieldGpu's local RenderingDevice end-to-end. Delegates to
    /// FieldGpu::macro_roundtrip_probe (uploads a 2x2 R32F texture [10,20,30,40],
    /// samples the 4 texel centers in a compute dispatch, reads back). Returns the
    /// 4 floats; the gate asserts they match [10,20,30,40] exactly. Empty on a
    /// missing device. Requires `initialize` first (it builds the local RD).
    #[func]
    fn macro_roundtrip_probe(&mut self) -> PackedFloat32Array {
        if self.gpu.is_none() {
            // The probe only needs the local RD, not the field shader; initialize
            // with the field shader path so callers don't have to pre-initialize.
            self.gpu = FieldGpu::new(&GString::from("res://shaders/field_height.glsl"));
        }
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: no local RenderingDevice (need --rendering-driver vulkan).");
            return PackedFloat32Array::new();
        };
        gpu.macro_roundtrip_probe()
    }

    /// M2.4c step-2 resident gate: how many region macros are resident on the
    /// local RD. 0 before any ensure; +1 per distinct region.
    #[func]
    fn macro_resident_count(&self) -> i64 {
        self.gpu.as_ref().map_or(0, |g| g.macro_resident_count() as i64)
    }

    /// M2.4c step-2 resident gate: bake a region (pure-Rust) and ensure it is
    /// resident. Idempotent for the same (rx,rz) — a repeat ensure does not grow
    /// the resident count. Used by m2_4c_resident_check to prove 0 -> 1 -> 1.
    #[func]
    fn macro_ensure_test(&mut self, rx: i64, rz: i64, seed: i64, spacing: f32, super_m: f32) {
        let Some(gpu) = self.gpu.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return;
        };
        let cfg = crate::macro_cache::MacroBakeConfig { bake_spacing_m: spacing, super_region_m: super_m };
        let rm = crate::macro_cache::MacroBake::bake_region(seed as u64, rx as i32, rz as i32, cfg);
        gpu.ensure_region(&rm);
    }

    /// Produce one page packed into an R32F ImageTexture (for a render shader).
    #[func]
    fn produce_page_texture(
        &mut self,
        origin_x: f32, origin_z: f32, spacing: f32, seed: f32,
        page_res: i64, octaves: i64, base_freq: f32, amplitude: f32,
    ) -> Option<Gd<ImageTexture>> {
        let heights = self.produce_page(
            origin_x, origin_z, spacing, seed, page_res, octaves, base_freq, amplitude);
        let res = page_res as i32;
        if heights.len() as i32 != res * res {
            godot_error!("produce_page_texture: unexpected height count");
            return None;
        }
        let bytes = heights.to_byte_array();
        let img = Image::create_from_data(res, res, false, Format::RF, &bytes)?;
        ImageTexture::create_from_image(&img)
    }
}
