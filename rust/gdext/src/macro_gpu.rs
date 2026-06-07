//! M2.4c step-2 GPU bridge helpers: create + sample R32F textures on a LOCAL
//! RenderingDevice (the same kind FieldGpu owns). Approach C bakes a macro
//! structure layer off-frame and uploads it as an R32_SFLOAT texture that the
//! field compute shader samples with hardware bilinear filtering. This module
//! pins the exact gdext 0.5.3 API for that, proven by `macro_roundtrip_probe`.
//!
//! VERIFIED gdext 0.5.3 signatures (godot-core 0.5.3, read from the generated
//! `out/classes/*.rs`, not assumed):
//!   RenderingDevice::texture_create(&fmt, &view) -> Rid          (data via _ex builder)
//!   RenderingDevice::texture_create_ex(&fmt, &view).data(&Array<PackedByteArray>).done() -> Rid
//!   RenderingDevice::sampler_create(&RdSamplerState) -> Rid
//!   RdTextureFormat::{set_width,set_height,set_format,set_usage_bits}  (set_usage_bits takes TextureUsageBits)
//!   RdSamplerState::{set_min_filter,set_mag_filter(SamplerFilter), set_repeat_u,set_repeat_v(SamplerRepeatMode)}
//!   DataFormat::R32_SFLOAT, SamplerFilter::LINEAR, SamplerRepeatMode::CLAMP_TO_EDGE,
//!   TextureUsageBits::SAMPLING_BIT | CAN_UPDATE_BIT (BitOr is impl'd),
//!   UniformType::SAMPLER_WITH_TEXTURE  (uniform: add_id(sampler) THEN add_id(texture)).
//! The texture data array MUST be a typed `Array<PackedByteArray>` (use `array!`,
//! NOT `varray!` which is untyped) — one layer for a 2D texture.

use godot::classes::rendering_device::{DataFormat, SamplerFilter, SamplerRepeatMode, TextureUsageBits};
use godot::classes::{RdSamplerState, RdTextureFormat, RdTextureView, RenderingDevice};
use godot::prelude::*;

use crate::macro_cache::RegionMacro;

/// Create a CLAMP_TO_EDGE, LINEAR (min+mag) sampler on the given local RD.
/// Returns its Rid (caller frees with `rd.free_rid`).
pub fn linear_sampler(rd: &mut Gd<RenderingDevice>) -> Rid {
    let mut st = RdSamplerState::new_gd();
    st.set_min_filter(SamplerFilter::LINEAR);
    st.set_mag_filter(SamplerFilter::LINEAR);
    st.set_repeat_u(SamplerRepeatMode::CLAMP_TO_EDGE);
    st.set_repeat_v(SamplerRepeatMode::CLAMP_TO_EDGE);
    rd.sampler_create(&st)
}

/// Create a 2D R32_SFLOAT texture (SAMPLING | CAN_UPDATE) on the given local RD,
/// uploading `data` (width*height f32, row-major) as one LE-byte layer. Returns
/// its Rid (caller frees with `rd.free_rid`).
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
    // Typed Array<PackedByteArray> with one layer (2D texture). `array!` is the
    // typed-array macro; `varray!` would produce an untyped VarArray (wrong type).
    let layers = array![&bytes];
    rd.texture_create_ex(&fmt, &view).data(&layers).done()
}

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
