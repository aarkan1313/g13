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
}
