//! Offline DEM distillation tool (M2.3). Reads labeled DEM .tif tiles + their
//! .tif.json sidecars, groups by terrain archetype, and emits a per-archetype
//! fingerprint file (radial amplitude spectrum + slope ceiling + ridge character)
//! for the runtime spectral field (M2.4). OFFLINE ONLY — never linked into the
//! Godot runtime; the runtime never opens a .tif (03_DEM_CATALOG hard rule).

#[allow(dead_code)] // wired into the pipeline in Task 7
mod archetype;
#[allow(dead_code)] // wired into the pipeline in Task 7
mod sidecar;
#[allow(dead_code)] // wired into the pipeline in Task 7
mod analyze;
#[allow(dead_code)] // wired into the pipeline in Task 7
mod fingerprint;

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
