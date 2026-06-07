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

use crate::field_gpu::{FieldGpu, FieldPage, PageParams, BIOME_STRIDE};
use crate::render_gpu::{RenderGpu, RenderTextures};
use godot::classes::image::Format;
use godot::classes::{Image, ImageTexture, Texture2Drd};
use godot::prelude::*;

/// M2.2 default biome roster (DATA, 00 §6) — centroids in normalized
/// (temp, moisture, altitude), BIOME_STRIDE floats per row [t_c, m_c, a_c, _pad].
/// Nearest-centroid Whittaker over the climate cube; high alt_c rows (snow, rock)
/// pull in at elevation via the altitude weight. The display shader holds the
/// matching debug-color table (BIOME_COLORS in world_view). Adding a biome = a
/// row here + a color there; never a code branch. Order = biome id.
///   0 snow/ice  1 tundra  2 taiga  3 mountain rock  4 grassland
///   5 temperate forest  6 temperate rainforest  7 desert  8 savanna
///   9 tropical rainforest
const BIOME_CENTROIDS: [[f32; BIOME_STRIDE]; 10] = [
    [0.15, 0.50, 0.95, 0.0],  // 0 snow / ice cap
    [0.18, 0.35, 0.55, 0.0],  // 1 tundra
    [0.35, 0.62, 0.50, 0.0],  // 2 taiga / boreal
    [0.50, 0.30, 0.85, 0.0],  // 3 bare mountain rock
    [0.58, 0.30, 0.30, 0.0],  // 4 grassland / steppe
    [0.55, 0.70, 0.35, 0.0],  // 5 temperate forest
    [0.50, 0.92, 0.35, 0.0],  // 6 temperate rainforest
    [0.88, 0.15, 0.25, 0.0],  // 7 desert
    [0.85, 0.45, 0.30, 0.0],  // 8 savanna
    [0.90, 0.90, 0.30, 0.0],  // 9 tropical rainforest
];
const BIOME_W_TEMP: f32 = 1.0;
const BIOME_W_MOIST: f32 = 1.0;
const BIOME_W_ALT: f32 = 1.2;   // elevation pulls peaks to alpine/snow, but temp/
                                // moisture still decide lowlands (deserts, jungle)
// Macro-altitude frequency: the biome altitude axis is a SEPARATE continental
// low-frequency landform (not the detailed render height), sampled at this freq
// so biomes stay contiguous at every LOD. ~1/30 km = big landmasses/sub-regions,
// far below any LOD cell spacing. Tunable.
const BIOME_ALT_FREQ: f32 = 0.000033;

/// Identifies a page in the world: ring level + integer grid coordinates.
/// Level 0 is finest; each coarser level doubles world span per page (M1.5c).
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct PageKey {
    level: i32,
    gx: i32,
    gz: i32,
}

/// A resident page: the displayed height texture AND the CPU height array it was
/// packed from, PLUS the M2.1 climate textures (temperature, moisture). ONE
/// production fills all of them, so collision (which reads `heights`), the view's
/// height displacement (`texture`) and the climate tint (`temp_tex`/`moist_tex`)
/// can never disagree — the M1.7 contract ("collision reads the same resident
/// page heights the view uses, never a second field path", 00 §2.2). The height
/// path is byte-for-byte what M1 produced (climate is additive); they cache and
/// evict together as one unit.
struct ResidentPage {
    // M2.6: RENDER textures are GPU-resident — produced on the MAIN device and
    // wrapped in Texture2DRD (no readback/re-upload). `texture` (height, vertex
    // displacement), `climate_tex` (RG: temp,moist), `biome_tex` (biome id),
    // `normal_tex` (RG: nx,nz). These are the same uniform names world_view binds.
    texture: Gd<Texture2Drd>,
    climate_tex: Gd<Texture2Drd>,
    biome_tex: Gd<Texture2Drd>,
    normal_tex: Gd<Texture2Drd>,
    /// The underlying main-device RD texture RIDs (NOT ref-counted) — freed on
    /// evict via RenderGpu::free_textures (Stage 3) or VRAM leaks.
    render_rids: RenderTextures,
    /// CPU heights for COLLISION (M1.7) — still read back from the LOCAL device
    /// (`gpu`). Byte-identical to what M1 produced. (Stage 2 trims this to near
    /// level-0 pages only.)
    heights: PackedFloat32Array,
    /// CPU biome ids (the gate's source of truth) — from the local readback.
    biome: PackedFloat32Array,
}

/// How a page request is budgeted this frame (M1.9.3b).
#[derive(Clone, Copy)]
enum RequestMode {
    Fine,            // finest level — bounded by max_new_per_frame
    EagerBounded,    // mid-coarse — bounded by max_eager_per_frame, falls back to coarser
    EagerUnbounded,  // coarsest — never gated (the never-black floor)
}

/// fBM + page geometry config + M2.1 climate params. Mirrors the GLSL Params
/// block (page_pool dispatches the same field_height.glsl). Climate defaults are
/// "continental": bands span tens of km so biomes (M2.2) come out large and
/// contiguous, never per-page confetti (MILESTONE_2 §2).
#[derive(Clone, Copy)]
struct FieldConfig {
    page_res: u32,
    spacing: f32,
    seed: f32,
    octaves: u32,
    base_freq: f32,
    amplitude: f32,
    climate_lat_scale: f32,
    climate_temp_freq: f32,
    climate_temp_noise: f32,
    climate_lapse: f32,
    climate_moist_freq: f32,
    // M2.2 biome classifier (centroids live in FieldGpu; here = count + weights).
    biome_count: u32,
    biome_w_temp: f32,
    biome_w_moist: f32,
    biome_w_alt: f32,
    biome_alt_freq: f32,
}

impl Default for FieldConfig {
    fn default() -> Self {
        Self {
            page_res: 128, spacing: 4.0, seed: 1234.0, octaves: 5,
            base_freq: 0.0015, amplitude: 240.0,
            // ~60 km latitude half-swing (poles ~120 km apart): continental bands.
            climate_lat_scale: 60000.0,
            // 1/50 km temp wobble, 1/40 km moisture: large regions, smooth.
            climate_temp_freq: 0.00002,
            climate_temp_noise: 0.15,
            climate_lapse: 0.35,   // cooling from lowland->peak (alt-normalized now)
            climate_moist_freq: 0.000025,
            // Biome defaults match the BIOME_CENTROIDS roster pushed in initialize().
            biome_count: BIOME_CENTROIDS.len() as u32,
            biome_w_temp: BIOME_W_TEMP,
            biome_w_moist: BIOME_W_MOIST,
            biome_w_alt: BIOME_W_ALT,
            biome_alt_freq: BIOME_ALT_FREQ,
        }
    }
}

#[derive(GodotClass)]
#[class(base = RefCounted)]
pub struct PagePool {
    base: Base<RefCounted>,
    gpu: Option<FieldGpu>,
    /// M2.6: GPU-resident RENDER producer on the MAIN device (Texture2DRD outputs,
    /// no readback). Render textures come from here; `gpu` (local device) still
    /// produces the CPU `heights` for collision (M1.7).
    render: Option<RenderGpu>,
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
            render: None,
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
    /// Compile the field shader on a local RD (shared FieldGpu machinery) and
    /// push the default M2.2 biome centroid table to the GPU.
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        let flat: Vec<f32> = BIOME_CENTROIDS.iter().flatten().copied().collect();
        let biome_arr = PackedFloat32Array::from(flat.as_slice());
        if let Some(gpu) = self.gpu.as_mut() {
            gpu.set_biome_centroids(&biome_arr);
        }
        // M2.6: GPU-resident render producer on the MAIN device, same field GLSL +
        // biome table. If the main device is unavailable (headless/OpenGL) this is
        // None and rendering falls back to nothing — the GPU gates require vulkan.
        self.render = RenderGpu::new(&shader_glsl_path, biome_arr.to_byte_array());
        self.gpu.is_some() && self.render.is_some()
    }

    /// Configure field params (tunable from GDScript / inspector). Climate params
    /// keep their defaults (or whatever a prior configure_climate set); this
    /// preserves the M1 call site (world_view) without forcing climate args here.
    #[func]
    fn configure(&mut self, page_res: i64, spacing: f32, seed: f32, octaves: i64,
                 base_freq: f32, amplitude: f32, max_new_per_frame: i64) {
        // Mutate only the height/geometry fields in place, so climate (M2.1) and
        // biome (M2.2) params keep their defaults / prior configure_* values.
        self.cfg.page_res = page_res as u32;
        self.cfg.spacing = spacing;
        self.cfg.seed = seed;
        self.cfg.octaves = octaves as u32;
        self.cfg.base_freq = base_freq;
        self.cfg.amplitude = amplitude;
        self.max_new_per_frame = max_new_per_frame as i32;
    }

    /// M2.1: tune the climate model (latitude band size, temp/moisture noise
    /// frequencies, temp wobble amplitude, altitude lapse). Tunable from
    /// GDScript / inspector; defaults are continental (see FieldConfig::default).
    #[func]
    fn configure_climate(&mut self, lat_scale: f32, temp_freq: f32, temp_noise: f32,
                         lapse: f32, moist_freq: f32) {
        self.cfg.climate_lat_scale = lat_scale;
        self.cfg.climate_temp_freq = temp_freq;
        self.cfg.climate_temp_noise = temp_noise;
        self.cfg.climate_lapse = lapse;
        self.cfg.climate_moist_freq = moist_freq;
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
    fn request_page(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        self.request(level, gx, gz, RequestMode::Fine)
    }

    /// Request a page EAGERLY, UNBOUNDED. Use for the COARSEST level — the
    /// never-black backstop, which must ALWAYS be complete so a hole in finer
    /// levels never reveals black (00 §3). The coarsest level is few pages (each
    /// covers huge ground) so unbounded production here doesn't stutter.
    #[func]
    fn request_page_eager(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
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
    fn request_page_eager_bounded(&mut self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        self.request(level, gx, gz, RequestMode::EagerBounded)
    }

    fn request(&mut self, level: i64, gx: i64, gz: i64, mode: RequestMode) -> Option<Gd<Texture2Drd>> {
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

    /// M2.1: the climate texture (RG32F, R=temperature G=moisture) of a RESIDENT
    /// page — the SAME production behind that page's height texture (one source
    /// of truth). Null if the page isn't resident. The view binds it for the
    /// climate view-mode tint; the field/collision paths don't depend on it.
    #[func]
    fn get_page_climate_tex(&self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        self.cache.get(&key).map(|p| p.climate_tex.clone())
    }

    /// M2.2: the biome-id texture (R32F, float-encoded int) of a RESIDENT page —
    /// the SAME production behind that page's height/climate textures. Null if not
    /// resident. The view binds it for the biome view-mode debug color.
    #[func]
    fn get_page_biome_tex(&self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        self.cache.get(&key).map(|p| p.biome_tex.clone())
    }

    /// M2.4: the normal-gradient texture (RG32F: R=normal_x, G=normal_z) of a
    /// RESIDENT page — the SAME production behind that page's height texture. Null
    /// if not resident. The view binds it so the display shader uses seam-free
    /// per-cell normals instead of finite-differencing the height texture.
    #[func]
    fn get_page_normal_tex(&self, level: i64, gx: i64, gz: i64) -> Option<Gd<Texture2Drd>> {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        self.cache.get(&key).map(|p| p.normal_tex.clone())
    }

    /// M2.2: biome id (float-encoded int) of a RESIDENT page, row-major — the
    /// SAME array behind biome_tex (for the gate / future field-side readers).
    /// Empty if not resident.
    #[func]
    fn get_page_biome(&self, level: i64, gx: i64, gz: i64) -> PackedFloat32Array {
        let key = PageKey { level: level as i32, gx: gx as i32, gz: gz as i32 };
        match self.cache.get(&key) {
            Some(page) => page.biome.clone(),
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
            climate_lat_scale: self.cfg.climate_lat_scale,
            climate_temp_freq: self.cfg.climate_temp_freq,
            climate_temp_noise: self.cfg.climate_temp_noise,
            climate_lapse: self.cfg.climate_lapse,
            climate_moist_freq: self.cfg.climate_moist_freq,
            biome_count: self.cfg.biome_count,
            biome_w_temp: self.cfg.biome_w_temp,
            biome_w_moist: self.cfg.biome_w_moist,
            biome_w_alt: self.cfg.biome_w_alt,
            biome_alt_freq: self.cfg.biome_alt_freq,
        };
        // M2.6 RENDER path: produce the 4 render textures GPU-resident on the MAIN
        // device (no readback/re-upload). The display shader samples these directly.
        let render_rids = self.render.as_mut()?.produce(params)?;
        let mut texture = Texture2Drd::new_gd();
        texture.set_texture_rd_rid(render_rids.height);
        let mut climate_tex = Texture2Drd::new_gd();
        climate_tex.set_texture_rd_rid(render_rids.climate);
        let mut biome_tex = Texture2Drd::new_gd();
        biome_tex.set_texture_rd_rid(render_rids.biome);
        let mut normal_tex = Texture2Drd::new_gd();
        normal_tex.set_texture_rd_rid(render_rids.normal);

        // COLLISION path (M1.7): the LOCAL-device readback produces the CPU `heights`
        // for the HeightMapShape. M2.6 STAGE 2: collision is built ONLY for level-0
        // pages (world_view), so ONLY level 0 needs the blocking readback. Levels 1-5
        // (the coarse blanket — most pages in a burst) skip it entirely: render is
        // GPU-resident, and they never collide. This removes the dominant per-page
        // stall for the majority of streamed pages. Their `heights`/`biome` stay
        // empty; get_page_heights already returns empty for non-collidable use.
        let (heights, biome) = if key.level == 0 {
            // Profiled region (M1.9.1): the blocking dispatch+readback (level-0 only now).
            let FieldPage { heights, biome, .. } = self.gpu.as_mut()?.dispatch_page(params)?;
            self.produce_us_this_frame += t0.elapsed().as_micros() as i64;
            (heights, biome)
        } else {
            (PackedFloat32Array::new(), PackedFloat32Array::new())
        };

        Some(ResidentPage {
            texture, climate_tex, biome_tex, normal_tex, render_rids, heights, biome,
        })
    }

    /// Pack a per-cell float array into an R32F ImageTexture (the format the M1
    /// height path used). Bytes are the LE float bytes, so the texture is
    /// bit-identical to the source array.
    fn r32f_texture(res: i32, data: &PackedFloat32Array) -> Option<Gd<ImageTexture>> {
        let bytes = data.to_byte_array();
        let img = Image::create_from_data(res, res, false, Format::RF, &bytes)?;
        ImageTexture::create_from_image(&img)
    }

    /// Pack two per-cell float arrays into ONE RG32F ImageTexture (R = `r_data`,
    /// G = `g_data`), interleaved [r,g,r,g,...]. Used for the M2.1 climate
    /// channels (temperature, moisture) so a page carries one climate texture.
    fn rg32f_texture(res: i32, r_data: &PackedFloat32Array, g_data: &PackedFloat32Array)
        -> Option<Gd<ImageTexture>> {
        let n = (res * res) as usize;
        let r = r_data.as_slice();
        let g = g_data.as_slice();
        let mut bytes: Vec<u8> = Vec::with_capacity(n * 8);
        for i in 0..n {
            bytes.extend_from_slice(&r[i].to_le_bytes());
            bytes.extend_from_slice(&g[i].to_le_bytes());
        }
        let pba = PackedByteArray::from(bytes.as_slice());
        let img = Image::create_from_data(res, res, false, Format::RGF, &pba)?;
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
    #[func] fn eager_this_frame(&self) -> i64 { self.eager_this_frame as i64 }
    #[func] fn evicted_count(&self) -> i64 { self.evicted }
    #[func] fn pinned_count(&self) -> i64 { self.pinned.len() as i64 }
    #[func] fn had_pin_violation(&self) -> bool { self.pin_violation }
    /// M1.9 profiling: microseconds spent producing pages this frame (GPU
    /// dispatch + blocking readback). The HUD reads this to attribute the
    /// fast-motion spike. Reset each begin_frame().
    #[func] fn produce_us_this_frame(&self) -> i64 { self.produce_us_this_frame }
}
