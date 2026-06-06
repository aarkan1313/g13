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

/// M2.2 biome roster (centroids [t,m,a,_pad]) for the test oracle, matching
/// PagePool so a FieldCompute production reproduces the runtime biome ids. M2.4:
/// the GPU row also carries the DEM spectrum (built in initialize), so this is
/// just the 4-float centroid; the spectrum comes from the fingerprints.
const BIOME_CENTROIDS: [[f32; 4]; 10] = [
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

use crate::fingerprints;

/// Biome -> DEM archetype (must match PagePool's BIOME_ARCHETYPE).
const BIOME_ARCHETYPE: [&str; 10] = [
    "glacial","tundra","temperate","mountain","grassland",
    "temperate","rainforest","desert","grassland","rainforest",
];

fn load_fingerprints_fc() -> std::collections::HashMap<String, fingerprints::Fingerprint> {
    use godot::classes::file_access::ModeFlags;
    use godot::classes::FileAccess;
    let path = GString::from("res://data/dem_fingerprints.json");
    match FileAccess::open(&path, ModeFlags::READ) {
        Some(f) => fingerprints::parse(&f.get_as_text().to_string()),
        None => std::collections::HashMap::new(),
    }
}

fn default_fingerprint_fc() -> fingerprints::Fingerprint {
    let mut s = [0f32; fingerprints::N_BANDS];
    let mut a = 1.0f32; let mut tot = 0.0f32;
    for i in 0..fingerprints::N_BANDS { s[i] = a; tot += a; a *= 0.5; }
    for v in s.iter_mut() { *v /= tot; }
    fingerprints::Fingerprint { spectrum: s, slope_p95: 1.0 }
}

/// Build the per-biome GPU table (BIOME_STRIDE floats/biome) — same packing as
/// PagePool::build_biome_table, so the oracle reproduces the runtime exactly.
fn build_biome_table_fc(fps: &std::collections::HashMap<String, fingerprints::Fingerprint>) -> Vec<f32> {
    let mut out = Vec::with_capacity(BIOME_CENTROIDS.len() * BIOME_STRIDE);
    for (i, c) in BIOME_CENTROIDS.iter().enumerate() {
        let fp = fps.get(BIOME_ARCHETYPE[i]).copied().unwrap_or_else(default_fingerprint_fc);
        out.push(c[0]); out.push(c[1]); out.push(c[2]); out.push(fp.slope_p95);
        for k in 0..4 { out.push(fp.spectrum[k]); }
        for k in 4..8 { out.push(fp.spectrum[k]); }
        out.push(0.0); out.push(0.0); out.push(0.0); out.push(0.0);
    }
    out
}

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
            // M2.4: reproduce the runtime table (same fingerprints, same packing).
            let fps = load_fingerprints_fc();
            let table = build_biome_table_fc(&fps);
            gpu.set_biome_centroids(&PackedFloat32Array::from(table.as_slice()));
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
        gpu.dispatch_page(p).map(|fp| fp.heights).unwrap_or_default()
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
        let Some(FieldPage { temp, moisture, .. }) = gpu.dispatch_page(p) else {
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
        gpu.dispatch_page(p).map(|fp| fp.biome).unwrap_or_default()
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
