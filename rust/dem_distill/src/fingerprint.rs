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
