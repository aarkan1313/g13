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

/// A resident page: the displayed texture AND the CPU height array it was packed
/// from. ONE production fills both, so collision (which reads `heights`) and the
/// view (which displaces `texture`) can never disagree — the M1.7 contract
/// ("collision reads the same resident page heights the view uses, never a second
/// field path", 00 §2.2 / MILESTONE_1 M1.7). They cache and evict together.
struct ResidentPage {
    texture: Gd<ImageTexture>,
    heights: PackedFloat32Array,
}

/// How a page request is budgeted this frame (M1.9.3b).
#[derive(Clone, Copy)]
enum RequestMode {
    Fine,            // finest level — bounded by max_new_per_frame
    EagerBounded,    // mid-coarse — bounded by max_eager_per_frame, falls back to coarser
    EagerUnbounded,  // coarsest — never gated (the never-black floor)
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

    cache: HashMap<PageKey, ResidentPage>,
    /// Pages currently displayed — must NOT be evicted out from under the mesh
    /// (00 §3 never-black discipline). Rebuilt each frame by the view.
    pinned: std::collections::HashSet<PageKey>,
    /// Bounded production: at most this many NEW FINE pages produced per frame.
    /// (Coarse/eager production is intentionally unbounded — see request().)
    max_new_per_frame: i32,
    produced_this_frame: i32,
    eager_this_frame: i32,  // diagnostics: eager pages produced this frame
    /// M1.9.3b: per-frame cap for MID-coarse eager production (levels between
    /// fine and coarsest). The COARSEST level stays unbounded (the never-black
    /// backstop); mid-coarse can be spread over frames because a missing
    /// mid-coarse page falls back to the coarser blanket beneath it (NOT to
    /// black). This bounds the fast-motion eager burst without starving the
    /// floor. <= 0 means "unbounded" (spreading off).
    max_eager_per_frame: i32,
    eager_bounded_this_frame: i32,
    /// M1.9 profiling: wall-time spent in produce() this frame (GPU dispatch +
    /// blocking readback). This is the prime suspect for the fast-motion frame
    /// spike — each production blocks on rd.sync(). Reset in begin_frame().
    produce_us_this_frame: i64,
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
            eager_this_frame: 0,
            max_eager_per_frame: 8,   // mid-coarse pages/frame; coarsest is exempt
            eager_bounded_this_frame: 0,
            produce_us_this_frame: 0,
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

    /// M1.9.3b: per-frame cap for MID-coarse eager pages (the coarsest level
    /// stays unbounded). <= 0 disables spreading (unbounded mid-coarse too).
    #[func]
    fn set_max_eager_per_frame(&mut self, n: i64) {
        self.max_eager_per_frame = n as i32;
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
        self.eager_this_frame = 0;
        self.eager_bounded_this_frame = 0;
        self.produce_us_this_frame = 0;
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

    /// Request a page, BOUNDED by the per-frame budget. Returns its texture if
    /// resident or affordable this frame; null when over budget and not cached
    /// (caller falls back to coarse coverage). Use for the expensive FINE level.
    #[func]
    fn request_page(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<ImageTexture>> {
        self.request(level, gx, gz, RequestMode::Fine)
    }

    /// Request a page EAGERLY, UNBOUNDED. Use for the COARSEST level — the
    /// never-black backstop, which must ALWAYS be complete so a hole in finer
    /// levels never reveals black (00 §3). The coarsest level is few pages (each
    /// covers huge ground) so unbounded production here doesn't stutter.
    #[func]
    fn request_page_eager(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<ImageTexture>> {
        self.request(level, gx, gz, RequestMode::EagerUnbounded)
    }

    /// Request a MID-coarse page eagerly but BOUNDED by max_eager_per_frame
    /// (M1.9.3b). Spreading these over frames is safe: a missing mid-coarse page
    /// falls back to the COARSER blanket beneath it (the annulus logic keeps the
    /// coarser page visible until the finer footprint is complete), so the worst
    /// case is "blurrier for a frame", never black. Caller uses this for levels
    /// strictly between fine (0) and coarsest. Returns null when over the eager
    /// budget this frame (caller leaves the coarser page showing → never-black).
    #[func]
    fn request_page_eager_bounded(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<ImageTexture>> {
        self.request(level, gx, gz, RequestMode::EagerBounded)
    }

    fn request(&mut self, level: i64, gx: i64, gz: i64, mode: RequestMode) -> Option<Gd<ImageTexture>> {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        if let Some(page) = self.cache.get(&key) {
            self.cache_hits += 1;
            return Some(page.texture.clone());
        }
        // Budget gate per mode. Coarsest (EagerUnbounded) is never gated — it's
        // the never-black floor. Fine and mid-coarse are spread over frames; when
        // over budget the caller falls back to the coarser blanket (never black).
        match mode {
            RequestMode::Fine => {
                if self.produced_this_frame >= self.max_new_per_frame {
                    return None;
                }
            }
            RequestMode::EagerBounded => {
                if self.max_eager_per_frame > 0
                    && self.eager_bounded_this_frame >= self.max_eager_per_frame {
                    return None;
                }
            }
            RequestMode::EagerUnbounded => {}
        }
        let page = self.produce(key)?;
        match mode {
            RequestMode::Fine => self.produced_this_frame += 1,
            RequestMode::EagerBounded => {
                self.eager_bounded_this_frame += 1;
                self.eager_this_frame += 1;
            }
            RequestMode::EagerUnbounded => self.eager_this_frame += 1,
        }
        self.total_produced += 1;
        let tex = page.texture.clone();
        self.cache.insert(key, page);
        Some(tex)
    }

    /// Heights of a RESIDENT page, row-major (z*page_res + x) — the SAME array
    /// produced for the page's texture (00 §2.2 / M1.7: collision reads the same
    /// resident heights the view uses, never a second field path). Returns the
    /// cached array with NO re-dispatch and NO GPU readback; empty if the page
    /// isn't resident (caller must have a displayed page = a produced page).
    /// PackedFloat32Array is copy-on-write, so the returned value is a cheap
    /// shared handle until the caller mutates it.
    #[func]
    fn get_page_heights(&self, level: i64, gx: i64, gz: i64) -> PackedFloat32Array {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        match self.cache.get(&key) {
            Some(page) => page.heights.clone(),
            None => PackedFloat32Array::new(),
        }
    }

    /// Produce one page on the GPU (via shared FieldGpu): the height array AND
    /// the R32F texture packed from it, kept together as a ResidentPage so they
    /// can't drift (M1.7 one-source-of-truth). Coarser levels stretch origin
    /// stride AND spacing by 2^level, so a coarse page covers more world at the
    /// same resolution (the clipmap blanket).
    fn produce(&mut self, key: PageKey) -> Option<ResidentPage> {
        let t0 = std::time::Instant::now();
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
        // Profiled region: GPU dispatch + blocking readback (rd.sync) — the
        // suspected fast-motion spike source. Accumulated per frame (M1.9.1).
        let heights = self.gpu.as_mut()?.dispatch_page(params)?;
        self.produce_us_this_frame += t0.elapsed().as_micros() as i64;
        let res = self.cfg.page_res as i32;
        let bytes = heights.to_byte_array();
        let img = Image::create_from_data(res, res, false, Format::RF, &bytes)?;
        let texture = ImageTexture::create_from_image(&img)?;
        Some(ResidentPage { texture, heights })
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
    #[func] fn eager_this_frame(&self) -> i64 { self.eager_this_frame as i64 }
    #[func] fn evicted_count(&self) -> i64 { self.evicted }
    #[func] fn pinned_count(&self) -> i64 { self.pinned.len() as i64 }
    #[func] fn had_pin_violation(&self) -> bool { self.pin_violation }
    /// M1.9 profiling: microseconds spent producing pages this frame (GPU
    /// dispatch + blocking readback). The HUD reads this to attribute the
    /// fast-motion spike. Reset each begin_frame().
    #[func] fn produce_us_this_frame(&self) -> i64 { self.produce_us_this_frame }
}
