//! M1.2 — GPU field producer + readback (the first real GPU step).
//!
//! Per 00_ARCHITECTURE §2.1/§3/§4: the world math is GLSL (source of truth);
//! Rust dispatches it on a LOCAL RenderingDevice and reads the result back for
//! the determinism/continuity test gates. There is no CPU copy of the math.
//!
//! `FieldCompute` is a Godot-callable object. A headless `_check.gd` (or a
//! future Rust harness) calls `produce_page(...)` and asserts on the returned
//! heights — that's how we self-certify M1.2 from output (02_WORKFLOW §2).

use godot::classes::rendering_device::UniformType;
use godot::classes::{
    RdShaderSource, RdUniform, RenderingDevice, RenderingServer,
};
use godot::prelude::*;

/// Parameters for one page production. Mirrors the GLSL `Params` block layout.
/// 8 x 4 bytes = 32 bytes, std430-friendly (floats then uints, all 4-byte).
struct PageParams {
    origin_x: f32,
    origin_z: f32,
    spacing: f32,
    seed: f32,
    page_res: u32,
    octaves: u32,
    base_freq: f32,
    amplitude: f32,
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

/// GPU field producer on a dedicated local RenderingDevice.
#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct FieldCompute {
    base: Base<RefCounted>,
    rd: Option<Gd<RenderingDevice>>,
    shader: Rid,
    pipeline: Rid,
}

#[godot_api]
impl IRefCounted for FieldCompute {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            rd: None,
            shader: Rid::Invalid,
            pipeline: Rid::Invalid,
        }
    }
}

#[godot_api]
impl FieldCompute {
    /// Create the local RenderingDevice, compile the field shader, build the
    /// compute pipeline. Returns true on success. Idempotent-ish: call once.
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        let mut server = RenderingServer::singleton();
        // 0.5.3: returns the local RenderingDevice object directly (dedicated,
        // off the main render device — ideal for off-frame readback later).
        let Some(mut rd) = server.create_local_rendering_device() else {
            godot_error!("FieldCompute: no local RenderingDevice (no GPU?).");
            return false;
        };

        let src = load_glsl(&shader_glsl_path);
        let mut shader_source = RdShaderSource::new_gd();
        shader_source.set_language(godot::classes::rendering_device::ShaderLanguage::GLSL);
        shader_source.set_stage_source(
            godot::classes::rendering_device::ShaderStage::COMPUTE,
            &src,
        );

        let spirv = rd.shader_compile_spirv_from_source(&shader_source);
        let Some(spirv) = spirv else {
            godot_error!("FieldCompute: SPIR-V compile returned null.");
            return false;
        };
        if !spirv.get_stage_compile_error(godot::classes::rendering_device::ShaderStage::COMPUTE).is_empty() {
            godot_error!(
                "FieldCompute: shader compile error: {}",
                spirv.get_stage_compile_error(godot::classes::rendering_device::ShaderStage::COMPUTE)
            );
            return false;
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        let pipeline = rd.compute_pipeline_create(shader);

        self.rd = Some(rd);
        self.shader = shader;
        self.pipeline = pipeline;
        true
    }

    /// Produce one page; return PAGE_RES*PAGE_RES heights row-major.
    #[func]
    fn produce_page(
        &mut self,
        origin_x: f32,
        origin_z: f32,
        spacing: f32,
        seed: f32,
        page_res: i64,
        octaves: i64,
        base_freq: f32,
        amplitude: f32,
    ) -> PackedFloat32Array {
        let Some(rd) = self.rd.as_mut() else {
            godot_error!("FieldCompute: not initialized.");
            return PackedFloat32Array::new();
        };
        let page_res = page_res as u32;
        let n = (page_res * page_res) as usize;

        // Output storage buffer (n floats).
        let out_bytes = PackedByteArray::from(vec![0u8; n * 4]);
        let out_buf = rd.storage_buffer_create_ex(out_bytes.len() as u32)
            .data(&out_bytes)
            .done();

        // Params storage buffer.
        let params = PageParams {
            origin_x, origin_z, spacing, seed,
            page_res, octaves: octaves as u32, base_freq, amplitude,
        };
        let pbytes = params.to_bytes();
        let param_buf = rd.storage_buffer_create_ex(pbytes.len() as u32)
            .data(&pbytes)
            .done();

        // Uniform set: binding 0 = heights, binding 1 = params.
        let mut u_out = RdUniform::new_gd();
        u_out.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_out.set_binding(0);
        u_out.add_id(out_buf);

        let mut u_param = RdUniform::new_gd();
        u_param.set_uniform_type(UniformType::STORAGE_BUFFER);
        u_param.set_binding(1);
        u_param.add_id(param_buf);

        let uniforms = array![&u_out, &u_param];
        let uniform_set = rd.uniform_set_create(&uniforms, self.shader, 0);

        // Dispatch: ceil(page_res/8) groups in x and y.
        let groups = (page_res + 7) / 8;
        let cl = rd.compute_list_begin();
        rd.compute_list_bind_compute_pipeline(cl, self.pipeline);
        rd.compute_list_bind_uniform_set(cl, uniform_set, 0);
        rd.compute_list_dispatch(cl, groups, groups, 1);
        rd.compute_list_end();
        rd.submit();
        rd.sync();

        // Read back.
        let result_bytes = rd.buffer_get_data(out_buf);
        let heights = result_bytes.to_float32_array();

        // Clean up per-call buffers (keep shader/pipeline).
        rd.free_rid(uniform_set);
        rd.free_rid(out_buf);
        rd.free_rid(param_buf);

        heights
    }
}

/// Load GLSL source from a res:// path via Godot's FileAccess.
///
/// The `.glsl` files use Godot's convention of a leading `#[compute]` stage
/// marker. That marker is NOT valid GLSL — `RDShaderSource::set_stage_source`
/// wants raw GLSL for the stage — so we strip any leading `#[stage]` lines.
fn load_glsl(path: &GString) -> GString {
    use godot::classes::FileAccess;
    use godot::classes::file_access::ModeFlags;
    let Some(f) = FileAccess::open(path, ModeFlags::READ) else {
        godot_error!("FieldCompute: cannot open shader {}", path);
        return GString::new();
    };
    let raw = f.get_as_text().to_string();
    let cleaned: String = raw
        .lines()
        .filter(|l| !l.trim_start().starts_with("#[") )
        .collect::<Vec<_>>()
        .join("\n");
    GString::from(cleaned.as_str())
}
