# M2.3 — Offline DEM Distillation Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone offline Rust binary that reads the 135 labeled DEM `.tif` tiles, groups them by terrain archetype, and emits a small per-archetype "fingerprint" params file (radial amplitude spectrum + slope ceiling + ridge character) for the runtime spectral field (M2.4) to consume.

**Architecture:** A new workspace member `rust/dem_distill` (a `[[bin]]`, NOT linked into the `wg13` cdylib — so the runtime never opens a `.tif`, honoring the `03_DEM_CATALOG` hard rule). It reads each tile's elevation + its `.tif.json` sidecar (bounds/width/height), converts degree spacing → metres (cos(lat) correction), computes per-tile statistics, aggregates by archetype, and writes `wg-13/data/dem_fingerprints.json` (committed; a few KB). Pure offline; the runtime is untouched by this milestone.

**Tech Stack:** Rust 2021; crates `tiff` (read GeoTIFF float32 elevation), `rustfft` (radial amplitude spectrum), `serde`/`serde_json` (read sidecars, write fingerprint file). Run with `cargo run -p dem_distill -- <dems_dir> <out_json>`.

**Determinism note:** this tool is offline and one-shot; its output (the fingerprint file) is the artifact that ships. Re-running on the same tiles yields the same numbers (no randomness).

---

## File Structure

- `rust/Cargo.toml` — add `dem_distill` to workspace `members`.
- `rust/dem_distill/Cargo.toml` — new crate manifest (bin; deps tiff, rustfft, serde, serde_json).
- `rust/dem_distill/src/main.rs` — CLI entry: parse args, walk dir, dispatch, write output.
- `rust/dem_distill/src/archetype.rs` — filename → archetype mapping (+ folds). Pure, unit-tested.
- `rust/dem_distill/src/sidecar.rs` — parse `.tif.json` sidecar (bounds/width/height/dtypes). serde structs.
- `rust/dem_distill/src/analyze.rs` — per-tile metrics: metre spacing (cos(lat)), slope p95, ridge character, radial amplitude spectrum (FFT). The math core.
- `rust/dem_distill/src/fingerprint.rs` — aggregate per-tile metrics → per-archetype `Fingerprint`; serialize the output JSON.
- `rust/dem_distill/tests/` — unit tests (archetype mapping; analyze on synthetic data with known spectra/slopes).
- `wg-13/data/dem_fingerprints.json` — OUTPUT (committed). One row per archetype.

The DEM `.tif`s stay at `archive/from_workflows_worldgen9/dems/opentopo/` (gitignored, on disk).

---

## Task 1: Workspace member + crate skeleton (compiles, runs, prints usage)

**Files:**
- Modify: `rust/Cargo.toml`
- Create: `rust/dem_distill/Cargo.toml`
- Create: `rust/dem_distill/src/main.rs`

- [ ] **Step 1: Add the member to the workspace**

In `rust/Cargo.toml`, change the members line:
```toml
[workspace]
resolver = "2"
members = ["gdext", "dem_distill"]
```

- [ ] **Step 2: Create the crate manifest**

Create `rust/dem_distill/Cargo.toml`:
```toml
[package]
name = "dem_distill"
version = "0.1.0"
edition = "2021"
publish = false

# OFFLINE tool only — NOT linked into the wg13 cdylib (no .tif at runtime,
# 03_DEM_CATALOG hard rule). Run with: cargo run -p dem_distill -- <dir> <out>
[[bin]]
name = "dem_distill"
path = "src/main.rs"

[dependencies]
tiff = "0.9"
rustfft = "6"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

- [ ] **Step 3: Minimal main that prints usage**

Create `rust/dem_distill/src/main.rs`:
```rust
//! Offline DEM distillation tool (M2.3). Reads labeled DEM .tif tiles + their
//! .tif.json sidecars, groups by terrain archetype, and emits a per-archetype
//! fingerprint file (radial amplitude spectrum + slope ceiling + ridge character)
//! for the runtime spectral field (M2.4). OFFLINE ONLY — never linked into the
//! Godot runtime; the runtime never opens a .tif (03_DEM_CATALOG hard rule).

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: dem_distill <dems_opentopo_dir> <out_fingerprints.json>");
        return ExitCode::from(2);
    }
    println!("dem_distill: dir={} out={}", args[1], args[2]);
    ExitCode::SUCCESS
}
```

- [ ] **Step 4: Build and run usage**

Run (note the target-dir override, 01_TOOLCHAIN §1):
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo run --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill
```
Expected: prints the `usage:` line and exits non-zero (no args). Then:
```powershell
cargo run --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill -- a b
```
Expected: prints `dem_distill: dir=a out=b`.

- [ ] **Step 5: Verify the gdext build is unaffected**

Run:
```powershell
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml" -p wg13
```
Expected: `wg13` builds clean (the new member doesn't touch it).

- [ ] **Step 6: Commit**

```powershell
git add rust/Cargo.toml rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] dem_distill crate skeleton (offline tool, not in runtime)`

---

## Task 2: Archetype mapping (filename → archetype, with folds)

**Files:**
- Create: `rust/dem_distill/src/archetype.rs`
- Modify: `rust/dem_distill/src/main.rs` (declare `mod archetype;`)
- Test: in `rust/dem_distill/src/archetype.rs` (`#[cfg(test)]`)

DEM filenames encode the archetype after stripping a `COP30_` and optional
`bulk<digits>_` prefix; the next token is the archetype, with a few folds
(03_DEM_CATALOG §"Labeled library"): `sahara→desert`, `andes→mountain`,
`amazon→rainforest`, and `cliff_coast`/`fjord_coast`/`delta_coast`/`sandy_coast`→`coast`.

- [ ] **Step 1: Write the failing test**

Create `rust/dem_distill/src/archetype.rs`:
```rust
//! Map a DEM tile filename to its terrain archetype (03_DEM_CATALOG). Pure.

/// The 12 canonical archetypes (after folds). Order is stable.
pub const ARCHETYPES: [&str; 12] = [
    "mountain", "badlands", "volcanic", "glacial", "desert", "karst",
    "grassland", "wetland", "coast", "rainforest", "temperate", "tundra",
];

/// Extract the archetype from a tile file stem (no extension). Returns None if
/// the stem doesn't match a known archetype (caller logs + skips).
pub fn archetype_of(stem: &str) -> Option<&'static str> {
    // Strip a leading "COP30_" and an optional "bulk<digits>_" prefix.
    let mut s = stem.strip_prefix("COP30_").unwrap_or(stem);
    if let Some(rest) = s.strip_prefix("bulk") {
        // rest begins with digits then '_'; drop through the first '_'.
        if let Some(us) = rest.find('_') {
            s = &rest[us + 1..];
        }
    }
    // Folds: a leading token that maps to a canonical archetype.
    const FOLDS: &[(&str, &str)] = &[
        ("sahara", "desert"),
        ("andes", "mountain"),
        ("amazon", "rainforest"),
        ("cliff_coast", "coast"),
        ("fjord_coast", "coast"),
        ("delta_coast", "coast"),
        ("sandy_coast", "coast"),
    ];
    for (pat, arche) in FOLDS {
        if s.starts_with(pat) {
            return Some(arche);
        }
    }
    for a in ARCHETYPES {
        if s.starts_with(a) {
            return Some(a);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_filenames() {
        assert_eq!(archetype_of("bulk20260524_mountain_alps_mont_blanc"), Some("mountain"));
        assert_eq!(archetype_of("bulk20260524_grassland_kazakh_steppe"), Some("grassland"));
        assert_eq!(archetype_of("COP30_andes_patagonia_-72_0_-41_15"), Some("mountain")); // fold
        assert_eq!(archetype_of("COP30_amazon_manaus_-60_0_-3_2"), Some("rainforest"));   // fold
        assert_eq!(archetype_of("sahara_erg_chebbi"), Some("desert"));                    // fold
        assert_eq!(archetype_of("cliff_coast_big_sur"), Some("coast"));                   // fold
        assert_eq!(archetype_of("fjord_coast_milford_sound"), Some("coast"));             // fold
        assert_eq!(archetype_of("temperate_black_forest"), Some("temperate"));
        assert_eq!(archetype_of("volcanic_hawaii_kilauea"), Some("volcanic"));
        assert_eq!(archetype_of("nonsense_place"), None);
    }
}
```

In `rust/dem_distill/src/main.rs` add at the top (after the doc comment):
```rust
mod archetype;
```

- [ ] **Step 2: Run the test to verify it passes** (it's written with the impl together — confirm green)

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill archetype
```
Expected: `maps_known_filenames ... ok`. If a fold is missing it FAILS naming the bad case — fix the FOLDS/order until green.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] archetype mapping (filename -> archetype, folds) + tests`

---

## Task 3: Sidecar parsing (.tif.json → bounds/width/height)

**Files:**
- Create: `rust/dem_distill/src/sidecar.rs`
- Modify: `rust/dem_distill/src/main.rs` (`mod sidecar;`)
- Test: in `rust/dem_distill/src/sidecar.rs`

- [ ] **Step 1: Write the struct + a parse test**

Create `rust/dem_distill/src/sidecar.rs`:
```rust
//! Parse a DEM .tif.json sidecar (03_DEM_CATALOG schema). Only the fields the
//! distiller needs; serde ignores the rest.

use serde::Deserialize;

#[derive(Deserialize, Clone, Copy)]
pub struct Bounds {
    pub south: f64,
    pub north: f64,
    pub west: f64,
    pub east: f64,
}

#[derive(Deserialize)]
pub struct Sidecar {
    pub bounds: Bounds,
    pub width: u32,
    pub height: u32,
}

impl Sidecar {
    pub fn from_str(s: &str) -> Result<Self, String> {
        serde_json::from_str(s).map_err(|e| format!("sidecar parse: {e}"))
    }
    /// Centre latitude (degrees) — for the cos(lat) longitude correction.
    pub fn center_lat(&self) -> f64 {
        (self.bounds.south + self.bounds.north) * 0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SAMPLE: &str = r#"{
        "demtype":"COP30",
        "bounds":{"south":-41.5,"north":-40.8,"west":-72.4,"east":-71.6},
        "crs":"EPSG:4326","width":2880,"height":2520,
        "dtypes":["float32"],"nodata":null }"#;

    #[test]
    fn parses_sample() {
        let s = Sidecar::from_str(SAMPLE).unwrap();
        assert_eq!(s.width, 2880);
        assert_eq!(s.height, 2520);
        assert!((s.center_lat() - (-41.15)).abs() < 1e-9);
        assert!((s.bounds.east - (-71.6)).abs() < 1e-9);
    }
}
```

In `main.rs` add `mod sidecar;`.

- [ ] **Step 2: Run the test**

Run:
```powershell
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill sidecar
```
Expected: `parses_sample ... ok`.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] sidecar (.tif.json) parsing + test`

---

## Task 4: Per-tile analysis — metre spacing + slope p95 (no FFT yet)

**Files:**
- Create: `rust/dem_distill/src/analyze.rs`
- Modify: `rust/dem_distill/src/main.rs` (`mod analyze;`)
- Test: in `rust/dem_distill/src/analyze.rs`

`analyze` works on a plain `&[f32]` elevation grid + its metre spacing, so it's
testable on synthetic data without reading a real `.tif`.

- [ ] **Step 1: Write metre-spacing + slope with a synthetic test**

Create `rust/dem_distill/src/analyze.rs`:
```rust
//! Per-tile terrain metrics. Operates on a plain elevation grid + metre spacing,
//! so it's unit-testable on synthetic data (no .tif needed here).

/// Metres per degree latitude (mean). Longitude scales by cos(lat).
const M_PER_DEG_LAT: f64 = 111_320.0;

/// (dx, dz) metres between adjacent cells, from the sidecar bounds + dims.
/// Longitude (x) uses cos(centre lat); latitude (z) is ~constant.
pub fn cell_spacing_m(west: f64, east: f64, south: f64, north: f64,
                      width: u32, height: u32) -> (f64, f64) {
    let lat_c = (south + north) * 0.5;
    let dx = ((east - west).abs() * M_PER_DEG_LAT * lat_c.to_radians().cos())
        / (width.max(2) as f64 - 1.0);
    let dz = ((north - south).abs() * M_PER_DEG_LAT) / (height.max(2) as f64 - 1.0);
    (dx, dz)
}

/// 95th-percentile slope magnitude (rise/run, dimensionless) over the grid.
/// Central differences in metres; NaN/Inf cells skipped.
pub fn slope_p95(h: &[f32], w: usize, ht: usize, dx: f64, dz: f64) -> f64 {
    let mut slopes: Vec<f64> = Vec::with_capacity(w * ht);
    for z in 1..ht.saturating_sub(1) {
        for x in 1..w.saturating_sub(1) {
            let c = h[z * w + x];
            let l = h[z * w + x - 1]; let r = h[z * w + x + 1];
            let u = h[(z - 1) * w + x]; let d = h[(z + 1) * w + x];
            if [c, l, r, u, d].iter().any(|v| !v.is_finite()) { continue; }
            let gx = (r - l) as f64 / (2.0 * dx);
            let gz = (d - u) as f64 / (2.0 * dz);
            slopes.push((gx * gx + gz * gz).sqrt());
        }
    }
    if slopes.is_empty() { return 0.0; }
    slopes.sort_by(|a, b| a.partial_cmp(b).unwrap());
    slopes[((slopes.len() as f64) * 0.95) as usize]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spacing_is_positive_and_lon_compressed() {
        // At ~41 deg S, a 0.8-deg-wide tile of 2880 px: dx < dz (cos(lat) < 1).
        let (dx, dz) = cell_spacing_m(-72.4, -71.6, -41.5, -40.8, 2880, 2520);
        assert!(dx > 0.0 && dz > 0.0);
        assert!(dx < dz, "longitude spacing should be compressed by cos(lat)");
    }

    #[test]
    fn slope_of_a_known_ramp() {
        // 4x4 grid, height = x * 10 metres, dx = dz = 10 m -> slope = 1.0 everywhere.
        let w = 4; let ht = 4;
        let mut h = vec![0f32; w * ht];
        for z in 0..ht { for x in 0..w { h[z * w + x] = (x as f32) * 10.0; } }
        let s = slope_p95(&h, w, ht, 10.0, 10.0);
        assert!((s - 1.0).abs() < 1e-6, "ramp slope {s} != 1.0");
    }
}
```

In `main.rs` add `mod analyze;`.

- [ ] **Step 2: Run the tests**

Run:
```powershell
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill analyze
```
Expected: `spacing_is_positive_and_lon_compressed ... ok`, `slope_of_a_known_ramp ... ok`.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] analyze: metre spacing (cos lat) + slope p95 + tests`

---

## Task 5: Radial amplitude spectrum (FFT) + ridge character

**Files:**
- Modify: `rust/dem_distill/src/analyze.rs` (add spectrum + ridge fns + tests)

The **radial amplitude spectrum** is the core fingerprint: 2D FFT of the (mean-
removed, windowed) elevation, magnitude binned by radial frequency, collapsed to
`N_BANDS` octave-ish bands from coarse→fine. **Ridge character** = mean of the
normalized absolute Laplacian (creased terrain has higher curvature density).

- [ ] **Step 1: Add spectrum + ridge functions with a synthetic-frequency test**

Append to `rust/dem_distill/src/analyze.rs` (inside the file, before `#[cfg(test)]`):
```rust
use rustfft::{num_complex::Complex, FftPlanner};

/// Number of radial frequency bands in the fingerprint (coarse -> fine).
pub const N_BANDS: usize = 8;

/// Radial amplitude spectrum, collapsed to N_BANDS normalized weights summing
/// to 1.0. Square-crops to `s x s` (s = min(w,ht) rounded down to even), removes
/// the mean, applies a Hann window (reduces edge leakage), 2D FFT, then bins
/// magnitude by radial frequency into N_BANDS logarithmic bands.
pub fn radial_spectrum(h: &[f32], w: usize, ht: usize) -> [f32; N_BANDS] {
    let s = (w.min(ht)) & !1usize; // even square side
    if s < 8 { return [0.0; N_BANDS]; }
    // Square crop (top-left) + mean.
    let mut buf: Vec<Complex<f32>> = Vec::with_capacity(s * s);
    let mut mean = 0f64;
    for z in 0..s { for x in 0..s {
        let v = h[z * w + x];
        let v = if v.is_finite() { v } else { 0.0 };
        mean += v as f64;
        buf.push(Complex { re: v, im: 0.0 });
    }}
    mean /= (s * s) as f64;
    // Hann window + remove mean.
    for z in 0..s { for x in 0..s {
        let wz = 0.5 - 0.5 * (std::f32::consts::TAU * z as f32 / (s as f32 - 1.0)).cos();
        let wx = 0.5 - 0.5 * (std::f32::consts::TAU * x as f32 / (s as f32 - 1.0)).cos();
        let i = z * s + x;
        buf[i].re = (buf[i].re - mean as f32) * wz * wx;
    }}
    // 2D FFT: rows then columns.
    let mut planner = FftPlanner::new();
    let fft = planner.plan_fft_forward(s);
    for z in 0..s { fft.process(&mut buf[z * s..z * s + s]); }
    // transpose, FFT, transpose back (column transform)
    let mut col = vec![Complex { re: 0.0, im: 0.0 }; s];
    for x in 0..s {
        for z in 0..s { col[z] = buf[z * s + x]; }
        fft.process(&mut col);
        for z in 0..s { buf[z * s + x] = col[z]; }
    }
    // Radial bins: frequency radius -> logarithmic band. Skip DC (0,0).
    let half = s / 2;
    let max_r = (half as f32) * std::f32::consts::SQRT_2;
    let mut bands = [0f64; N_BANDS];
    for z in 0..s { for x in 0..s {
        if z == 0 && x == 0 { continue; }
        let fz = if z <= half { z as f32 } else { z as f32 - s as f32 };
        let fx = if x <= half { x as f32 } else { x as f32 - s as f32 };
        let r = (fx * fx + fz * fz).sqrt();
        if r < 1.0 { continue; }
        // log band: r in [1, max_r] -> [0, N_BANDS)
        let t = (r.ln() / max_r.max(2.0).ln()).clamp(0.0, 0.999_99);
        let b = (t * N_BANDS as f32) as usize;
        let mag = buf[z * s + x].norm() as f64;
        bands[b.min(N_BANDS - 1)] += mag;
    }}
    // Normalize to sum 1.0.
    let total: f64 = bands.iter().sum();
    let mut out = [0f32; N_BANDS];
    if total > 0.0 { for b in 0..N_BANDS { out[b] = (bands[b] / total) as f32; } }
    out
}

/// Ridge character in ~[0,1]: normalized mean absolute discrete Laplacian.
/// Ridged/creased terrain has more high curvature than rounded terrain. Scaled
/// by the height range so it's comparable across tiles of different relief.
pub fn ridge_character(h: &[f32], w: usize, ht: usize) -> f32 {
    let mut sum = 0f64; let mut n = 0u64;
    let mut hmin = f32::INFINITY; let mut hmax = f32::NEG_INFINITY;
    for &v in h { if v.is_finite() { hmin = hmin.min(v); hmax = hmax.max(v); } }
    let range = ((hmax - hmin) as f64).max(1.0);
    for z in 1..ht.saturating_sub(1) { for x in 1..w.saturating_sub(1) {
        let c = h[z * w + x];
        let l = h[z * w + x - 1]; let r = h[z * w + x + 1];
        let u = h[(z - 1) * w + x]; let d = h[(z + 1) * w + x];
        if [c, l, r, u, d].iter().any(|v| !v.is_finite()) { continue; }
        let lap = (l + r + u + d - 4.0 * c) as f64;
        sum += lap.abs(); n += 1;
    }}
    if n == 0 { return 0.0; }
    ((sum / n as f64) / range).clamp(0.0, 1.0) as f32
}
```

Append these tests inside the existing `mod tests`:
```rust
    #[test]
    fn spectrum_sums_to_one_and_catches_frequency() {
        // Low-frequency sine -> energy in the coarse (low) bands.
        let s = 64usize;
        let mut h = vec![0f32; s * s];
        for z in 0..s { for x in 0..s {
            h[z * s + x] = (std::f32::consts::TAU * 2.0 * x as f32 / s as f32).sin() * 100.0;
        }}
        let lo = radial_spectrum(&h, s, s);
        let sum: f32 = lo.iter().sum();
        assert!((sum - 1.0).abs() < 1e-3, "spectrum sum {sum} != 1");
        // High-frequency sine -> energy shifts to finer (higher) bands.
        let mut hf = vec![0f32; s * s];
        for z in 0..s { for x in 0..s {
            hf[z * s + x] = (std::f32::consts::TAU * 16.0 * x as f32 / s as f32).sin() * 100.0;
        }}
        let hi = radial_spectrum(&hf, s, s);
        // centroid band index, energy-weighted
        let cen = |b: &[f32; N_BANDS]| -> f32 {
            let mut num = 0.0; let mut den = 0.0;
            for i in 0..N_BANDS { num += i as f32 * b[i]; den += b[i]; }
            if den > 0.0 { num / den } else { 0.0 }
        };
        assert!(cen(&hi) > cen(&lo), "high-freq spectrum centroid {} !> low {}", cen(&hi), cen(&lo));
    }

    #[test]
    fn ridge_character_higher_for_creased() {
        let s = 32usize;
        // smooth ramp
        let mut smooth = vec![0f32; s * s];
        for z in 0..s { for x in 0..s { smooth[z * s + x] = x as f32; } }
        // creased: triangle wave (sharp ridges)
        let mut creased = vec![0f32; s * s];
        for z in 0..s { for x in 0..s {
            creased[z * s + x] = (x as f32 % 4.0 - 2.0).abs() * 30.0;
        }}
        assert!(ridge_character(&creased, s, s) > ridge_character(&smooth, s, s));
    }
```

- [ ] **Step 2: Run the tests**

Run:
```powershell
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill analyze
```
Expected: all analyze tests pass, including `spectrum_sums_to_one_and_catches_frequency` and `ridge_character_higher_for_creased`.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] analyze: radial amplitude spectrum (FFT) + ridge character + tests`

---

## Task 6: Fingerprint aggregation + JSON output schema

**Files:**
- Create: `rust/dem_distill/src/fingerprint.rs`
- Modify: `rust/dem_distill/src/main.rs` (`mod fingerprint;`)
- Test: in `rust/dem_distill/src/fingerprint.rs`

- [ ] **Step 1: Define the Fingerprint + accumulator with a test**

Create `rust/dem_distill/src/fingerprint.rs`:
```rust
//! Aggregate per-tile metrics into one Fingerprint per archetype, and serialize
//! the output the runtime (M2.4) reads.

use serde::Serialize;
use crate::analyze::N_BANDS;

/// One archetype's distilled terrain fingerprint. Output schema (committed JSON).
#[derive(Serialize, Clone)]
pub struct Fingerprint {
    pub archetype: String,
    pub tile_count: u32,
    /// Radial amplitude spectrum, N_BANDS normalized weights (coarse -> fine).
    pub spectrum: Vec<f32>,
    /// 95th-percentile slope (rise/run) — the synthesis steepness ceiling.
    pub slope_p95: f32,
    /// Ridge character ~[0,1] (rounded -> ridged).
    pub ridge_character: f32,
}

/// Running mean accumulator across an archetype's tiles.
pub struct Accum {
    archetype: String,
    n: u32,
    spectrum: [f64; N_BANDS],
    slope: f64,
    ridge: f64,
}

impl Accum {
    pub fn new(archetype: &str) -> Self {
        Self { archetype: archetype.to_string(), n: 0, spectrum: [0.0; N_BANDS], slope: 0.0, ridge: 0.0 }
    }
    pub fn add(&mut self, spectrum: &[f32; N_BANDS], slope_p95: f32, ridge: f32) {
        for i in 0..N_BANDS { self.spectrum[i] += spectrum[i] as f64; }
        self.slope += slope_p95 as f64;
        self.ridge += ridge as f64;
        self.n += 1;
    }
    pub fn finish(&self) -> Fingerprint {
        let d = self.n.max(1) as f64;
        // Average then renormalize the spectrum to sum 1.0.
        let mut spec: Vec<f32> = self.spectrum.iter().map(|s| (s / d) as f32).collect();
        let tot: f32 = spec.iter().sum();
        if tot > 0.0 { for s in spec.iter_mut() { *s /= tot; } }
        Fingerprint {
            archetype: self.archetype.clone(),
            tile_count: self.n,
            spectrum: spec,
            slope_p95: (self.slope / d) as f32,
            ridge_character: (self.ridge / d) as f32,
        }
    }
}

/// Serialize the full set to pretty JSON.
pub fn to_json(fps: &[Fingerprint]) -> String {
    serde_json::to_string_pretty(fps).unwrap_or_else(|_| "[]".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn averages_and_renormalizes() {
        let mut a = Accum::new("mountain");
        let mut s1 = [0f32; N_BANDS]; s1[0] = 0.8; s1[1] = 0.2;
        let mut s2 = [0f32; N_BANDS]; s2[0] = 0.4; s2[1] = 0.6;
        a.add(&s1, 1.5, 0.7);
        a.add(&s2, 0.5, 0.3);
        let fp = a.finish();
        assert_eq!(fp.tile_count, 2);
        assert!((fp.spectrum.iter().sum::<f32>() - 1.0).abs() < 1e-5);
        assert!((fp.slope_p95 - 1.0).abs() < 1e-5);
        assert!((fp.ridge_character - 0.5).abs() < 1e-5);
    }
}
```

In `main.rs` add `mod fingerprint;`.

- [ ] **Step 2: Run the test**

Run:
```powershell
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill fingerprint
```
Expected: `averages_and_renormalizes ... ok`.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/
git commit -F a-temp-message-file
```
Message: `[M2.3] fingerprint aggregation + JSON schema + test`

---

## Task 7: Wire main — walk dir, read .tif + sidecar, analyze, write fingerprints

**Files:**
- Modify: `rust/dem_distill/src/main.rs`

This is the integration: read each `.tif` (float32 elevation via the `tiff`
crate), pair with its `.tif.json`, map to archetype, analyze, accumulate, write.

- [ ] **Step 1: Implement the tile reader + main pipeline**

Replace the body of `rust/dem_distill/src/main.rs`'s `main()` (keep the module
decls and doc comment) with:
```rust
mod archetype;
mod sidecar;
mod analyze;
mod fingerprint;

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

use analyze::N_BANDS;
use fingerprint::Accum;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: dem_distill <dems_opentopo_dir> <out_fingerprints.json>");
        return ExitCode::from(2);
    }
    let dir = &args[1];
    let out = &args[2];

    let mut accums: BTreeMap<&'static str, Accum> = BTreeMap::new();
    let mut read = 0u32;
    let mut skipped = 0u32;

    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => { eprintln!("cannot read dir {dir}: {e}"); return ExitCode::FAILURE; }
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("tif") { continue; }
        let stem = match path.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s, None => { skipped += 1; continue; }
        };
        let arche = match archetype::archetype_of(stem) {
            Some(a) => a,
            None => { eprintln!("skip (no archetype): {stem}"); skipped += 1; continue; }
        };
        let side_path = format!("{}.json", path.display());
        let side = match fs::read_to_string(&side_path).ok()
            .and_then(|s| sidecar::Sidecar::from_str(&s).ok()) {
            Some(s) => s,
            None => { eprintln!("skip (no/bad sidecar): {stem}"); skipped += 1; continue; }
        };
        let (h, w, ht) = match read_tif_f32(&path) {
            Ok(t) => t,
            Err(e) => { eprintln!("skip (tif read {stem}): {e}"); skipped += 1; continue; }
        };
        if w * ht != h.len() || w < 8 || ht < 8 { skipped += 1; continue; }

        let (dx, dz) = analyze::cell_spacing_m(
            side.bounds.west, side.bounds.east, side.bounds.south, side.bounds.north,
            side.width, side.height);
        let spectrum = analyze::radial_spectrum(&h, w, ht);
        let slope = analyze::slope_p95(&h, w, ht, dx, dz);
        let ridge = analyze::ridge_character(&h, w, ht);

        accums.entry(arche).or_insert_with(|| Accum::new(arche))
            .add(&spectrum, slope as f32, ridge);
        read += 1;
        println!("ok {arche:<10} {stem}  slope_p95={slope:.3} ridge={ridge:.3}");
    }

    let mut fps: Vec<_> = accums.values().map(|a| a.finish()).collect();
    fps.sort_by(|a, b| a.archetype.cmp(&b.archetype));
    let json = fingerprint::to_json(&fps);
    if let Some(parent) = Path::new(out).parent() { let _ = fs::create_dir_all(parent); }
    if let Err(e) = fs::write(out, &json) {
        eprintln!("cannot write {out}: {e}"); return ExitCode::FAILURE;
    }
    eprintln!("DONE: read {read}, skipped {skipped}, archetypes {} (N_BANDS={N_BANDS}) -> {out}", fps.len());
    ExitCode::SUCCESS
}

/// Read a single-band float32 GeoTIFF as (heights, width, height). Decodes the
/// full image; DEM tiles here are float32 (sidecar dtypes=["float32"]).
fn read_tif_f32(path: &Path) -> Result<(Vec<f32>, usize, usize), String> {
    use tiff::decoder::{Decoder, DecodingResult};
    let file = fs::File::open(path).map_err(|e| e.to_string())?;
    let mut dec = Decoder::new(std::io::BufReader::new(file)).map_err(|e| e.to_string())?;
    let (w, ht) = dec.dimensions().map_err(|e| e.to_string())?;
    let img = dec.read_image().map_err(|e| e.to_string())?;
    let heights: Vec<f32> = match img {
        DecodingResult::F32(v) => v,
        DecodingResult::F64(v) => v.into_iter().map(|x| x as f32).collect(),
        DecodingResult::I16(v) => v.into_iter().map(|x| x as f32).collect(),
        DecodingResult::U16(v) => v.into_iter().map(|x| x as f32).collect(),
        _ => return Err("unsupported tiff sample format".into()),
    };
    Ok((heights, w as usize, ht as usize))
}
```

Delete the now-duplicate `mod archetype;` etc. lines if they appear twice (the
block above includes the four `mod` decls once at the top).

- [ ] **Step 2: Build**

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill
```
Expected: builds clean.

- [ ] **Step 3: Run on the real DEM library**

Run:
```powershell
cargo run --release --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill -- "D:\world gen 13\archive\from_workflows_worldgen9\dems\opentopo" "D:\world gen 13\wg-13\data\dem_fingerprints.json"
```
Expected: prints `ok <archetype> <name> slope_p95=… ridge=…` per tile, then
`DONE: read 135, skipped 0, archetypes 12 …`. (A few skips are acceptable if a
sidecar is malformed; `read` should be ~135 and archetypes should be 12.)

- [ ] **Step 4: Commit**

```powershell
git add rust/dem_distill/ "wg-13/data/dem_fingerprints.json"
git commit -F a-temp-message-file
```
Message: `[M2.3] main pipeline: walk tiles -> analyze -> dem_fingerprints.json`

---

## Task 8: The gate — m2_3_distill_check (sanity-assert the output)

This is the M2.3 test gate. It does NOT need Godot/GPU — it's a plain Rust test
that reads the committed fingerprint file and asserts the numbers are sane and
discriminating (the catalog's "mountain ≠ grassland" check).

**Files:**
- Create: `rust/dem_distill/tests/fingerprints_sane.rs`

- [ ] **Step 1: Write the gate test**

Create `rust/dem_distill/tests/fingerprints_sane.rs`:
```rust
//! M2.3 GATE — assert the committed dem_fingerprints.json is sane + discriminating.
//! Run: cargo test --manifest-path rust/Cargo.toml -p dem_distill --test fingerprints_sane

use serde::Deserialize;

#[derive(Deserialize)]
struct Fp {
    archetype: String,
    tile_count: u32,
    spectrum: Vec<f32>,
    slope_p95: f32,
    ridge_character: f32,
}

fn load() -> Vec<Fp> {
    // CARGO_MANIFEST_DIR = rust/dem_distill ; file is at wg-13/data/.
    let p = concat!(env!("CARGO_MANIFEST_DIR"), "/../../wg-13/data/dem_fingerprints.json");
    let s = std::fs::read_to_string(p).expect("dem_fingerprints.json must exist (run the tool first)");
    serde_json::from_str(&s).expect("valid fingerprint json")
}

fn spectrum_centroid(s: &[f32]) -> f32 {
    let mut num = 0.0; let mut den = 0.0;
    for (i, w) in s.iter().enumerate() { num += i as f32 * w; den += w; }
    if den > 0.0 { num / den } else { 0.0 }
}

#[test]
fn fingerprints_are_sane() {
    let fps = load();
    assert!(fps.len() >= 12, "expected >= 12 archetypes, got {}", fps.len());
    for fp in &fps {
        assert!(fp.tile_count > 0, "{} has no tiles", fp.archetype);
        let sum: f32 = fp.spectrum.iter().sum();
        assert!((sum - 1.0).abs() < 1e-3, "{} spectrum sum {} != 1", fp.archetype, sum);
        assert!(fp.slope_p95 > 0.0 && fp.slope_p95 < 20.0,
            "{} slope_p95 {} implausible", fp.archetype, fp.slope_p95);
        assert!(fp.ridge_character >= 0.0 && fp.ridge_character <= 1.0,
            "{} ridge {} out of range", fp.archetype, fp.ridge_character);
    }
    println!("PASS: {} archetypes, all spectra normalized, slopes/ridge in range", fps.len());
}

#[test]
fn mountain_is_steeper_than_grassland() {
    let fps = load();
    let get = |a: &str| fps.iter().find(|f| f.archetype == a)
        .unwrap_or_else(|| panic!("missing archetype {a}"));
    let m = get("mountain");
    let g = get("grassland");
    // Mountains must be markedly steeper than grassland (the believability core).
    assert!(m.slope_p95 > g.slope_p95 * 1.5,
        "mountain slope_p95 {} not >> grassland {}", m.slope_p95, g.slope_p95);
    println!("PASS: mountain slope_p95 {:.3} >> grassland {:.3}; mountain spectrum centroid {:.2}, grassland {:.2}",
        m.slope_p95, g.slope_p95, spectrum_centroid(&m.spectrum), spectrum_centroid(&g.spectrum));
}
```

- [ ] **Step 2: Run the gate**

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p dem_distill --test fingerprints_sane -- --nocapture
```
Expected: both tests PASS; the `PASS:` lines print real numbers (mountain
slope_p95 clearly > grassland). If `mountain_is_steeper_than_grassland` fails,
that's a real signal the analysis is wrong — investigate (Phase 1 debugging),
do not weaken the assert.

- [ ] **Step 3: Commit**

```powershell
git add rust/dem_distill/tests/
git commit -F a-temp-message-file
```
Message: `[M2.3] GATE m2_3 distill: fingerprints sane + mountain steeper than grassland`

---

## Task 9: Record + document (docs match reality)

**Files:**
- Modify: `plans and docs/plans/PROGRESS.md` (mark M2.3 done)
- Modify: `plans and docs/plans/04_CODE_MAP.md` (add the tool + output + gate)
- Modify: `plans and docs/plans/DRIFT_LOG.md` (prepend an entry)
- Modify: `.gitignore` if needed (ensure the `.tif`s stay ignored; the JSON output is committed)

- [ ] **Step 1: Confirm gitignore keeps DEMs out, fingerprints in**

Run:
```powershell
git check-ignore "archive/from_workflows_worldgen9/dems/opentopo/COP30_amazon_manaus_-60_0_-3_2.tif"
git check-ignore "wg-13/data/dem_fingerprints.json"
```
Expected: the `.tif` path prints (ignored = good); the fingerprints path prints
NOTHING (not ignored = committed). If the JSON is ignored, add `!wg-13/data/dem_fingerprints.json` to `.gitignore`.

- [ ] **Step 2: Update PROGRESS.md**

Change the M2.3 line to `[x]` with a one-line result (archetypes count, that the
gate passed with mountain>grassland), and move the `<- CURRENT` marker to M2.4.

- [ ] **Step 3: Update 04_CODE_MAP.md**

Add a section documenting `rust/dem_distill/` (offline tool: archetype/sidecar/
analyze/fingerprint + the gate), the output `wg-13/data/dem_fingerprints.json`,
and the run command. Note it is NOT in the runtime.

- [ ] **Step 4: Append a DRIFT_LOG.md entry**

Prepend an entry (format per 02_WORKFLOW §3): M2.3 done — offline DEM distill tool
built + run on 135 tiles -> per-archetype fingerprints; gate PASS (sane +
mountain steeper than grassland); runtime untouched (no .tif at runtime). Next: M2.4.

- [ ] **Step 5: Commit**

```powershell
git add "plans and docs/plans/" .gitignore
git commit -F a-temp-message-file
```
Message: `[M2.3] docs: record distill tool done + gate PASS; point to M2.4`

---

## Notes for the implementer

- **Commit message mechanic (01_TOOLCHAIN gotcha):** write each message to a temp
  file and `git commit -F <file>` (here-strings with special chars have broken
  commits before). Keep messages ASCII. End with the Co-Authored-By trailer used
  in this repo's history.
- **target-dir override (01_TOOLCHAIN §1):** every cargo command pins
  `$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"` or output escapes the tree.
- **No GPU/Godot needed** for any M2.3 step — it's pure offline Rust. (M2.4 is where
  the runtime/GPU comes back.)
- **If a crate version doesn't resolve** (`tiff`/`rustfft` API drift): check the
  actual API with `cargo doc` and adapt the call (e.g. `Decoder::read_image`
  return variants). Don't guess — read the crate's types. The plan's API usage
  matches tiff 0.9 / rustfft 6 at writing.
- **Performance:** reading 135 tiles (~15 GB) + FFT is offline and one-shot; use
  `--release` for the real run (Task 7 Step 3). Minutes is fine.
