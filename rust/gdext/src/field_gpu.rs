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

/// Parameters for one page production. Mirrors the GLSL `Params` block layout:
/// 8 × 4 bytes = 32 bytes, std430-friendly (4 floats, 2 uints, 2 floats).
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
}

impl PageParams {
    fn to_bytes(&self) -> PackedByteArray {
        let mut v: Vec<u8> = Vec::with_capacity(32);
        v.extend_from_slice(&self.origin_x.to_le_bytes());
        v.extend_from_slice(&self.origin_z.to_le_bytes());
        v.extend_from_slice(&self.spacing.to_le_bytes());
        v.extend_from_slice(&self.seed.to_le_bytes());
        v.extend_from_slice(&self.page_res.to_le_bytes());
        v.extend_from_slice(&self.octaves.to_le_bytes());
        v.extend_from_slice(&self.base_freq.to_le_bytes());
        v.extend_from_slice(&self.amplitude.to_le_bytes());
        PackedByteArray::from(v.as_slice())
    }
}

/// A compiled field-compute pipeline on a dedicated local RenderingDevice.
/// Create once with `new`, then `dispatch_page` per page.
pub struct FieldGpu {
    rd: Gd<RenderingDevice>,
    shader: Rid,
    pipeline: Rid,
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
        Some(Self { rd, shader, pipeline })
    }

    /// Dispatch the field over one page and read the heights back to the CPU.
    /// Returns PAGE_RES*PAGE_RES floats, row-major (z * page_res + x).
    pub fn dispatch_page(&mut self, params: PageParams) -> Option<PackedFloat32Array> {
        let res = params.page_res;
        let n = (res * res) as usize;

        let out_bytes = PackedByteArray::from(vec![0u8; n * 4]);
        let out_buf = self.rd.storage_buffer_create_ex(out_bytes.len() as u32).data(&out_bytes).done();
        let pbytes = params.to_bytes();
        let param_buf = self.rd.storage_buffer_create_ex(pbytes.len() as u32).data(&pbytes).done();

        let mut u_out = RdUniform::new_gd();
        u_out.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_out.set_binding(0);
        u_out.add_id(out_buf);
        let mut u_param = RdUniform::new_gd();
        u_param.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_param.set_binding(1);
        u_param.add_id(param_buf);

        let uniforms = array![&u_out, &u_param];
        let uniform_set = self.rd.uniform_set_create(&uniforms, self.shader, 0);

        let groups = (res + 7) / 8;
        let cl = self.rd.compute_list_begin();
        self.rd.compute_list_bind_compute_pipeline(cl, self.pipeline);
        self.rd.compute_list_bind_uniform_set(cl, uniform_set, 0);
        self.rd.compute_list_dispatch(cl, groups, groups, 1);
        self.rd.compute_list_end();
        self.rd.submit();
        self.rd.sync();

        let result = self.rd.buffer_get_data(out_buf).to_float32_array();
        self.rd.free_rid(uniform_set);
        self.rd.free_rid(out_buf);
        self.rd.free_rid(param_buf);
        Some(result)
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
