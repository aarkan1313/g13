//! M2.6 GPU-resident RENDER producer. Runs the SAME field GLSL
//! (wg-13/shaders/field_height.glsl) but with `#define RENDER_MODE`, on the MAIN
//! RenderingDevice, writing height/climate/biome/normal into storage IMAGES that
//! the display shader samples directly via Texture2DRD — NO sync, NO readback, NO
//! re-upload. This is the render path; the local-device `field_gpu` readback path
//! still feeds COLLISION (M1.7). One world-math source (the shared GLSL).
//!
//! Proven by the M2.6 spikes: main-device compute needs NO submit()/sync()
//! (auto-barriers order compute->draw); Texture2DRD samples in both fragment and
//! vertex stages. RD textures are NOT ref-counted — the pool must free the RIDs on
//! evict (Stage 3) or VRAM leaks.

use godot::classes::rendering_device::{
    DataFormat, ShaderLanguage, ShaderStage, TextureType, TextureUsageBits, UniformType,
};
use godot::classes::{
    RdShaderSource, RdTextureFormat, RdTextureView, RdUniform, RenderingDevice, RenderingServer,
};
use godot::prelude::*;

use crate::field_gpu::PageParams;

/// The four render textures a page produces, as MAIN-device RD texture RIDs.
/// RAII: frees the RIDs on Drop (RD textures are NOT ref-counted). The pool keeps
/// this alive for as long as the page is resident; dropping it (page evicted) frees
/// the GPU textures. The pool MUST ensure no material still references the page's
/// Texture2DRD when this drops (world_view clears recycled materials' textures).
pub struct RenderTextures {
    pub height: Rid,   // R32F  — vertex displacement
    pub climate: Rid,  // RG32F — temperature, moisture
    pub biome: Rid,    // R32F  — biome id (float-encoded)
    pub normal: Rid,   // RG32F — normal_x, normal_z (seam-free analytic gradient)
}

impl Drop for RenderTextures {
    fn drop(&mut self) {
        // Free on the MAIN device. Acquire it here so lifetime == this struct's.
        if let Some(mut rd) = RenderingServer::singleton().get_rendering_device() {
            for rid in [self.height, self.climate, self.biome, self.normal] {
                if rid != Rid::Invalid {
                    rd.free_rid(rid);
                }
            }
        }
    }
}

/// Owns the MAIN RenderingDevice handle + the RENDER_MODE field pipeline.
pub struct RenderGpu {
    rd: Gd<RenderingDevice>,
    shader: Rid,
    pipeline: Rid,
    /// M2.2 biome centroid table bytes (binding 2), same data the local path uses.
    biome_bytes: PackedByteArray,
}

impl RenderGpu {
    /// Compile the field shader in RENDER_MODE on the MAIN device. Returns None if
    /// there is no main device (headless/OpenGL) or the shader fails to compile.
    /// `field_glsl_path` is the same res:// path the local path uses.
    pub fn new(field_glsl_path: &GString, biome_bytes: PackedByteArray) -> Option<Self> {
        let mut rd = RenderingServer::singleton().get_rendering_device()?;
        // Read the shared field GLSL and inject `#define RENDER_MODE` right after the
        // `#version` line (GLSL requires #version first). Strip the `#[compute]`
        // marker like load_glsl does.
        let src_text = read_render_glsl(field_glsl_path)?;
        let mut src = RdShaderSource::new_gd();
        src.set_language(ShaderLanguage::GLSL);
        src.set_stage_source(ShaderStage::COMPUTE, &src_text);
        let spirv = rd.shader_compile_spirv_from_source(&src)?;
        let err = spirv.get_stage_compile_error(ShaderStage::COMPUTE);
        if !err.is_empty() {
            godot_error!("RenderGpu: RENDER_MODE shader compile error: {}", err);
            return None;
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        let pipeline = rd.compute_pipeline_create(shader);
        Some(Self { rd, shader, pipeline, biome_bytes })
    }

    /// Update the biome centroid table (binding 2) to match the local path.
    pub fn set_biome_bytes(&mut self, biome_bytes: PackedByteArray) {
        if !biome_bytes.is_empty() {
            self.biome_bytes = biome_bytes;
        }
    }

    /// Create an R32F or RG32F render texture (sampleable + storage-writable) on the
    /// main device. `channels` = 1 (R32F) or 2 (RG32F).
    fn make_texture(&mut self, res: i32, channels: i32) -> Rid {
        let mut tf = RdTextureFormat::new_gd();
        tf.set_format(if channels == 1 {
            DataFormat::R32_SFLOAT
        } else {
            DataFormat::R32G32_SFLOAT
        });
        tf.set_texture_type(TextureType::TYPE_2D);
        tf.set_width(res as u32);
        tf.set_height(res as u32);
        tf.set_depth(1);
        tf.set_array_layers(1);
        tf.set_mipmaps(1);
        tf.set_usage_bits(
            TextureUsageBits::SAMPLING_BIT
                | TextureUsageBits::STORAGE_BIT
                | TextureUsageBits::CAN_COPY_TO_BIT,
        );
        let view = RdTextureView::new_gd();
        self.rd.texture_create(&tf, &view)
    }

    /// Produce one page's render textures on the GPU (no readback). Returns the four
    /// RD texture RIDs. Caller owns them (wrap in Texture2DRD; free on evict).
    pub fn produce(&mut self, params: PageParams) -> Option<RenderTextures> {
        let res = params.page_res as i32;
        let height = self.make_texture(res, 1);
        let climate = self.make_texture(res, 2);
        let biome = self.make_texture(res, 1);
        let normal = self.make_texture(res, 2);

        // params + biome table buffers (bindings 1 and 2; binding 0,3,4,5 = images).
        let pbytes = params.to_bytes();
        let param_buf = self.rd.storage_buffer_create_ex(pbytes.len() as u32).data(&pbytes).done();
        let biome_buf = self
            .rd
            .storage_buffer_create_ex(self.biome_bytes.len() as u32)
            .data(&self.biome_bytes)
            .done();

        let u_h = image_uniform(0, height);
        let u_p = buffer_uniform(1, param_buf);
        let u_b = buffer_uniform(2, biome_buf);
        let u_c = image_uniform(3, climate);
        let u_bi = image_uniform(4, biome);
        let u_n = image_uniform(5, normal);
        let uniform_set = self.rd.uniform_set_create(
            &array![&u_h, &u_p, &u_b, &u_c, &u_bi, &u_n],
            self.shader,
            0,
        );

        let groups = ((res + 7) / 8) as u32;
        let cl = self.rd.compute_list_begin();
        self.rd.compute_list_bind_compute_pipeline(cl, self.pipeline);
        self.rd.compute_list_bind_uniform_set(cl, uniform_set, 0);
        self.rd.compute_list_dispatch(cl, groups, groups, 1);
        self.rd.compute_list_end();
        // MAIN device: NO submit()/sync(). Auto-barriers order compute->draw (spike-proven).

        // Free the transient uniform set + param/biome buffers (the textures stay).
        self.rd.free_rid(uniform_set);
        self.rd.free_rid(param_buf);
        self.rd.free_rid(biome_buf);

        Some(RenderTextures { height, climate, biome, normal })
    }
}

fn image_uniform(binding: i32, rid: Rid) -> Gd<RdUniform> {
    let mut u = RdUniform::new_gd();
    u.set_uniform_type(UniformType::IMAGE);
    u.set_binding(binding);
    u.add_id(rid);
    u
}

fn buffer_uniform(binding: i32, rid: Rid) -> Gd<RdUniform> {
    let mut u = RdUniform::new_gd();
    u.set_uniform_type(UniformType::STORAGE_BUFFER);
    u.set_binding(binding);
    u.add_id(rid);
    u
}

/// Read the field GLSL, strip the `#[compute]` marker, and inject `#define
/// RENDER_MODE` immediately after the `#version` line so the render variant compiles.
fn read_render_glsl(path: &GString) -> Option<GString> {
    use godot::classes::file_access::ModeFlags;
    use godot::classes::FileAccess;
    let f = FileAccess::open(path, ModeFlags::READ)?;
    let raw = f.get_as_text().to_string();
    let mut out = String::with_capacity(raw.len() + 32);
    let mut injected = false;
    for line in raw.lines() {
        if line.trim_start().starts_with("#[") {
            continue; // strip Godot's #[compute] marker (not valid GLSL)
        }
        out.push_str(line);
        out.push('\n');
        if !injected && line.trim_start().starts_with("#version") {
            out.push_str("#define RENDER_MODE\n");
            injected = true;
        }
    }
    if !injected {
        godot_error!("RenderGpu: no #version line found in field GLSL");
        return None;
    }
    Some(GString::from(out.as_str()))
}
