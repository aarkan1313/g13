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
