# M2.4c Step 1 — MacroBake + RegionCache (pure Rust) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the deterministic, off-frame **macro bake** (one super-region's structural fields via the proven window-port) and a **bounded LRU region cache** — entirely in pure Rust, fully unit-tested, with ZERO GPU and ZERO engine wiring — as the foundation for Approach C (`docs/superpowers/specs/2026-06-07-m2-4c-macro-cache-terrain-design.md`).

**Architecture:** A new `macro_cache` module inside the `wg13` gdext crate (NOT the scaffold crate — this is runtime engine code). `MacroBake::bake_region` reuses `structural_scaffold::recipes::mountain::generate_seamsafe_fields` verbatim (the window-port that produced the liked look) to compute a `RegionMacro` (flat f32 structural fields) from `(seed, rx, rz, cfg)`. `RegionCache` is a bounded LRU keyed by `(rx, rz)`. Both are pure: no I/O, no threads, no GPU, no Godot FFI in the testable core — so they unit-test with plain `cargo test`.

**Tech Stack:** Rust (gdext crate `wg13`), depends on the existing `structural_scaffold` crate. No GPU, no GDScript in this step.

**Scope:** This is build step 1 of 4 from the spec. Steps 2 (GPU upload+sample bridge), 3 (BakeScheduler + prefetch + fallback), 4 (loading-screen prefetch + tunables + visual gate) are SEPARATE follow-on plans written after this lands green. This plan touches NO shader, NO page production, NO terrain_mode — it is self-contained pure-Rust foundation.

**Dependency note:** `structural_scaffold` currently exposes `generate_fact_map_style`, `sample_cell`, `oracle_fact_map` publicly, but `generate_seamsafe_fields` + `MountainFields` + `apron_meshgrid` + `S_REF` + `ALPINE_BRANCHING` live in private modules (only reachable via the `__bake_probe` doc-hidden re-export added for the timing probe). Task 1 promotes a clean public API for them, replacing the probe hack.

---

## Cargo dependency precondition

The `wg13` crate must depend on `structural_scaffold`. Verify/add before Task 2.

- [ ] **Step A: Check the dependency**

Read `rust/gdext/Cargo.toml`. If it does NOT list `structural_scaffold`, add under `[dependencies]`:

```toml
structural_scaffold = { path = "../structural_scaffold" }
```

Run: `cargo build --manifest-path rust\Cargo.toml -p wg13` (with `$env:CARGO_TARGET_DIR="D:\world gen 13\rust\target"`)
Expected: builds clean (no behavior change yet; just the dep available).

- [ ] **Step B: Commit if changed**

```bash
git add rust/gdext/Cargo.toml rust/Cargo.lock
git commit -F - <<'EOF'
[M2.4c] wg13 depends on structural_scaffold (macro bake reuse)

So the runtime macro bake can call the proven window-port
(generate_seamsafe_fields) directly. No behavior change.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```
(If Cargo.toml already had the dep, skip the commit.)

---

## Task 1: Promote a clean public bake API on `structural_scaffold`

**Files:**
- Modify: `rust/structural_scaffold/src/lib.rs` (replace the `__bake_probe` doc-hidden re-export with a real public `bake` module)
- Modify: `rust/structural_scaffold/tests/bake_timing_probe.rs` (update its import to the new path) — OR delete the probe (it was a one-off; the timing decision is made). DECISION: delete it; the measurement is recorded in the spec.

**Context:** The window-port internals (`generate_seamsafe_fields`, `MountainFields`, `apron_meshgrid`, `S_REF`, `ALPINE_BRANCHING`) are private + exposed only via the `__bake_probe` hack. Promote a real public surface so `wg13` can call them cleanly, and remove the probe.

- [ ] **Step 1: Delete the timing probe (its job is done)**

Delete `rust/structural_scaffold/tests/bake_timing_probe.rs`.

- [ ] **Step 2: Replace `__bake_probe` with a public `bake` module**

In `rust/structural_scaffold/src/lib.rs`, replace the `#[doc(hidden)] pub mod __bake_probe { ... }` block with:

```rust
/// Public surface for the runtime MACRO BAKE (Approach C). Re-exports the seam-safe
/// window-port pieces the engine's macro_cache calls to bake one super-region.
/// Stable for the gdext crate; the underlying recipe modules stay private.
pub mod bake {
    pub use crate::recipes::helpers::{apron_meshgrid, S_REF};
    pub use crate::recipes::mountain::{
        generate_seamsafe_fields, MountainFields, MountainStyle, ALPINE_BRANCHING, APRON_PX, STYLES,
    };
}
```

(Confirm `APRON_PX`, `STYLES`, `MountainStyle` are `pub` in `recipes/mountain.rs` — they are, per the source. If any is not `pub`, make it `pub`.)

- [ ] **Step 3: Build the scaffold crate**

Run: `cargo build --manifest-path rust\Cargo.toml -p structural_scaffold`
Expected: builds clean.

- [ ] **Step 4: Run the scaffold tests (no regression)**

Run: `cargo test --manifest-path rust\Cargo.toml -p structural_scaffold`
Expected: all PASS (the 6 existing lib tests; the deleted probe no longer runs).

- [ ] **Step 5: Commit**

```bash
git add rust/structural_scaffold/src/lib.rs
git rm rust/structural_scaffold/tests/bake_timing_probe.rs
git commit -F - <<'EOF'
[M2.4c] promote public structural_scaffold::bake API; drop timing probe

Replaces the __bake_probe doc-hidden hack with a real pub `bake` module
(generate_seamsafe_fields, MountainFields, apron_meshgrid, S_REF, styles)
so the runtime macro_cache can call the window-port cleanly. Timing probe
removed (its measurement is recorded in the M2.4c spec).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 2: `RegionMacro` struct + `MacroBakeConfig`

**Files:**
- Create: `rust/gdext/src/macro_cache/mod.rs` (module root)
- Create: `rust/gdext/src/macro_cache/region.rs` (the data types)
- Modify: `rust/gdext/src/lib.rs` (add `mod macro_cache;`)

**Context:** `RegionMacro` holds one baked super-region's structural fields as flat f32 row-major arrays (the layer fine pages will sample in step 2). `MacroBakeConfig` holds the tunables (spacing, super-region size, resolution). Keep fields f32 (the bake computes f64 internally; we downcast on store to halve memory — the spec's footprint math assumes f32).

- [ ] **Step 1: Write the failing test**

Create `rust/gdext/src/macro_cache/region.rs` with ONLY the test first (it won't compile — that's the failure):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn region_macro_indexing_is_row_major() {
        let res = 4;
        let mut rm = RegionMacro::zeroed(7, 11, res);
        rm.height[2 * res + 3] = 42.0;          // (x=3, z=2)
        assert_eq!(rm.cell_count(), res * res);
        assert_eq!(rm.height_at(3, 2), 42.0);
        assert_eq!(rm.region_x, 7);
        assert_eq!(rm.region_z, 11);
        assert_eq!(rm.resolution, res);
    }

    #[test]
    fn config_core_span_and_resolution_are_consistent() {
        let cfg = MacroBakeConfig { bake_spacing_m: 256.0, super_region_m: 30000.0 };
        // resolution = ceil(super_region / spacing) so the core covers the region.
        assert_eq!(cfg.resolution(), 118);
        assert!((cfg.core_span_m() - (118.0 - 1.0) * 256.0).abs() < 1.0);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 region_macro` 
Expected: FAIL to compile (`RegionMacro`, `MacroBakeConfig` not defined).

- [ ] **Step 3: Write the types**

Prepend to `rust/gdext/src/macro_cache/region.rs` (above the test module):

```rust
//! M2.4c: the cached macro layer's data types — one baked super-region's
//! structural fields (flat f32, row-major z*res+x) and the bake tunables.

/// Tunable bake parameters (data-driven; defaults set by the caller, picked by
/// visual gate per the spec — NOT hardcoded terrain values).
#[derive(Clone, Copy, Debug)]
pub struct MacroBakeConfig {
    pub bake_spacing_m: f32,   // metres per macro cell (start ~256; tunable)
    pub super_region_m: f32,   // world span one super-region covers (~30km; tunable)
}

impl MacroBakeConfig {
    /// Core macro cells per side: ceil(super_region / spacing) so the core covers
    /// the whole region (the bake adds an apron around this, cropped after).
    pub fn resolution(&self) -> usize {
        (self.super_region_m / self.bake_spacing_m).ceil() as usize
    }
    /// World span the core grid covers (shared-boundary convention: (res-1)*spacing).
    pub fn core_span_m(&self) -> f32 {
        (self.resolution() as f32 - 1.0) * self.bake_spacing_m
    }
}

/// One baked super-region's structural fields. Flat f32, row-major (z*res + x).
/// These are what fine pages will sample (Approach C step 2). Mirrors the WG10
/// fact vocabulary: height + the masks that drive material/biome bias.
#[derive(Clone, Debug, PartialEq)]
pub struct RegionMacro {
    pub region_x: i32,
    pub region_z: i32,
    pub resolution: usize,
    pub height: Vec<f32>,        // world Y (metres)
    pub range_mask: Vec<f32>,    // [0,1] where highland mass stands
    pub channel_mask: Vec<f32>,  // [0,1] drainage/valley corridors
    pub pass_floor: Vec<f32>,    // [0,1] graded traversable corridor
    pub massif: Vec<f32>,        // [0,1] inner massif weight
    pub rock: Vec<f32>,          // [0,1] material hint
    pub snow: Vec<f32>,          // [0,1] material hint
    pub valley_floor: Vec<f32>,  // [0,1] material hint
}

impl RegionMacro {
    pub fn zeroed(region_x: i32, region_z: i32, resolution: usize) -> Self {
        let n = resolution * resolution;
        Self {
            region_x, region_z, resolution,
            height: vec![0.0; n],
            range_mask: vec![0.0; n],
            channel_mask: vec![0.0; n],
            pass_floor: vec![0.0; n],
            massif: vec![0.0; n],
            rock: vec![0.0; n],
            snow: vec![0.0; n],
            valley_floor: vec![0.0; n],
        }
    }
    pub fn cell_count(&self) -> usize { self.resolution * self.resolution }
    pub fn height_at(&self, x: usize, z: usize) -> f32 { self.height[z * self.resolution + x] }
}
```

Create `rust/gdext/src/macro_cache/mod.rs`:

```rust
//! M2.4c macro-cache: off-frame bake of per-super-region structural fields
//! (RegionMacro), reused from the proven window-port, plus a bounded LRU cache.
//! Pure Rust, no GPU/threads in this layer (step 1 of the Approach C build).

mod region;
pub use region::{MacroBakeConfig, RegionMacro};

mod bake;
pub use bake::MacroBake;

mod cache;
pub use cache::RegionCache;
```

(`bake` and `cache` modules are created in Tasks 3 and 4; if the crate must compile after THIS task, temporarily comment the `mod bake;`/`mod cache;` + their `pub use` lines, then uncomment in those tasks. Simpler: do Step 5's build with only `mod region;` exported, and add the others when written.)

For THIS task, `mod.rs` should contain only:

```rust
//! M2.4c macro-cache (step 1: pure-Rust bake + bounded cache).
mod region;
pub use region::{MacroBakeConfig, RegionMacro};
```

Add to `rust/gdext/src/lib.rs` (near the other `mod` declarations):

```rust
mod macro_cache;
```

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 region_macro`
Expected: PASS (2 tests). NOTE: these tests use no Godot FFI (plain structs/Vecs), so they run under plain `cargo test`.

- [ ] **Step 5: Commit**

```bash
git add rust/gdext/src/macro_cache/ rust/gdext/src/lib.rs
git commit -F - <<'EOF'
[M2.4c] RegionMacro + MacroBakeConfig data types (pure Rust)

The cached macro layer's types: one super-region's structural fields
(height + range/channel/pass/massif/material masks, flat f32 row-major)
and the bake tunables (spacing, super-region size; resolution/span
derived). No GPU/threads. Unit-tested for indexing + config consistency.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 3: `MacroBake::bake_region` (reuse the window-port)

**Files:**
- Create: `rust/gdext/src/macro_cache/bake.rs`
- Modify: `rust/gdext/src/macro_cache/mod.rs` (add `mod bake; pub use bake::MacroBake;`)

**Context:** `bake_region(seed, rx, rz, cfg) -> RegionMacro` computes the apron-padded world grid for region (rx,rz), runs `generate_seamsafe_fields` (flow_on = true), crops to core, derives the material masks the same way `structural_scaffold`'s `fact_cells_from_mountain_fields` does, downcasts f64->f32. Region (rx,rz) origin = `(rx * core_span, rz * core_span)` so adjacent regions tile seamlessly (shared-boundary convention).

- [ ] **Step 1: Write the failing tests**

Create `rust/gdext/src/macro_cache/bake.rs` with the test module first:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::macro_cache::MacroBakeConfig;

    fn cfg() -> MacroBakeConfig {
        // small + coarse so the test is fast (apron is large; keep res modest)
        MacroBakeConfig { bake_spacing_m: 256.0, super_region_m: 8000.0 }
    }

    #[test]
    fn bake_is_deterministic() {
        let a = MacroBake::bake_region(177, 2, -1, cfg());
        let b = MacroBake::bake_region(177, 2, -1, cfg());
        assert_eq!(a, b, "same seed/region/cfg must be bit-identical");
    }

    #[test]
    fn bake_fields_are_finite_and_sized() {
        let rm = MacroBake::bake_region(177, 0, 0, cfg());
        let res = cfg().resolution();
        assert_eq!(rm.resolution, res);
        assert_eq!(rm.height.len(), res * res);
        assert_eq!(rm.channel_mask.len(), res * res);
        for &h in &rm.height { assert!(h.is_finite()); }
        for &c in &rm.channel_mask { assert!((0.0..=1.0).contains(&c)); }
        for &r in &rm.range_mask { assert!((0.0..=1.0).contains(&r)); }
    }

    #[test]
    fn bake_has_real_relief_not_flat() {
        let rm = MacroBake::bake_region(177, 0, 0, cfg());
        let lo = rm.height.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = rm.height.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo > 100.0, "macro height should have real relief, got {} m", hi - lo);
    }

    #[test]
    fn adjacent_regions_agree_on_shared_border() {
        // East border of (0,0) core vs west border of (1,0) core: same world column,
        // so heights must match closely (seam-safe apron -> tight agreement).
        let west = MacroBake::bake_region(177, 0, 0, cfg());
        let east = MacroBake::bake_region(177, 1, 0, cfg());
        let res = cfg().resolution();
        let mut max_delta = 0.0f32;
        for z in 0..res {
            let w = west.height[z * res + (res - 1)]; // east edge of west region
            let e = east.height[z * res + 0];          // west edge of east region
            max_delta = max_delta.max((w - e).abs());
        }
        assert!(max_delta < 1.0, "shared border height delta {} m too large (seam)", max_delta);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 macro_cache::bake`
Expected: FAIL to compile (`MacroBake` not defined).

- [ ] **Step 3: Write `MacroBake::bake_region`**

Prepend to `rust/gdext/src/macro_cache/bake.rs`:

```rust
//! M2.4c: bake ONE super-region's structural fields by reusing the proven
//! window-port (structural_scaffold::bake::generate_seamsafe_fields). Pure
//! compute: (seed, rx, rz, cfg) -> RegionMacro. No threads/GPU here (the
//! scheduler in step 3 runs this off-frame).

use crate::macro_cache::{MacroBakeConfig, RegionMacro};
use structural_scaffold::bake::{
    apron_meshgrid, generate_seamsafe_fields, ALPINE_BRANCHING, APRON_PX, S_REF,
};

pub struct MacroBake;

impl MacroBake {
    pub fn bake_region(seed: u64, rx: i32, rz: i32, cfg: MacroBakeConfig) -> RegionMacro {
        let res = cfg.resolution();
        let spacing = cfg.bake_spacing_m as f64;
        let core_span = cfg.core_span_m() as f64;

        // World-anchored apron in CELLS: cover the same ~APRON_PX*S_REF world distance
        // at this spacing (so the blur/flow halo is scale-correct, like the window-port).
        let apron = (((APRON_PX as f64) * S_REF) / spacing).round() as usize;
        let padded = res + apron * 2;

        // Region origin tiles seamlessly: (rx,rz) * core_span (shared-boundary).
        let origin_x = rx as f64 * core_span;
        let origin_z = rz as f64 * core_span;

        // apron_meshgrid offsets by -apron cells, so world coords line up across regions.
        let (wx, wz) = apron_meshgrid(padded, padded, apron, spacing, origin_x, origin_z);

        let fields = generate_seamsafe_fields(
            &wx, &wz, padded, padded, seed as i64, &ALPINE_BRANCHING,
            core_span, apron, spacing, true, // flow_on = true (drainage)
        );

        // fields are already core-cropped (length res*res). Derive material masks the
        // same way structural_scaffold::fact_cells_from_mountain_fields does, downcast f32.
        let n = res * res;
        let mut rm = RegionMacro::zeroed(rx, rz, res);
        for i in 0..n {
            let range = fields.range_envelope[i].clamp(0.0, 1.0) as f32;
            let ridge = fields.ranges[i].clamp(0.0, 1.0) as f32;
            let massif = fields.massif[i].clamp(0.0, 1.0) as f32;
            let primary = fields.primary_channels[i].clamp(0.0, 1.0) as f32;
            let tributary = fields.tributaries[i].clamp(0.0, 1.0) as f32;
            let lowland = fields.lowland[i].clamp(0.0, 1.0) as f32;
            let valley_mask = fields.valley_mask[i].clamp(0.0, 1.0) as f32;
            let floor_mask = fields.floor_mask[i].clamp(0.0, 1.0) as f32;

            let channel = primary.max(tributary * 0.65).clamp(0.0, 1.0);
            let pass = floor_mask.max(lowland * 0.35).clamp(0.0, 1.0);
            // preview_height_m convention from structural_scaffold: 1050 + h*520.
            let height = 1_050.0 + fields.height[i] as f32 * 520.0;
            let rock = (range * 0.34 + ridge * 0.38 + massif * 0.26).clamp(0.0, 1.0);
            let snow = (smoothstep(1_550.0, 2_350.0, height) * (0.36 + range * 0.64)).clamp(0.0, 1.0);
            let valley_floor = channel.max(pass * 0.82).max(valley_mask * 0.42);

            rm.height[i] = height;
            rm.range_mask[i] = range;
            rm.channel_mask[i] = channel;
            rm.pass_floor[i] = pass;
            rm.massif[i] = massif;
            rm.rock[i] = rock;
            rm.snow[i] = snow;
            rm.valley_floor[i] = valley_floor;
        }
        rm
    }
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}
```

Add to `rust/gdext/src/macro_cache/mod.rs`:

```rust
mod bake;
pub use bake::MacroBake;
```

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 macro_cache::bake`
Expected: PASS (4 tests: deterministic, finite/sized, real relief, adjacent border agreement).

NOTE on the border test tolerance: the window-port's apron makes adjacent regions agree to a tight epsilon. If `adjacent_regions_agree_on_shared_border` fails with a delta of several metres, the likely cause is the region-origin tiling (core_span vs padded span) — verify origin = `rx * core_span` (NOT `rx * super_region_m` and NOT padded span). Do NOT loosen the tolerance to pass; fix the tiling (a real seam would show as cracks live).

- [ ] **Step 5: Commit**

```bash
git add rust/gdext/src/macro_cache/bake.rs rust/gdext/src/macro_cache/mod.rs
git commit -F - <<'EOF'
[M2.4c] MacroBake::bake_region — reuse window-port, per super-region

bake_region(seed,rx,rz,cfg) runs the proven generate_seamsafe_fields
(blur + flow routing) on an apron-padded world grid, crops to core,
derives material masks, downcasts to f32 RegionMacro. World-anchored
apron; region origin = (rx,rz)*core_span for seamless tiling. Unit
tests: determinism, finite/bounded, real relief, adjacent-border
agreement (<1m, proves seam-safe tiling). Pure compute, no GPU/threads.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 4: `RegionCache` (bounded LRU)

**Files:**
- Create: `rust/gdext/src/macro_cache/cache.rs`
- Modify: `rust/gdext/src/macro_cache/mod.rs` (add `mod cache; pub use cache::RegionCache;`)

**Context:** A bounded LRU keyed by `(rx, rz)`. Holds `RegionMacro`s. On `insert` beyond `cap`, evict the least-recently-used. `get` marks most-recently-used. Deterministic rebuild (Task 3) makes eviction safe. Pure data structure — no threads (the scheduler in step 3 owns concurrency). Simple LRU via a `HashMap` + a `VecDeque<(i32,i32)>` recency list (cap is small — hundreds — so O(n) recency touch is fine; keep it simple, no extern crate).

- [ ] **Step 1: Write the failing tests**

Create `rust/gdext/src/macro_cache/cache.rs` with the test module first:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::macro_cache::RegionMacro;

    fn rm(rx: i32, rz: i32) -> RegionMacro { RegionMacro::zeroed(rx, rz, 2) }

    #[test]
    fn insert_and_get() {
        let mut c = RegionCache::new(4);
        assert!(c.get(0, 0).is_none());
        c.insert(rm(0, 0));
        assert!(c.contains(0, 0));
        assert_eq!(c.get(0, 0).unwrap().region_x, 0);
        assert_eq!(c.len(), 1);
    }

    #[test]
    fn bounded_evicts_lru() {
        let mut c = RegionCache::new(2);
        c.insert(rm(0, 0));
        c.insert(rm(1, 0));
        let _ = c.get(0, 0);          // touch (0,0) -> now (1,0) is LRU
        c.insert(rm(2, 0));           // over cap -> evict LRU = (1,0)
        assert!(c.contains(0, 0), "recently-used kept");
        assert!(c.contains(2, 0), "newest kept");
        assert!(!c.contains(1, 0), "LRU evicted");
        assert_eq!(c.len(), 2);
    }

    #[test]
    fn reinsert_updates_recency_not_size() {
        let mut c = RegionCache::new(2);
        c.insert(rm(0, 0));
        c.insert(rm(0, 0));           // same key again
        assert_eq!(c.len(), 1);
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 macro_cache::cache`
Expected: FAIL to compile (`RegionCache` not defined).

- [ ] **Step 3: Write `RegionCache`**

Prepend to `rust/gdext/src/macro_cache/cache.rs`:

```rust
//! M2.4c: bounded LRU cache of baked RegionMacros, keyed by (rx,rz). Deterministic
//! rebuild (MacroBake) makes eviction safe — purely a speed cache, never truth.
//! Pure data structure; the scheduler (step 3) owns threading.

use std::collections::HashMap;
use std::collections::VecDeque;

use crate::macro_cache::RegionMacro;

pub struct RegionCache {
    cap: usize,
    map: HashMap<(i32, i32), RegionMacro>,
    recency: VecDeque<(i32, i32)>, // front = LRU, back = MRU
}

impl RegionCache {
    pub fn new(cap: usize) -> Self {
        Self { cap: cap.max(1), map: HashMap::new(), recency: VecDeque::new() }
    }

    pub fn len(&self) -> usize { self.map.len() }
    pub fn is_empty(&self) -> bool { self.map.is_empty() }
    pub fn contains(&self, rx: i32, rz: i32) -> bool { self.map.contains_key(&(rx, rz)) }

    /// Get + mark most-recently-used.
    pub fn get(&mut self, rx: i32, rz: i32) -> Option<&RegionMacro> {
        let key = (rx, rz);
        if self.map.contains_key(&key) {
            self.touch(key);
            self.map.get(&key)
        } else {
            None
        }
    }

    /// Insert (or replace), mark MRU, evict LRU if over cap.
    pub fn insert(&mut self, region: RegionMacro) {
        let key = (region.region_x, region.region_z);
        self.map.insert(key, region);
        self.touch(key);
        while self.map.len() > self.cap {
            if let Some(lru) = self.recency.pop_front() {
                // pop_front may name a stale key already re-touched; only evict if it
                // is still the front-most occurrence (i.e. not present later).
                if !self.recency.contains(&lru) {
                    self.map.remove(&lru);
                }
            } else {
                break;
            }
        }
    }

    fn touch(&mut self, key: (i32, i32)) {
        self.recency.retain(|k| *k != key);
        self.recency.push_back(key);
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cargo test --manifest-path rust\Cargo.toml -p wg13 macro_cache::cache`
Expected: PASS (3 tests). Then enable the `mod cache` export.

Add to `rust/gdext/src/macro_cache/mod.rs`:

```rust
mod cache;
pub use cache::RegionCache;
```

- [ ] **Step 5: Run the whole crate + workspace (no regression)**

Run (editor closed for the wg13 build):
```
cargo build --manifest-path rust\Cargo.toml -p wg13
cargo test --manifest-path rust\Cargo.toml --workspace
```
Expected: builds clean; ALL tests PASS (existing wg13 + scaffold + the new macro_cache tests). The macro_cache is pure additive Rust — no existing gate touched.

- [ ] **Step 6: Commit**

```bash
git add rust/gdext/src/macro_cache/cache.rs rust/gdext/src/macro_cache/mod.rs
git commit -F - <<'EOF'
[M2.4c] RegionCache — bounded LRU of baked macro regions

HashMap + recency VecDeque, keyed by (rx,rz). get() marks MRU; insert()
evicts LRU over cap. Deterministic rebuild makes eviction safe (speed
cache, never truth). Pure data structure, no threads. Unit tests:
insert/get, bounded LRU eviction with touch, reinsert recency. Workspace
green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Task 5: Step-1 close-out (docs)

**Files:** PROGRESS, DRIFT_LOG, HANDOFF, the M2.4c spec.

**Context:** Step 1 (pure-Rust bake + cache foundation) is green. Record it; the next plan is step 2 (GPU upload + sample bridge). This is a TEST-gated close (all unit tests green) — no human visual gate at this step (nothing renders yet).

- [ ] **Step 1: Update PROGRESS + HANDOFF + DRIFT_LOG**

DRIFT_LOG (append at top): TYPE = step gate PASS; what landed (MacroBake reusing window-port + RegionCache, pure Rust, N tests green, no GPU); what's next (step 2 GPU bridge). Update PROGRESS M2.4 line to note C step 1 done. Update HANDOFF §3 current-state.

- [ ] **Step 2: Commit docs**

```bash
git add "plans and docs/plans/PROGRESS.md" "plans and docs/plans/HANDOFF.md" "plans and docs/plans/DRIFT_LOG.md"
git commit -F - <<'EOF'
[M2.4c] step 1 done — pure-Rust macro bake + cache foundation green

MacroBake (reuses the window-port per super-region) + RegionCache
(bounded LRU), all pure Rust, unit-tested (determinism, seam agreement,
relief, LRU), zero GPU. Foundation for Approach C. Next: step 2 — GPU
upload + sample bridge (the one risky piece), its own plan.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
```

---

## Self-Review

**1. Spec coverage (this is STEP 1 only — steps 2-4 are follow-on plans):**
- Spec "MacroBake (Rust, pure compute, reuses generate_seamsafe_fields)" — Tasks 1+3. ✓
- Spec "RegionCache (bounded LRU, deterministic eviction)" — Task 4. ✓
- Spec "RegionMacro structural fields (height + range/channel/pass/massif/material)" — Task 2. ✓
- Spec "tunable bake spacing / super-region size (data-driven)" — Task 2 MacroBakeConfig. ✓
- Spec "bake determinism + seam agreement test" — Task 3 tests. ✓
- Spec "cache invariants test (bounded, LRU, rebuild-identical)" — Task 4 tests (rebuild-identical follows from bake determinism, Task 3). ✓
- Spec "live+procedural, no disk I/O" — bake is pure (seed,rx,rz)->fields; no I/O anywhere. ✓
- DEFERRED to later plans (correctly NOT in this plan): GPU upload+sample (step 2), BakeScheduler+prefetch+fallback (step 3), loading-screen prefetch + terrain_mode wiring + visual gate (step 4).

**2. Placeholder scan:** No TBD/TODO. Every code step shows full code. Commands have expected output. The `mod.rs` "comment then uncomment" note is an explicit ordering instruction, not a placeholder (the final state is specified). ✓

**3. Type/name consistency:** `RegionMacro`, `MacroBakeConfig`, `MacroBake`, `RegionCache` consistent across tasks. `bake_region(seed,rx,rz,cfg)` signature matches its test calls. `resolution()`/`core_span_m()` used consistently. `structural_scaffold::bake::{...}` (Task 1) matches the imports in Task 3. `height_at(x,z)`/row-major `z*res+x` consistent. Cache `new/get/insert/contains/len` consistent between tests and impl. ✓

**Executor notes:**
- Editor must be CLOSED for any `cargo build/test -p wg13` (wg13.dll lock). The scaffold-crate-only tasks (Task 1) don't need the editor closed.
- All tests in this plan are pure Rust (no Godot FFI) — they run under plain `cargo test`, no `--rendering-driver vulkan`, no headless concern. This is the payoff of keeping step 1 GPU-free.
- The border-agreement tolerance (Task 3) is a real seam check — fix tiling, never loosen it.
