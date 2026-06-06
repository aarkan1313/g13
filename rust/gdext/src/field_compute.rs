//! `FieldCompute` — the test oracle for the GPU field (M1.2/M1.4 gates).
//!
//! A thin Godot-callable wrapper over `field_gpu::FieldGpu`: produce a page and
//! return its heights (or an R32F texture). Used by determinism/continuity/seam
//! tests. The runtime uses `PagePool` (also over `FieldGpu`); both share the one
//! GPU-dispatch implementation, so there is no duplicated field code (00 §4).

use crate::field_gpu::{FieldGpu, PageParams};
use godot::classes::image::Format;
use godot::classes::{Image, ImageTexture};
use godot::prelude::*;

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
    /// Create the local RD + compile the field shader. Returns true on success.
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        self.gpu.is_some()
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
        gpu.dispatch_page(PageParams {
            origin_x, origin_z, spacing, seed,
            page_res: page_res as u32, octaves: octaves as u32, base_freq, amplitude,
        }).unwrap_or_default()
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
