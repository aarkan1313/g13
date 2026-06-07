//! Offline DEM distillation tool (M2.3). Reads labeled DEM .tif tiles + their
//! .tif.json sidecars, groups by terrain archetype, and emits a per-archetype
//! fingerprint file (radial amplitude spectrum + slope ceiling + ridge character)
//! for the runtime spectral field (M2.4). OFFLINE ONLY — never linked into the
//! Godot runtime; the runtime never opens a .tif (03_DEM_CATALOG hard rule).

mod archetype;
mod sidecar;
mod analyze;
mod fingerprint;
mod kernel;

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

use analyze::N_BANDS;
use fingerprint::Accum;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    // M2.4d kernel spike subcommand:
    //   dem_distill kernels <dems_opentopo_dir> [archetype ...]
    // Extracts surface kernels for the named archetypes (default mountain+grassland),
    // measures count / asset-size / detrend-quality / diversity, prints the report.
    if args.len() >= 3 && args[1] == "kernels" {
        let dir = &args[2];
        let arches: Vec<String> = if args.len() > 3 {
            args[3..].to_vec()
        } else {
            vec!["mountain".to_string(), "grassland".to_string()]
        };
        return run_kernel_spike(dir, &arches);
    }
    if args.len() != 3 {
        eprintln!("usage: dem_distill <dems_opentopo_dir> <out_fingerprints.json>");
        eprintln!("   or: dem_distill kernels <dems_opentopo_dir> [archetype ...]");
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

/// M2.4d kernel SPIKE: extract surface kernels for the requested archetypes from
/// the real DEMs, MEASURE the things that decide the runtime representation
/// (count, raw-atlas asset size, detrend quality, within-archetype diversity),
/// and print the report. This is the DECISION instrument — it does NOT write the
/// runtime asset yet (that follows the decision). SKIPS cleanly if the DEM dir is
/// absent (so it's safe to run anywhere).
fn run_kernel_spike(dir: &str, arches: &[String]) -> ExitCode {
    // Spike parameters (sensible starts; the report tells us if they need tuning).
    const SIZE: usize = 256; // patch side (samples)
    const STRIDE: usize = 256; // non-overlapping (honest distinct-patch diversity)
    const DETREND_R: usize = SIZE / 4; // 64 — wide low-pass = the regional ramp

    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("SKIP kernel spike: cannot read DEM dir {dir}: {e}");
            eprintln!("(the labeled DEMs live on disk only, gitignored — run where they are)");
            return ExitCode::SUCCESS; // skip, not fail
        }
    };

    // archetype -> all kernels extracted for it.
    let mut by_arche: BTreeMap<String, Vec<kernel::Kernel>> = BTreeMap::new();
    let mut tiles_used = 0u32;

    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("tif") {
            continue;
        }
        let stem = match path.file_stem().and_then(|s| s.to_str()) {
            Some(s) => s,
            None => continue,
        };
        let arche = match archetype::archetype_of(stem) {
            Some(a) => a,
            None => continue,
        };
        if !arches.iter().any(|a| a == arche) {
            continue;
        }
        let (h, w, ht) = match read_tif_f32(&path) {
            Ok(t) => t,
            Err(e) => {
                eprintln!("skip (tif read {stem}): {e}");
                continue;
            }
        };
        let ks = kernel::extract_kernels(&h, w, ht, arche, SIZE, STRIDE, DETREND_R);
        println!("  {arche:<10} {stem}  ({w}x{ht}) -> {} kernels", ks.len());
        by_arche.entry(arche.to_string()).or_default().extend(ks);
        tiles_used += 1;
    }

    println!("\n=== M2.4d KERNEL SPIKE REPORT (patch {SIZE}, stride {STRIDE}, detrend_r {DETREND_R}) ===");
    println!("tiles used: {tiles_used}");
    let per_kernel_bytes = kernel::kernel_bytes(SIZE);
    let mut grand_kernels = 0usize;
    for arche in arches {
        let ks = match by_arche.get(arche) {
            Some(k) if !k.is_empty() => k,
            _ => {
                println!("  {arche:<10}: NO kernels extracted");
                continue;
            }
        };
        grand_kernels += ks.len();
        let bytes = ks.len() * per_kernel_bytes;
        // Diversity: mean pairwise correlation over a sample of distinct pairs.
        // Low mean correlation -> blending won't visibly repeat.
        let mut corr_sum = 0.0f64;
        let mut pairs = 0u32;
        let step = (ks.len() / 16).max(1); // sample ~16 kernels to bound cost
        let mut idx: Vec<usize> = (0..ks.len()).step_by(step).collect();
        idx.truncate(16);
        for i in 0..idx.len() {
            for j in (i + 1)..idx.len() {
                corr_sum += kernel::correlation(&ks[idx[i]].data, &ks[idx[j]].data);
                pairs += 1;
            }
        }
        let mean_corr = if pairs > 0 { corr_sum / pairs as f64 } else { 1.0 };
        println!(
            "  {arche:<10}: {} kernels  {:.1} MB raw-atlas  mean_pair_corr {:.3} {}",
            ks.len(),
            bytes as f64 / (1024.0 * 1024.0),
            mean_corr,
            if mean_corr < 0.5 { "(diverse OK)" } else { "(REPETITIVE?)" }
        );
    }
    // Extrapolate raw-atlas size to all 12 archetypes (rough: scale by mean/arche).
    let arche_done = arches
        .iter()
        .filter(|a| by_arche.get(*a).map_or(false, |k| !k.is_empty()))
        .count()
        .max(1);
    let mean_bytes_per_arche = grand_kernels * per_kernel_bytes / arche_done;
    let proj_12 = mean_bytes_per_arche * 12;
    println!(
        "\nraw-atlas (all patches) projection: {} kernels = {:.1} MB; ~12 archetypes ~= {:.1} MB (INFEASIBLE)",
        grand_kernels,
        (grand_kernels * per_kernel_bytes) as f64 / (1024.0 * 1024.0),
        proj_12 as f64 / (1024.0 * 1024.0)
    );

    // DECISION (pillar-derived, see kernel.rs header): ship a CURATED SUBSET at
    // reduced resolution. 32 kernels/archetype @ 128^2 (~24 MB for 12) — diverse
    // enough (corr~0) and carries all the character the 256m macro grid can use.
    const KEEP: usize = 32;
    const OUT_SIZE: usize = 128;
    let mut groups: Vec<(String, Vec<kernel::Kernel>)> = Vec::new();
    for arche in arches {
        if let Some(ks) = by_arche.get(arche) {
            if !ks.is_empty() {
                groups.push((arche.clone(), kernel::curate(ks, KEEP, OUT_SIZE)));
            }
        }
    }
    let blob = kernel::serialize_atlas(&groups, OUT_SIZE as u32);
    let asset_path = "wg-13/data/dem_kernels.bin";
    if let Some(parent) = Path::new(asset_path).parent() {
        let _ = fs::create_dir_all(parent);
    }
    match fs::write(asset_path, &blob) {
        Ok(()) => {
            let total_kernels: usize = groups.iter().map(|(_, k)| k.len()).sum();
            println!(
                "\nWROTE {asset_path}: {} kernels ({} archetypes) @ {OUT_SIZE}^2 = {:.2} MB",
                total_kernels,
                groups.len(),
                blob.len() as f64 / (1024.0 * 1024.0)
            );
            // Small JSON index next to the .bin (human-readable manifest).
            let idx: Vec<String> = groups
                .iter()
                .map(|(n, k)| format!("    {{ \"archetype\": \"{n}\", \"kernels\": {} }}", k.len()))
                .collect();
            let json = format!(
                "{{\n  \"format\": \"WGK1\",\n  \"kernel_size\": {OUT_SIZE},\n  \"keep_per_archetype\": {KEEP},\n  \"archetypes\": [\n{}\n  ]\n}}\n",
                idx.join(",\n")
            );
            let _ = fs::write("wg-13/data/dem_kernels.index.json", json);
        }
        Err(e) => {
            eprintln!("cannot write {asset_path}: {e}");
            return ExitCode::FAILURE;
        }
    }
    ExitCode::SUCCESS
}
