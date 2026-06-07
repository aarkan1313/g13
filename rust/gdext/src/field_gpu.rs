//! Shared GPU field machinery — the one place that compiles the field shader,
//! dispatches it over a page, and reads the result back. Both `FieldCompute`
//! (the test oracle) and `PagePool` (the runtime) use this, so there is exactly
//! ONE implementation of "run the field on the GPU" (00 §4, no duplication).
//!
//! This is NOT a second field: the world math is still the GLSL in
//! wg-13/shaders/. This module only drives that GLSL on a local RenderingDevice.

use godot::classes::rendering_device::{ShaderLanguage, ShaderStage, UniformType};
use godot::classes::{RdShaderSource, RdUniform, RenderingDevice, RenderingServer};
use godot::prelude::*;

/// Number of float channels the field shader writes per cell (M2.2): the page
/// carries [height, temperature, moisture, biome_id, normal_x, normal_z]
/// interleaved (00 §2.1, one dispatch). biome_id is a float-encoded integer index
/// into the biome table; normal_x/normal_z are the analytic surface-gradient
/// components (M2.4: seam-free per-cell normals computed from the continuous
/// height function, so adjacent pages agree at the shared edge).
pub const FIELD_CHANNELS: usize = 6;

/// Floats per biome centroid row in the pushed BiomeTable (vec4 stride for
/// std430): [temp_c, moist_c, alt_c, _pad].
pub const BIOME_STRIDE: usize = 4;

/// Parameters for one page production. Mirrors the GLSL `Params` block layout,
/// std430-friendly: 20 × 4 bytes = 80 bytes (8 height + 6 climate + 6 biome,
/// the last 3 of which are pad). Field order MUST match field_height.glsl.
#[derive(Clone, Copy)]
pub struct PageParams {
    pub origin_x: f32,
    pub origin_z: f32,
    pub spacing: f32,
    pub seed: f32,
    pub page_res: u32,
    pub octaves: u32,
    pub base_freq: f32,
    pub amplitude: f32,
    // --- M2.1 climate params (see field_height.glsl Params block) ---
    pub climate_lat_scale: f32,
    pub climate_temp_freq: f32,
    pub climate_temp_noise: f32,
    pub climate_lapse: f32,
    pub climate_moist_freq: f32,
    // --- M2.2 biome classifier params ---
    pub biome_count: u32,
    pub biome_w_temp: f32,
    pub biome_w_moist: f32,
    pub biome_w_alt: f32,
    pub biome_alt_freq: f32, // macro-altitude frequency (continental, low)
}

impl PageParams {
    fn to_bytes(&self) -> PackedByteArray {
        let mut v: Vec<u8> = Vec::with_capacity(80);
        v.extend_from_slice(&self.origin_x.to_le_bytes());
        v.extend_from_slice(&self.origin_z.to_le_bytes());
        v.extend_from_slice(&self.spacing.to_le_bytes());
        v.extend_from_slice(&self.seed.to_le_bytes());
        v.extend_from_slice(&self.page_res.to_le_bytes());
        v.extend_from_slice(&self.octaves.to_le_bytes());
        v.extend_from_slice(&self.base_freq.to_le_bytes());
        v.extend_from_slice(&self.amplitude.to_le_bytes());
        v.extend_from_slice(&self.climate_lat_scale.to_le_bytes());
        v.extend_from_slice(&self.climate_temp_freq.to_le_bytes());
        v.extend_from_slice(&self.climate_temp_noise.to_le_bytes());
        v.extend_from_slice(&self.climate_lapse.to_le_bytes());
        v.extend_from_slice(&self.climate_moist_freq.to_le_bytes());
        v.extend_from_slice(&self.biome_count.to_le_bytes());
        v.extend_from_slice(&self.biome_w_temp.to_le_bytes());
        v.extend_from_slice(&self.biome_w_moist.to_le_bytes());
        v.extend_from_slice(&self.biome_w_alt.to_le_bytes());
        v.extend_from_slice(&self.biome_alt_freq.to_le_bytes());
        v.extend_from_slice(&0f32.to_le_bytes());   // _biome_pad0
        v.extend_from_slice(&0f32.to_le_bytes());   // _biome_pad1
        PackedByteArray::from(v.as_slice())
    }
}

/// One produced page, deinterleaved into separate per-channel arrays (each
/// page_res*page_res, row-major z*res+x). `heights` is exactly what M1 produced,
/// so the M1.7 collision/height contract is unchanged; `temp`/`moisture` are the
/// M2.1 climate channels; `biome` is the M2.2 biome-id channel (float-encoded
/// int) for the display shader's biome debug color.
pub struct FieldPage {
    pub heights: PackedFloat32Array,
    pub temp: PackedFloat32Array,
    pub moisture: PackedFloat32Array,
    pub biome: PackedFloat32Array,
    /// M2.4 analytic surface-normal gradient, deinterleaved: `normal_x` = -(hr-hl),
    /// `normal_z` = -(hu-hd) per cell. Packed into one RG32F texture for the display
    /// shader, which reconstructs the +Y component. Seam-free across page edges.
    pub normal_x: PackedFloat32Array,
    pub normal_z: PackedFloat32Array,
}

/// A compiled field-compute pipeline on a dedicated local RenderingDevice.
/// Create once with `new`, then `dispatch_page` per page.
pub struct FieldGpu {
    rd: Gd<RenderingDevice>,
    shader: Rid,
    pipeline: Rid,
    /// M2.2 biome centroid table (binding 2): flat f32 LE bytes, BIOME_STRIDE
    /// floats per biome ([temp_c, moist_c, alt_c, _pad]). Set via
    /// set_biome_centroids; the std430 buffer can't be zero-length, so a 1-row
    /// default is kept until configured (biome_count in PageParams gates use).
    biome_bytes: PackedByteArray,
}

impl FieldGpu {
    /// Create a local RenderingDevice and compile the field shader at the given
    /// res:// path. Returns None if no device (e.g. `--headless`) or compile error.
    pub fn new(shader_glsl_path: &GString) -> Option<Self> {
        let server = RenderingServer::singleton();
        let mut rd = server.create_local_rendering_device().or_else(|| {
            godot_error!("FieldGpu: no local RenderingDevice (need --rendering-driver vulkan).");
            None
        })?;
        let src = load_glsl(shader_glsl_path);
        let mut shader_source = RdShaderSource::new_gd();
        shader_source.set_language(ShaderLanguage::GLSL);
        shader_source.set_stage_source(ShaderStage::COMPUTE, &src);
        let spirv = rd.shader_compile_spirv_from_source(&shader_source).or_else(|| {
            godot_error!("FieldGpu: SPIR-V compile returned null.");
            None
        })?;
        let err = spirv.get_stage_compile_error(ShaderStage::COMPUTE);
        if !err.is_empty() {
            godot_error!("FieldGpu: shader compile error: {}", err);
            return None;
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        let pipeline = rd.compute_pipeline_create(shader);
        // Default biome table: one centroid (BIOME_STRIDE floats), so the std430
        // buffer is never zero-length before set_biome_centroids. With biome_count
        // left at its caller default this still classifies sanely (all -> row 0).
        let biome_bytes = PackedByteArray::from(vec![0u8; BIOME_STRIDE * 4]);
        Some(Self { rd, shader, pipeline, biome_bytes })
    }

    /// Set the M2.2 biome centroid table. `centroids` is a flat f32 list,
    /// BIOME_STRIDE per biome: [temp_c, moist_c, alt_c, _pad] × N. The caller
    /// passes biome_count in PageParams to match. Must be non-empty (std430).
    pub fn set_biome_centroids(&mut self, centroids: &PackedFloat32Array) {
        if centroids.is_empty() {
            return;
        }
        self.biome_bytes = centroids.to_byte_array();
    }

    /// Dispatch the field over one page and read all channels back to the CPU.
    /// Returns a FieldPage with deinterleaved height/temp/moisture arrays, each
    /// PAGE_RES*PAGE_RES floats, row-major (z * page_res + x). ONE dispatch, ONE
    /// readback — climate rides along with height (00 §2.1).
    pub fn dispatch_page(&mut self, params: PageParams) -> Option<FieldPage> {
        let res = params.page_res;
        let n = (res * res) as usize;

        // The shader writes FIELD_CHANNELS floats per cell, interleaved.
        let out_bytes = PackedByteArray::from(vec![0u8; n * FIELD_CHANNELS * 4]);
        let out_buf = self.rd.storage_buffer_create_ex(out_bytes.len() as u32).data(&out_bytes).done();
        let pbytes = params.to_bytes();
        let param_buf = self.rd.storage_buffer_create_ex(pbytes.len() as u32).data(&pbytes).done();
        // M2.2 biome centroid table (binding 2).
        let biome_buf = self.rd
            .storage_buffer_create_ex(self.biome_bytes.len() as u32)
            .data(&self.biome_bytes)
            .done();

        let mut u_out = RdUniform::new_gd();
        u_out.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_out.set_binding(0);
        u_out.add_id(out_buf);
        let mut u_param = RdUniform::new_gd();
        u_param.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_param.set_binding(1);
        u_param.add_id(param_buf);
        let mut u_biome = RdUniform::new_gd();
        u_biome.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_biome.set_binding(2);
        u_biome.add_id(biome_buf);

        let uniforms = array![&u_out, &u_param, &u_biome];
        let uniform_set = self.rd.uniform_set_create(&uniforms, self.shader, 0);

        let groups = (res + 7) / 8;
        let cl = self.rd.compute_list_begin();
        self.rd.compute_list_bind_compute_pipeline(cl, self.pipeline);
        self.rd.compute_list_bind_uniform_set(cl, uniform_set, 0);
        self.rd.compute_list_dispatch(cl, groups, groups, 1);
        self.rd.compute_list_end();
        self.rd.submit();
        self.rd.sync();

        let interleaved = self.rd.buffer_get_data(out_buf).to_float32_array();
        self.rd.free_rid(uniform_set);
        self.rd.free_rid(out_buf);
        self.rd.free_rid(param_buf);
        self.rd.free_rid(biome_buf);

        // Deinterleave [h,t,m,b, ...] into four contiguous channel arrays.
        // heights is bit-identical to what the M1 single-channel path produced
        // for the same cell, so the M1.7 collision/texture contract is preserved.
        if interleaved.len() != n * FIELD_CHANNELS {
            godot_error!("FieldGpu: readback len {} != expected {}", interleaved.len(), n * FIELD_CHANNELS);
            return None;
        }
        let mut heights = PackedFloat32Array::new();
        let mut temp = PackedFloat32Array::new();
        let mut moisture = PackedFloat32Array::new();
        let mut biome = PackedFloat32Array::new();
        let mut normal_x = PackedFloat32Array::new();
        let mut normal_z = PackedFloat32Array::new();
        heights.resize(n);
        temp.resize(n);
        moisture.resize(n);
        biome.resize(n);
        normal_x.resize(n);
        normal_z.resize(n);
        let src = interleaved.as_slice();
        let h = heights.as_mut_slice();
        let t = temp.as_mut_slice();
        let m = moisture.as_mut_slice();
        let bm = biome.as_mut_slice();
        let nx = normal_x.as_mut_slice();
        let nz = normal_z.as_mut_slice();
        for i in 0..n {
            let b = i * FIELD_CHANNELS;
            h[i] = src[b];
            t[i] = src[b + 1];
            m[i] = src[b + 2];
            bm[i] = src[b + 3];
            nx[i] = src[b + 4];
            nz[i] = src[b + 5];
        }
        Some(FieldPage { heights, temp, moisture, biome, normal_x, normal_z })
    }
}

/// Load GLSL from a res:// path, stripping Godot's leading `#[stage]` marker
/// lines (not valid GLSL — `set_stage_source` wants raw GLSL for the stage).
fn load_glsl(path: &GString) -> GString {
    use godot::classes::file_access::ModeFlags;
    use godot::classes::FileAccess;
    let Some(f) = FileAccess::open(path, ModeFlags::READ) else {
        godot_error!("FieldGpu: cannot open shader {}", path);
        return GString::new();
    };
    let raw = f.get_as_text().to_string();
    let cleaned: String = raw
        .lines()
        .filter(|l| !l.trim_start().starts_with("#["))
        .collect::<Vec<_>>()
        .join("\n");
    GString::from(cleaned.as_str())
}
