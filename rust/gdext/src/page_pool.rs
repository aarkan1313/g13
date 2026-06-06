//! M1.5 — bounded page pool (the heart of the streaming runtime).
//!
//! Owns the GPU field production and a cache of produced page textures keyed by
//! (level, gx, gz). Per 00_ARCHITECTURE §4 this is Rust: deterministic policy +
//! residency. The GLSL field stays the source of truth; the pool just schedules
//! and caches its output. Per 00 §1.1 ("build it right once") this is the real
//! pool from the start, delivered in gated sub-steps — not a GDScript prototype.
//!
//! M1.5a scope: caching + bounded production per frame + grid-index page keys
//! using the shared-boundary-cell convention (00 §5.1). Streaming/rings come in
//! M1.5b/c on top of this.

use std::collections::HashMap;

use godot::classes::rendering_device::UniformType;
use godot::classes::{
    Image, ImageTexture, RdShaderSource, RdUniform, RenderingDevice, RenderingServer,
};
use godot::classes::image::Format;
use godot::prelude::*;

/// Identifies a page in the world: ring level + integer grid coordinates.
/// Level 0 is finest; each coarser level doubles world span per page (M1.5c).
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct PageKey {
    level: i32,
    gx: i32,
    gz: i32,
}

/// fBM + page geometry config. Mirrors the GLSL Params block (page_pool dispatches
/// the same field_height.glsl the M1.2/M1.3 path used).
#[derive(Clone, Copy)]
struct FieldConfig {
    page_res: u32,
    spacing: f32,
    seed: f32,
    octaves: u32,
    base_freq: f32,
    amplitude: f32,
}

impl Default for FieldConfig {
    fn default() -> Self {
        Self { page_res: 128, spacing: 4.0, seed: 1234.0, octaves: 5, base_freq: 0.0015, amplitude: 240.0 }
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct PagePool {
    base: Base<RefCounted>,
    rd: Option<Gd<RenderingDevice>>,
    shader: Rid,
    pipeline: Rid,
    cfg: FieldConfig,

    cache: HashMap<PageKey, Gd<ImageTexture>>,
    /// Pages currently displayed — must NOT be evicted out from under the mesh
    /// (00 §3 never-black discipline). Rebuilt each frame by the view.
    pinned: std::collections::HashSet<PageKey>,
    /// Bounded production: at most this many NEW pages produced per frame.
    max_new_per_frame: i32,
    produced_this_frame: i32,
    /// Counters for tests/diagnostics.
    total_produced: i64,
    cache_hits: i64,
    evicted: i64,
    /// Set true if an eviction of a pinned page was ever attempted (test guard).
    pin_violation: bool,
}

#[godot_api]
impl IRefCounted for PagePool {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            rd: None,
            shader: Rid::Invalid,
            pipeline: Rid::Invalid,
            cfg: FieldConfig::default(),
            cache: HashMap::new(),
            pinned: std::collections::HashSet::new(),
            max_new_per_frame: 4,
            produced_this_frame: 0,
            total_produced: 0,
            cache_hits: 0,
            evicted: 0,
            pin_violation: false,
        }
    }
}

#[godot_api]
impl PagePool {
    /// Compile the field shader and build the compute pipeline on a local RD.
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        let server = RenderingServer::singleton();
        let Some(mut rd) = server.create_local_rendering_device() else {
            godot_error!("PagePool: no local RenderingDevice (need --rendering-driver vulkan).");
            return false;
        };
        let src = load_glsl(&shader_glsl_path);
        let mut shader_source = RdShaderSource::new_gd();
        shader_source.set_language(godot::classes::rendering_device::ShaderLanguage::GLSL);
        shader_source.set_stage_source(godot::classes::rendering_device::ShaderStage::COMPUTE, &src);
        let Some(spirv) = rd.shader_compile_spirv_from_source(&shader_source) else {
            godot_error!("PagePool: SPIR-V compile returned null."); return false;
        };
        let err = spirv.get_stage_compile_error(godot::classes::rendering_device::ShaderStage::COMPUTE);
        if !err.is_empty() {
            godot_error!("PagePool: shader compile error: {}", err); return false;
        }
        let shader = rd.shader_create_from_spirv(&spirv);
        let pipeline = rd.compute_pipeline_create(shader);
        self.rd = Some(rd);
        self.shader = shader;
        self.pipeline = pipeline;
        true
    }

    /// Configure field params (tunable from GDScript / inspector).
    #[func]
    fn configure(&mut self, page_res: i64, spacing: f32, seed: f32, octaves: i64,
                 base_freq: f32, amplitude: f32, max_new_per_frame: i64) {
        self.cfg = FieldConfig {
            page_res: page_res as u32, spacing, seed,
            octaves: octaves as u32, base_freq, amplitude,
        };
        self.max_new_per_frame = max_new_per_frame as i32;
    }

    /// World span one page covers (shared-boundary-cell convention, 00 §5.1).
    #[func]
    fn page_span(&self) -> f32 {
        (self.cfg.page_res as f32 - 1.0) * self.cfg.spacing
    }

    /// Reset the per-frame production budget and clear display pins. Call once
    /// at the top of each frame; the view then re-pins everything it displays.
    #[func]
    fn begin_frame(&mut self) {
        self.produced_this_frame = 0;
        self.pinned.clear();
    }

    /// Mark a page as displayed this frame (cannot be evicted). The view calls
    /// this for every page it currently has a mesh for.
    #[func]
    fn pin_page(&mut self, level: i64, gx: i64, gz: i64) {
        self.pinned.insert(PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 });
    }

    /// Evict cached pages whose grid distance from (center_gx, center_gz) at the
    /// given level exceeds `keep_radius` (Chebyshev). Pinned pages are NEVER
    /// evicted (never-black discipline). Returns how many were evicted.
    #[func]
    fn evict_outside(&mut self, level: i64, center_gx: i64, center_gz: i64, keep_radius: i64) -> i64 {
        let level = level as i32;
        let cgx = center_gx as i32;
        let cgz = center_gz as i32;
        let r = keep_radius as i32;
        let pinned = &self.pinned;
        let mut removed = 0i64;
        let mut violated = false;
        self.cache.retain(|k, _| {
            if k.level != level {
                return true; // only manage the requested level here
            }
            let cheb = (k.gx - cgx).abs().max((k.gz - cgz).abs());
            if cheb <= r {
                return true; // within keep radius
            }
            if pinned.contains(k) {
                violated = true; // asked to drop a displayed page — refuse, flag it
                return true;
            }
            removed += 1;
            false
        });
        if violated {
            self.pin_violation = true;
        }
        self.evicted += removed;
        removed
    }

    /// Request a page. Returns its texture if resident, or if we can afford to
    /// produce it this frame (under the budget). Returns null when over budget
    /// and not yet cached — the caller then shows coarser coverage (M1.5c).
    #[func]
    fn request_page(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<ImageTexture>> {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        if let Some(tex) = self.cache.get(&key) {
            self.cache_hits += 1;
            return Some(tex.clone());
        }
        if self.produced_this_frame >= self.max_new_per_frame {
            return None; // over budget this frame; caller falls back to coarse
        }
        let tex = self.produce(key)?;
        self.produced_this_frame += 1;
        self.total_produced += 1;
        self.cache.insert(key, tex.clone());
        Some(tex)
    }

    /// World origin of a page (level scales span by 2^level — M1.5c uses levels).
    fn page_origin(&self, key: PageKey) -> (f32, f32) {
        let span = self.page_span() * (1 << key.level.max(0)) as f32;
        (key.gx as f32 * span, key.gz as f32 * span)
    }

    /// Produce one page on the GPU and pack it into an R32F ImageTexture.
    fn produce(&mut self, key: PageKey) -> Option<Gd<ImageTexture>> {
        let (ox, oz) = self.page_origin(key);
        // Coarser levels stretch spacing so a page covers more world at lower res.
        let spacing = self.cfg.spacing * (1 << key.level.max(0)) as f32;
        let heights = self.dispatch(ox, oz, spacing)?;
        let res = self.cfg.page_res as i32;
        let bytes = heights.to_byte_array();
        let img = Image::create_from_data(res, res, false, Format::RF, &bytes)?;
        ImageTexture::create_from_image(&img)
    }

    /// GPU dispatch + readback for one page at a world origin & spacing.
    fn dispatch(&mut self, origin_x: f32, origin_z: f32, spacing: f32) -> Option<PackedFloat32Array> {
        let rd = self.rd.as_mut()?;
        let res = self.cfg.page_res;
        let n = (res * res) as usize;

        let out_bytes = PackedByteArray::from(vec![0u8; n * 4]);
        let out_buf = rd.storage_buffer_create_ex(out_bytes.len() as u32).data(&out_bytes).done();

        let mut pv: Vec<u8> = Vec::with_capacity(32);
        pv.extend_from_slice(&origin_x.to_le_bytes());
        pv.extend_from_slice(&origin_z.to_le_bytes());
        pv.extend_from_slice(&spacing.to_le_bytes());
        pv.extend_from_slice(&self.cfg.seed.to_le_bytes());
        pv.extend_from_slice(&res.to_le_bytes());
        pv.extend_from_slice(&self.cfg.octaves.to_le_bytes());
        pv.extend_from_slice(&self.cfg.base_freq.to_le_bytes());
        pv.extend_from_slice(&self.cfg.amplitude.to_le_bytes());
        let pbytes = PackedByteArray::from(pv.as_slice());
        let param_buf = rd.storage_buffer_create_ex(pbytes.len() as u32).data(&pbytes).done();

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

        let groups = (res + 7) / 8;
        let cl = rd.compute_list_begin();
        rd.compute_list_bind_compute_pipeline(cl, self.pipeline);
        rd.compute_list_bind_uniform_set(cl, uniform_set, 0);
        rd.compute_list_dispatch(cl, groups, groups, 1);
        rd.compute_list_end();
        rd.submit();
        rd.sync();

        let result = rd.buffer_get_data(out_buf).to_float32_array();
        rd.free_rid(uniform_set);
        rd.free_rid(out_buf);
        rd.free_rid(param_buf);
        Some(result)
    }

    /// Grid index of the level-0 page containing a world X (or Z) coordinate.
    /// Uses the shared-boundary-cell span so it matches page_origin/keys.
    #[func]
    fn world_to_page_index(&self, world_coord: f32) -> i64 {
        let span = self.page_span();
        (world_coord / span).floor() as i64
    }

    // --- diagnostics / test introspection ---
    #[func] fn resident_count(&self) -> i64 { self.cache.len() as i64 }
    #[func] fn total_produced(&self) -> i64 { self.total_produced }
    #[func] fn cache_hits(&self) -> i64 { self.cache_hits }
    #[func] fn produced_this_frame(&self) -> i64 { self.produced_this_frame as i64 }
    #[func] fn evicted_count(&self) -> i64 { self.evicted }
    #[func] fn pinned_count(&self) -> i64 { self.pinned.len() as i64 }
    #[func] fn had_pin_violation(&self) -> bool { self.pin_violation }
}

fn load_glsl(path: &GString) -> GString {
    use godot::classes::FileAccess;
    use godot::classes::file_access::ModeFlags;
    let Some(f) = FileAccess::open(path, ModeFlags::READ) else {
        godot_error!("PagePool: cannot open shader {}", path);
        return GString::new();
    };
    let raw = f.get_as_text().to_string();
    let cleaned: String = raw.lines().filter(|l| !l.trim_start().starts_with("#[")).collect::<Vec<_>>().join("\n");
    GString::from(cleaned.as_str())
}
