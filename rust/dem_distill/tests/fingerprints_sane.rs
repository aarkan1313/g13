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
