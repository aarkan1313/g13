//! Offline DEM distillation tool (M2.3). Reads labeled DEM .tif tiles + their
//! .tif.json sidecars, groups by terrain archetype, and emits a per-archetype
//! fingerprint file (radial amplitude spectrum + slope ceiling + ridge character)
//! for the runtime spectral field (M2.4). OFFLINE ONLY — never linked into the
//! Godot runtime; the runtime never opens a .tif (03_DEM_CATALOG hard rule).

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

        // Use the .tif's real dimensions for spacing (ground truth; the sidecar's
        // width/height are optional and absent on some tiles).
        let (dx, dz) = analyze::cell_spacing_m(
            side.bounds.west, side.bounds.east, side.bounds.south, side.bounds.north,
            w as u32, ht as u32);
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
