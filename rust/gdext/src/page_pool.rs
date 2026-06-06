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

use crate::field_gpu::{FieldGpu, PageParams};
use godot::classes::image::Format;
use godot::classes::{Image, ImageTexture};
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
    gpu: Option<FieldGpu>,
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
            gpu: None,
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
    /// Compile the field shader on a local RD (shared FieldGpu machinery).
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        self.gpu.is_some()
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

    /// Produce one page on the GPU (via shared FieldGpu) and pack it R32F.
    /// Coarser levels stretch origin stride AND spacing by 2^level, so a coarse
    /// page covers more world at the same resolution (the clipmap blanket).
    fn produce(&mut self, key: PageKey) -> Option<Gd<ImageTexture>> {
        let scale = (1 << key.level.max(0)) as f32;
        let span = self.page_span() * scale;
        let params = PageParams {
            origin_x: key.gx as f32 * span,
            origin_z: key.gz as f32 * span,
            spacing: self.cfg.spacing * scale,
            seed: self.cfg.seed,
            page_res: self.cfg.page_res,
            octaves: self.cfg.octaves,
            base_freq: self.cfg.base_freq,
            amplitude: self.cfg.amplitude,
        };
        let heights = self.gpu.as_mut()?.dispatch_page(params)?;
        let res = self.cfg.page_res as i32;
        let bytes = heights.to_byte_array();
        let img = Image::create_from_data(res, res, false, Format::RF, &bytes)?;
        ImageTexture::create_from_image(&img)
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
