//! Load the offline-distilled DEM fingerprints (wg-13/data/dem_fingerprints.json)
//! at runtime. This reads a small (~3.5 KB) JSON of NUMBERS (spectra/slopes) —
//! NOT a .tif. The .tif hard rule (03_DEM_CATALOG) forbids loading DEM RASTER
//! data at runtime; the distilled params are config, like WorldConfig. M2.4 uses
//! these to shape the procedural field per biome archetype.

use std::collections::HashMap;

pub const N_BANDS: usize = 8;

#[derive(Clone, Copy)]
pub struct Fingerprint {
    pub spectrum: [f32; N_BANDS],
    pub slope_p95: f32,
}

/// Parse the fingerprint JSON text into archetype -> Fingerprint. Hand-rolled
/// (no serde dep in the runtime crate) — the schema is tiny and fixed.
pub fn parse(json: &str) -> HashMap<String, Fingerprint> {
    let mut out = HashMap::new();
    let bytes = json;
    let mut idx = 0usize;
    while let Some(a) = bytes[idx..].find("\"archetype\"") {
        let astart = idx + a;
        let name = extract_string_after(bytes, astart, "\"archetype\"");
        let spectrum = extract_f32_array_after(bytes, astart, "\"spectrum\"");
        let slope = extract_f32_after(bytes, astart, "\"slope_p95\"");
        if let (Some(name), Some(spec), Some(slope)) = (name, spectrum, slope) {
            if spec.len() == N_BANDS {
                let mut arr = [0f32; N_BANDS];
                arr.copy_from_slice(&spec);
                out.insert(name, Fingerprint { spectrum: arr, slope_p95: slope });
            }
        }
        idx = astart + "\"archetype\"".len();
    }
    out
}

fn extract_string_after(s: &str, from: usize, key: &str) -> Option<String> {
    let k = s[from..].find(key)? + from;
    let colon = s[k..].find(':')? + k;
    let q1 = s[colon..].find('"')? + colon + 1;
    let q2 = s[q1..].find('"')? + q1;
    Some(s[q1..q2].to_string())
}

fn extract_f32_after(s: &str, from: usize, key: &str) -> Option<f32> {
    let k = s[from..].find(key)? + from;
    let colon = s[k..].find(':')? + k + 1;
    let rest = &s[colon..];
    let end = rest.find(|c: char| c == ',' || c == '}' || c == '\n').unwrap_or(rest.len());
    rest[..end].trim().parse::<f32>().ok()
}

fn extract_f32_array_after(s: &str, from: usize, key: &str) -> Option<Vec<f32>> {
    let k = s[from..].find(key)? + from;
    let lb = s[k..].find('[')? + k + 1;
    let rb = s[lb..].find(']')? + lb;
    let mut v = Vec::new();
    for tok in s[lb..rb].split(',') {
        if let Ok(f) = tok.trim().parse::<f32>() { v.push(f); }
    }
    Some(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    const SAMPLE: &str = r#"[
      { "archetype":"mountain","tile_count":11,
        "spectrum":[0.02,0.04,0.07,0.12,0.18,0.22,0.21,0.14],
        "slope_p95":0.888,"ridge_character":0.001 },
      { "archetype":"grassland","tile_count":11,
        "spectrum":[0.30,0.25,0.18,0.12,0.08,0.04,0.02,0.01],
        "slope_p95":0.181,"ridge_character":0.002 } ]"#;

    #[test]
    fn parses_two_archetypes() {
        let m = parse(SAMPLE);
        assert_eq!(m.len(), 2);
        let mt = m.get("mountain").unwrap();
        assert!((mt.slope_p95 - 0.888).abs() < 1e-4);
        assert!((mt.spectrum.iter().sum::<f32>() - 1.0).abs() < 0.02);
        let g = m.get("grassland").unwrap();
        assert!(g.slope_p95 < mt.slope_p95);
        // grassland energy is coarser-weighted in this sample; mountain finer.
        assert!(g.spectrum[0] > mt.spectrum[0]);
    }
}
