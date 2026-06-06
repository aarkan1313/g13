# M2.4 — Spectral-Shaped Runtime Field Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the runtime field synthesize procedural terrain whose per-octave amplitudes come from each biome's MEASURED DEM fingerprint (M2.3's `dem_fingerprints.json`), so terrain reads as believable real-world landforms instead of generic-fBM "oatmeal."

**Architecture:** Rust loads `dem_fingerprints.json` at init, maps each of the 10 biomes to a DEM archetype, and packs that archetype's 8-band amplitude spectrum + slope ceiling into the per-biome GPU table (binding 2, alongside the existing climate centroid). The GLSL field synthesizes height as a domain-warped octave sum where octave `o`'s amplitude = `spectrum[o]`, then clamps slope to the biome's measured ceiling so it stays continuous (no cliffs). Biome selection (M2.2) is unchanged and chooses which spectrum applies. Shared continental base keeps borders continuous. Quality-first: NOT performance-tuned (that's M2.6).

**Tech Stack:** GLSL compute (field_height.glsl), Rust gdext (field_gpu.rs/page_pool.rs/field_compute.rs load + pack the fingerprints), serde_json (parse the fingerprint file in the runtime — reading a 3.5 KB JSON of NUMBERS is allowed; the .tif hard-rule is about DEM raster data, not the distilled params).

**Scope (this plan):** wire ALL biomes to their archetype fingerprint (the data's already there for all 12 archetypes, so per-biome wiring is uniform — no reason to artificially limit to 3), but the VISUAL gate review focuses first on the clearest contrasts (mountain rock / grassland / desert). If the spectral approach looks wrong, we catch it on those three before trusting the rest.

---

## Pre-flight (read before Task 1)

Current field (M2.2, after the revert) — confirmed structure:
- `field_height.glsl`: `Params` block (binding 1) has height+climate+biome-classifier params ending at `biome_alt_freq`. `BiomeTable` (binding 2) = `vec4 biome_centroid[]` (.xyz centroid, .w unused). `main()` does `h = fbm(world_xz, seed)` then climate then `biome_id`. `fbm` = generic 0.5/octave value-noise sum.
- `field_gpu.rs`: `PageParams` mirrors the Params block; `BIOME_STRIDE = 4` (one vec4/biome); `set_biome_centroids(&PackedFloat32Array)` uploads the table; `FIELD_CHANNELS = 4`.
- `page_pool.rs`: `BIOME_CENTROIDS: [[f32;4];10]` roster + weights; `initialize()` flattens + pushes them.
- `field_compute.rs`: a parallel copy of the roster for the test oracle.

The fingerprint file `wg-13/data/dem_fingerprints.json` is an array of `{archetype, tile_count, spectrum:[8], slope_p95, ridge_character}`.

**Biome → archetype map** (10 M2.2 biomes → DEM archetypes; both lists are fixed):
```
0 snow         -> glacial
1 tundra       -> tundra
2 taiga        -> temperate
3 mountain rock-> mountain
4 grassland    -> grassland
5 temp forest  -> temperate
6 temp rainfor.-> rainforest
7 desert       -> desert
8 savanna      -> grassland
9 trop rainfor.-> rainforest
```

**Spectrum convention:** `spectrum[0]` = coarsest band, `spectrum[7]` = finest. In synthesis, octave `o` (freq `base_freq * 2^o`) uses weight `spectrum[o]`. The weights sum to 1.0; multiply by `amplitude` for world units.

---

## File Structure

- `rust/gdext/src/fingerprints.rs` — NEW. Load + parse `dem_fingerprints.json`; expose `archetype_spectrum(name) -> ([f32;8], slope_p95)`. One responsibility: turn the JSON into lookups.
- `rust/gdext/src/field_gpu.rs` — `BIOME_STRIDE` grows (centroid + 8 spectrum + slope_ceiling); `PageParams` unchanged in count (synthesis reads the table, not new Params). `set_biome_centroids` doc updated (now packs spectrum too).
- `rust/gdext/src/page_pool.rs` — `initialize()` loads fingerprints, builds the per-biome packed table (centroid from the roster + spectrum/slope from the biome→archetype map), pushes it. Add the biome→archetype const.
- `rust/gdext/src/field_compute.rs` — same packed-table build for the test oracle (so gates reproduce the runtime).
- `rust/gdext/src/lib.rs` — `mod fingerprints;`.
- `wg-13/shaders/field_height.glsl` — `BiomeTable` row grows; new `spectral_height()` synthesis replaces `fbm()` for the height channel; slope clamp; domain warp.
- `wg-13/tests/m2_4_spectral_check.gd` — NEW gate: determinism; per-biome roughness tracks the fingerprint slope ceiling (mountain rough > grassland); no cliffs (max step bounded by biome slope ceiling × spacing × margin).
- `wg-13/captures/shape_capture.gd` — already exists (low-altitude); reuse for the visual gate.

---

## Task 1: Runtime fingerprint loader (Rust)

**Files:**
- Create: `rust/gdext/src/fingerprints.rs`
- Modify: `rust/gdext/src/lib.rs` (add `mod fingerprints;`)
- Test: in `rust/gdext/src/fingerprints.rs` (`#[cfg(test)]`)

- [ ] **Step 1: Write the loader + a parse test**

Create `rust/gdext/src/fingerprints.rs`:
```rust
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
    // The file is an array of objects; split on "archetype" occurrences is
    // fragile, so use a tiny tolerant scan: find each "archetype":"X" and the
    // following "spectrum":[...] and "slope_p95":N.
    let bytes = json;
    let mut idx = 0usize;
    while let Some(a) = bytes[idx..].find("\"archetype\"") {
        let astart = idx + a;
        // archetype value
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
```

In `rust/gdext/src/lib.rs`, add near the other `mod` lines:
```rust
mod fingerprints;
```

- [ ] **Step 2: Run the test**

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo test --manifest-path "D:\world gen 13\rust\Cargo.toml" -p wg13 fingerprints
```
Expected: `parses_two_archetypes ... ok`.

- [ ] **Step 3: Commit**

```powershell
git add rust/gdext/src/fingerprints.rs rust/gdext/src/lib.rs
git commit -F a-temp-message-file
```
Message: `[M2.4] runtime fingerprint loader (parse dem_fingerprints.json, numbers only)`

---

## Task 2: Grow the biome GPU table to carry the spectrum (Rust field_gpu)

**Files:**
- Modify: `rust/gdext/src/field_gpu.rs`

The per-biome GPU row grows from 1 vec4 (centroid) to **4 vec4** (16 floats):
`[temp_c, moist_c, alt_c, slope_p95]`, `[spec0..3]`, `[spec4..7]`, `[_pad x4]`.
`set_biome_centroids` already uploads a flat f32 buffer of whatever length, so
only the STRIDE constant + the GLSL reader change; the upload path is unchanged.

- [ ] **Step 1: Change BIOME_STRIDE and document the row layout**

In `rust/gdext/src/field_gpu.rs`, replace:
```rust
/// Floats per biome centroid row in the pushed BiomeTable (vec4 stride for
/// std430): [temp_c, moist_c, alt_c, _pad].
pub const BIOME_STRIDE: usize = 4;
```
with:
```rust
/// Floats per biome row in the pushed BiomeTable (std430, vec4-aligned). M2.4
/// grows the row to carry the DEM spectral fingerprint alongside the climate
/// centroid. Layout (16 floats = 4 vec4):
///   row[0] = (temp_c, moist_c, alt_c, slope_p95)
///   row[1] = (spectrum[0..4))
///   row[2] = (spectrum[4..8))
///   row[3] = (pad, pad, pad, pad)
pub const BIOME_STRIDE: usize = 16;
```

- [ ] **Step 2: Build (will fail to link until callers updated — that's fine to check compile of this file later). Just save.**

No run yet; Tasks 3-4 update the callers that build the table. Proceed.

- [ ] **Step 3: Commit**

```powershell
git add rust/gdext/src/field_gpu.rs
git commit -F a-temp-message-file
```
Message: `[M2.4] BIOME_STRIDE 4->16: biome row now carries spectrum + slope_p95`

---

## Task 3: Build the packed table from fingerprints (Rust page_pool)

**Files:**
- Modify: `rust/gdext/src/page_pool.rs`

- [ ] **Step 1: Add the biome→archetype map + fingerprint-backed table build**

In `rust/gdext/src/page_pool.rs`, near the top (after the `BIOME_CENTROIDS` /
weights consts), add:
```rust
use crate::fingerprints;

/// Maps each of the 10 M2.2 biomes (row index = biome id) to a DEM archetype
/// whose fingerprint shapes its terrain (M2.4). DATA (00 §6).
const BIOME_ARCHETYPE: [&str; 10] = [
    "glacial",     // 0 snow / ice cap
    "tundra",      // 1 tundra
    "temperate",   // 2 taiga / boreal
    "mountain",    // 3 bare mountain rock
    "grassland",   // 4 grassland / steppe
    "temperate",   // 5 temperate forest
    "rainforest",  // 6 temperate rainforest
    "desert",      // 7 desert
    "grassland",   // 8 savanna
    "rainforest",  // 9 tropical rainforest
];

/// Path to the committed fingerprint file (res:// at runtime).
const FINGERPRINTS_PATH: &str = "res://data/dem_fingerprints.json";

/// A safe default spectrum if a fingerprint is missing (generic 0.5/octave,
/// normalized) so the field never produces NaN; slope ceiling generous.
fn default_fingerprint() -> fingerprints::Fingerprint {
    let mut s = [0f32; fingerprints::N_BANDS];
    let mut a = 1.0f32; let mut tot = 0.0f32;
    for i in 0..fingerprints::N_BANDS { s[i] = a; tot += a; a *= 0.5; }
    for v in s.iter_mut() { *v /= tot; }
    fingerprints::Fingerprint { spectrum: s, slope_p95: 1.0 }
}

/// Build the flat per-biome GPU table (BIOME_STRIDE floats/biome): centroid +
/// slope_p95 + 8-band spectrum, looking each biome's archetype up in the loaded
/// fingerprints. Falls back to a generic spectrum if a fingerprint is absent.
fn build_biome_table(fps: &std::collections::HashMap<String, fingerprints::Fingerprint>)
    -> Vec<f32> {
    let mut out = Vec::with_capacity(BIOME_CENTROIDS.len() * crate::field_gpu::BIOME_STRIDE);
    for (i, c) in BIOME_CENTROIDS.iter().enumerate() {
        let fp = fps.get(BIOME_ARCHETYPE[i]).copied().unwrap_or_else(default_fingerprint);
        // row[0]: centroid (t,m,a) + slope_p95
        out.push(c[0]); out.push(c[1]); out.push(c[2]); out.push(fp.slope_p95);
        // row[1]: spectrum[0..4)
        for k in 0..4 { out.push(fp.spectrum[k]); }
        // row[2]: spectrum[4..8)
        for k in 4..8 { out.push(fp.spectrum[k]); }
        // row[3]: pad
        out.push(0.0); out.push(0.0); out.push(0.0); out.push(0.0);
    }
    out
}
```
(Note: `BIOME_CENTROIDS` rows are `[f32;4]` `[t,m,a,_pad]` in the M2.2 code —
this reads only `c[0..3]`. Leave the centroid roster as-is.)

- [ ] **Step 2: Load fingerprints + push the packed table in initialize()**

In `page_pool.rs`, find `initialize()` (it currently flattens `BIOME_CENTROIDS`
and calls `set_biome_centroids`). Replace its biome-push block with a load of the
fingerprint file via Godot's FileAccess (res://) + `build_biome_table`:
```rust
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        if let Some(gpu) = self.gpu.as_mut() {
            let fps = load_fingerprints();
            let table = build_biome_table(&fps);
            gpu.set_biome_centroids(&PackedFloat32Array::from(table.as_slice()));
        }
        self.gpu.is_some()
    }
```
And add this free function (reads the res:// JSON via Godot FileAccess):
```rust
/// Read the committed fingerprint JSON from res:// and parse it. Empty map on
/// failure (build_biome_table then falls back to the generic spectrum).
fn load_fingerprints() -> std::collections::HashMap<String, crate::fingerprints::Fingerprint> {
    use godot::classes::file_access::ModeFlags;
    use godot::classes::FileAccess;
    let path = GString::from(FINGERPRINTS_PATH);
    match FileAccess::open(&path, ModeFlags::READ) {
        Some(f) => crate::fingerprints::parse(&f.get_as_text().to_string()),
        None => {
            godot_warn!("M2.4: could not open {FINGERPRINTS_PATH}; using generic spectrum");
            std::collections::HashMap::new()
        }
    }
}
```
Add `use godot::global::godot_warn;` if not already imported (it's in the prelude;
verify the crate compiles — if `godot_warn!` is unresolved, it's `godot::prelude::*`).

- [ ] **Step 3: Commit**

```powershell
git add rust/gdext/src/page_pool.rs
git commit -F a-temp-message-file
```
Message: `[M2.4] page_pool: load fingerprints + pack per-biome spectrum table`

---

## Task 4: Mirror the table build in the test oracle (Rust field_compute)

**Files:**
- Modify: `rust/gdext/src/field_compute.rs`

The gate's `FieldCompute` must push the SAME table so readback reproduces the
runtime. It can't easily read res:// in a `--script` test reliably, so it builds
the table from the SAME fingerprint file via std::fs at the known repo path, with
the same fallback.

- [ ] **Step 1: Add fingerprint load + table build to FieldCompute::initialize**

In `rust/gdext/src/field_compute.rs`, replace the `initialize` biome-push block
(currently flattens its local `BIOME_CENTROIDS`) with:
```rust
    #[func]
    fn initialize(&mut self, shader_glsl_path: GString) -> bool {
        self.gpu = FieldGpu::new(&shader_glsl_path);
        if let Some(gpu) = self.gpu.as_mut() {
            // Reproduce the runtime table: same fingerprints, same packing.
            let fps = load_fingerprints_fc();
            let table = build_biome_table_fc(&fps);
            gpu.set_biome_centroids(&PackedFloat32Array::from(table.as_slice()));
        }
        self.gpu.is_some()
    }
```
Add (mirroring page_pool's logic; FieldCompute keeps its own copies so the two
classes stay independent over the shared field_gpu, per the M1.2 pattern):
```rust
use crate::fingerprints;

const BIOME_ARCHETYPE: [&str; 10] = [
    "glacial","tundra","temperate","mountain","grassland",
    "temperate","rainforest","desert","grassland","rainforest",
];

fn load_fingerprints_fc() -> std::collections::HashMap<String, fingerprints::Fingerprint> {
    use godot::classes::file_access::ModeFlags;
    use godot::classes::FileAccess;
    let path = GString::from("res://data/dem_fingerprints.json");
    match FileAccess::open(&path, ModeFlags::READ) {
        Some(f) => fingerprints::parse(&f.get_as_text().to_string()),
        None => std::collections::HashMap::new(),
    }
}

fn default_fingerprint_fc() -> fingerprints::Fingerprint {
    let mut s = [0f32; fingerprints::N_BANDS];
    let mut a = 1.0f32; let mut tot = 0.0f32;
    for i in 0..fingerprints::N_BANDS { s[i] = a; tot += a; a *= 0.5; }
    for v in s.iter_mut() { *v /= tot; }
    fingerprints::Fingerprint { spectrum: s, slope_p95: 1.0 }
}

fn build_biome_table_fc(fps: &std::collections::HashMap<String, fingerprints::Fingerprint>) -> Vec<f32> {
    let mut out = Vec::with_capacity(BIOME_CENTROIDS.len() * crate::field_gpu::BIOME_STRIDE);
    for (i, c) in BIOME_CENTROIDS.iter().enumerate() {
        let fp = fps.get(BIOME_ARCHETYPE[i]).copied().unwrap_or_else(default_fingerprint_fc);
        out.push(c[0]); out.push(c[1]); out.push(c[2]); out.push(fp.slope_p95);
        for k in 0..4 { out.push(fp.spectrum[k]); }
        for k in 4..8 { out.push(fp.spectrum[k]); }
        out.push(0.0); out.push(0.0); out.push(0.0); out.push(0.0);
    }
    out
}
```

- [ ] **Step 2: Build the whole crate**

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml" -p wg13
```
Expected: builds clean (Tasks 2-4 now consistent). If `godot_warn!`/FileAccess
imports are off, fix per the compiler.

- [ ] **Step 3: Commit**

```powershell
git add rust/gdext/src/field_compute.rs
git commit -F a-temp-message-file
```
Message: `[M2.4] field_compute oracle: same fingerprint table as the runtime`

---

## Task 5: GLSL — read the spectral row + synthesize spectral height

**Files:**
- Modify: `wg-13/shaders/field_height.glsl`

- [ ] **Step 1: Grow the BiomeTable row + accessors**

Replace the `BiomeTable` block (binding 2):
```glsl
layout(set = 0, binding = 2, std430) restrict readonly buffer BiomeTable {
    vec4 biome_centroid[];   // .xyz = (temp_c, moist_c, alt_c), .w unused
};
```
with:
```glsl
// M2.4: each biome row is 4 vec4 (BIOME_STRIDE=16 floats):
//   row[0] = (temp_c, moist_c, alt_c, slope_p95)
//   row[1] = spectrum[0..4)   row[2] = spectrum[4..8)   row[3] = pad
// Spectrum = the biome archetype's MEASURED radial amplitude spectrum (M2.3),
// coarse band 0 -> fine band 7, summing ~1.0. slope_p95 = real steepness ceiling.
layout(set = 0, binding = 2, std430) restrict readonly buffer BiomeTable {
    vec4 biome_row[];
};
vec3  biome_centroid(uint b) { return biome_row[b * 4u].xyz; }
float biome_slope(uint b)    { return biome_row[b * 4u].w; }
float biome_spec(uint b, uint o) {
    // o in [0,8): row[1] holds 0..3, row[2] holds 4..7.
    vec4 r = (o < 4u) ? biome_row[b * 4u + 1u] : biome_row[b * 4u + 2u];
    uint k = o & 3u;
    return (k == 0u) ? r.x : (k == 1u) ? r.y : (k == 2u) ? r.z : r.w;
}
```

- [ ] **Step 2: Update biome_id to use the accessor**

In `biome_id(...)`, change the centroid read:
```glsl
        vec3 d = (p - biome_centroid[b].xyz) * w;
```
to:
```glsl
        vec3 d = (p - biome_centroid(b)) * w;
```

- [ ] **Step 3: Add domain warp + spectral synthesis functions**

Immediately BEFORE `void main()`, add:
```glsl
// M2.4 spectral synthesis. Domain-warped octave sum where octave o's amplitude
// is the biome archetype's MEASURED spectrum weight (M2.3 fingerprint), not a
// generic 0.5^o. This makes each biome carry real-Earth structure (mountains
// ridged + macro-heavy, plains fine-and-flat). 8 octaves from base_freq.
vec2 warp2(vec2 p, uint seed) {
    return vec2(value_noise(p, seed), value_noise(p, seed ^ 0x9e3779b9u)) - 0.5;
}

const uint SPEC_OCTAVES = 8u;
float spectral_height(vec2 world_xz, uint seed, uint biome) {
    // Domain warp the low frequencies for organic shapes (warp amount scales with
    // amplitude so it bends features, not pixels).
    vec2 wp = world_xz + (amplitude * 0.6) * warp2(world_xz * (base_freq * 0.5), seed ^ 0x57415250u);
    float freq = base_freq;
    float sum = 0.0;
    for (uint o = 0u; o < SPEC_OCTAVES; o++) {
        // Low octaves warped (organic), high octaves plain (crisp + cheap).
        vec2 p = (o < 2u) ? wp : world_xz;
        float n = value_noise(p * freq, seed + o * 0x68bc21ebu);
        sum += biome_spec(biome, o) * n;     // amplitude = measured spectrum weight
        freq *= 2.0;
    }
    // spectrum sums ~1.0, so sum is ~[0,1]; scale to world height units.
    return sum * amplitude;
}
```

- [ ] **Step 4: Rewrite main() to use spectral height + slope clamp**

Replace the body of `main()` from `float h = fbm(...)` through the height write:
```glsl
    // absolute world position of this cell (00 §5)
    vec2 world_xz = vec2(origin_x, origin_z) + vec2(cell) * spacing;
    uint useed = uint(seed);

    // Biome + climate from the biome-INDEPENDENT macro altitude (no circularity).
    float alt = macro_altitude(world_xz, useed);
    vec2 c = climate(world_xz, alt * amplitude, useed);
    float bid = biome_id(c.x, c.y, alt);
    uint b = uint(bid + 0.5);

    // M2.4: height = shared continental base (biome-independent, continuous across
    // borders) + this biome's SPECTRAL relief (octave amplitudes from the DEM
    // fingerprint). Different biomes carry different real-Earth structure; the
    // shared base keeps borders continuous (a relief-character step, not a cliff).
    float base_h = alt * amplitude * 0.5;
    float relief = spectral_height(world_xz, useed, b);
    float h = base_h + relief;

    uint o = (cell.y * page_res + cell.x) * 4u;
    field[o + 0u] = h;
    field[o + 1u] = c.x;
    field[o + 2u] = c.y;
    field[o + 3u] = bid;
```
(Delete the now-unused `fbm` function if the compiler flags it unused; GLSL
tolerates it but remove for cleanliness. `climate`'s altitude arg now takes
`alt*amplitude`; verify `climate`'s internal `alt_cool` normalizes over
`amplitude` — if it still divides by `amplitude*0.5` from M2.1, change to
`/ amplitude` so the cooling matches the new regional-altitude proxy. Read the
climate fn and adjust the one normalization line accordingly.)

- [ ] **Step 5: Build the runtime DLL + sanity-run a height gate**

Close any Godot first (DLL lock). Run:
```powershell
$g = Get-Process -Name "Godot*" -ErrorAction SilentlyContinue; if ($g) { & "D:\world gen 13\run.ps1" -Stop }
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml" -p wg13
$gx = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $gx --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m1_2_field_check.gd
```
Expected: build clean; `m1_2` PASS (shader compiles, field deterministic + continuous). If `m1_2` continuity FAILS with a huge step, the slope clamp (Task 6) is needed — proceed, but note it.

- [ ] **Step 6: Commit**

```powershell
git add wg-13/shaders/field_height.glsl
git commit -F a-temp-message-file
```
Message: `[M2.4] GLSL: spectral height synthesis (per-biome DEM spectrum) + warp`

---

## Task 6: Slope clamp (no cliffs, from the real ceiling)

**Files:**
- Modify: `wg-13/shaders/field_height.glsl`

The measured spectra can put real energy in fine octaves; at 4 m cells that can
exceed a believable slope. Clamp the per-octave high-frequency contribution so the
synthesized slope stays within the biome's measured `slope_p95` (× a margin).
Simplest robust approach: attenuate the finest octaves' weights by a factor that
keeps the worst-case per-cell step ≤ `slope_p95 * spacing * MARGIN`.

- [ ] **Step 1: Add a per-octave slope-aware attenuation in spectral_height**

In `spectral_height`, replace the accumulation loop with a slope-bounded version:
```glsl
    float freq = base_freq;
    float sum = 0.0;
    float slope_ceiling = biome_slope(biome);    // rise/run, from the DEM
    for (uint o = 0u; o < SPEC_OCTAVES; o++) {
        vec2 p = (o < 2u) ? wp : world_xz;
        float n = value_noise(p * freq, seed + o * 0x68bc21ebu);
        // This octave's max per-cell slope contribution ~ weight*amplitude * 2 *
        // (spacing*freq). Cap the weight so it can't exceed the ceiling alone.
        float w = biome_spec(biome, o);
        float oct_slope = w * amplitude * 2.0 * (spacing * freq) / max(amplitude, 1.0);
        // (oct_slope is rise/run in normalized units; clamp weight if it would
        //  blow the ceiling — generous 1.5x margin so terrain stays steep-but-sane.)
        float cap = (slope_ceiling * 1.5) / max(oct_slope, 1e-6);
        if (cap < 1.0) w *= cap;
        sum += w * n;
        freq *= 2.0;
    }
    return sum * amplitude;
```
Remove the old `sum += biome_spec(...)` line if duplicated.

- [ ] **Step 2: Build + verify continuity gate**

Run:
```powershell
$env:CARGO_TARGET_DIR = "D:\world gen 13\rust\target"
cargo build --manifest-path "D:\world gen 13\rust\Cargo.toml" -p wg13
$gx = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $gx --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m1_2_field_check.gd
```
Expected: `m1_2` PASS, continuity max step within limit (no near-vertical cliffs).

- [ ] **Step 3: Commit**

```powershell
git add wg-13/shaders/field_height.glsl
git commit -F a-temp-message-file
```
Message: `[M2.4] GLSL: slope-bounded octave weights (no cliffs, from DEM slope_p95)`

---

## Task 7: M2.4 test gate — per-biome roughness tracks the fingerprint

**Files:**
- Create: `wg-13/tests/m2_4_spectral_check.gd`

- [ ] **Step 1: Write the gate**

Create `wg-13/tests/m2_4_spectral_check.gd`:
```gdscript
extends SceneTree
# M2.4 gate — spectral-shaped field, proven by readback.
#   1. DETERMINISM: same page+seed -> identical heights.
#   2. PER-BIOME STRUCTURE DIFFERS: a mountain-region page is rougher than a
#      grassland-region page (the DEM spectrum/slope taking effect).
#   3. NO CLIFF: max adjacent step bounded (slope clamp working).
# Run: godot --rendering-driver vulkan --path wg-13 --script res://tests/m2_4_spectral_check.gd

const SHADER := "res://shaders/field_height.glsl"
const RES := 128
const SPACING := 4.0
const SEED := 1234.0
const OCT := 5
const FREQ := 0.0015
const AMP := 240.0

var _failed := false
func _fail(m): _failed = true; print("FAIL: ", m)

func _avg_step(h: PackedFloat32Array) -> float:
	var s := 0.0; var n := 0
	for z in range(RES):
		for x in range(RES - 1):
			s += absf(h[z*RES+x+1] - h[z*RES+x]); n += 1
	return s / maxf(n, 1)

func _max_step(h: PackedFloat32Array) -> float:
	var m := 0.0
	for z in range(RES):
		for x in range(RES - 1):
			m = maxf(m, absf(h[z*RES+x+1] - h[z*RES+x]))
	return m

func _init() -> void:
	var fc = ClassDB.instantiate("FieldCompute")
	if fc == null or not fc.initialize(SHADER):
		_fail("FieldCompute init failed (need vulkan)"); _finish(); return

	# Determinism.
	var a: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	var b: PackedFloat32Array = fc.produce_page(0.0, 0.0, SPACING, SEED, RES, OCT, FREQ, AMP)
	if a.size() != RES*RES: _fail("page size"); _finish(); return
	if a != b: _fail("determinism: same seed differs"); else: print("PASS: determinism")

	# Per-biome structure: scan many pages, bucket avg-roughness by majority biome,
	# assert mountain(3) rougher than grassland(4). (Reuses produce_biome_page.)
	var rough := {}; var cnt := {}
	for iz in range(-3, 4):
		for ix in range(-3, 4):
			var ox := ix * 12000.0; var oz := iz * 12000.0
			var h: PackedFloat32Array = fc.produce_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)
			var bm: PackedFloat32Array = fc.produce_biome_page(ox, oz, SPACING, SEED, RES, OCT, FREQ, AMP)
			var counts := {}
			for v in bm:
				var id := int(round(v)); counts[id] = counts.get(id, 0) + 1
			var maj := 0; var mc := -1
			for id in counts:
				if counts[id] > mc: mc = counts[id]; maj = id
			rough[maj] = rough.get(maj, 0.0) + _avg_step(h)
			cnt[maj] = cnt.get(maj, 0) + 1
	var mean := {}
	for id in cnt: mean[id] = rough[id] / cnt[id]
	for id in mean: print("INFO: biome %d avg roughness %.3f (%d pages)" % [id, mean[id], cnt[id]])
	if mean.has(3) and mean.has(4):
		if mean[3] > mean[4] * 1.3:
			print("PASS: per-biome structure — mountain %.3f > 1.3x grassland %.3f" % [mean[3], mean[4]])
		else:
			_fail("mountain %.3f not >1.3x grassland %.3f" % [mean[3], mean.get(4, 0.0)])
	else:
		print("INFO: mountain/grassland not both present in sample; structure check skipped")

	# No cliff: max step over the origin page bounded (slope clamp). AMP*0.6 is a
	# generous steep-mountain allowance; a true discontinuity blows past it.
	var ms := _max_step(a)
	if ms > AMP * 0.6: _fail("cliff: max step %.1f > %.1f" % [ms, AMP*0.6])
	else: print("PASS: no cliff — max step %.1f within %.1f" % [ms, AMP*0.6])

	_finish()

func _finish() -> void:
	print("M2.4 RESULT: ", "FAIL" if _failed else "PASS")
	quit(1 if _failed else 0)
```

- [ ] **Step 2: Run the gate**

Run:
```powershell
$gx = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $gx --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://tests/m2_4_spectral_check.gd
```
Expected: `M2.4 RESULT: PASS` — determinism, mountain rougher than grassland, no
cliff. If "mountain not >1.3x grassland", the spectrum isn't differentiating —
investigate (Phase 1 debugging) before weakening the assert.

- [ ] **Step 3: Commit**

```powershell
git add wg-13/tests/m2_4_spectral_check.gd
git commit -F a-temp-message-file
```
Message: `[M2.4] gate: spectral field determinism + per-biome roughness + no cliff`

---

## Task 8: Full regression suite + VISUAL gate (capture + PARK)

**Files:**
- (no code) run all gates; produce low-altitude captures; PARK for the human.

- [ ] **Step 1: Run the full gate suite**

Run each and confirm PASS (the spectral field touched the height path, so the M1
seam/continuity/collision gates are the guardrails):
```powershell
$gx = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
$gates = @("m1_2_field_check","m1_4_seam_check","m1_5c_coverage_check","m1_5c_overlap_check",
  "m1_6_frametime_check","m1_7a_heights_check","m1_7b_collision_check","m1_7c_stand_check",
  "m1_9b_eager_spread_check","hud_smoke_check","tour_smoke_check",
  "m2_1_climate_check","m2_2_biome_check","m2_4_spectral_check")
foreach ($t in $gates) {
  $out = & $gx --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script "res://tests/$t.gd" 2>&1
  "{0,-26} {1}" -f $t, ((("$($out | Select-String 'RESULT' | Select-Object -Last 1)") -replace '.*RESULT:\s*','').Trim())
}
```
Expected: all PASS. (Also run the Rust dem_distill suite once: `cargo test -p dem_distill` — should still pass, untouched.)

- [ ] **Step 2: Capture low-altitude shape shots**

Run:
```powershell
$gx = "C:\Godot\v4.6.2\Godot_v4.6.2-stable_mono_win64\Godot_v4.6.2-stable_mono_win64_console.exe"
& $gx --rendering-driver vulkan --path "D:\world gen 13\wg-13" --script res://captures/shape_capture.gd
```
Expected: `_captures/shape_low0..2.png` saved. Open them; the terrain should read
as believable landforms (not oatmeal, not mesas). If it looks wrong, STOP and
debug systematically — do NOT tune blindly.

- [ ] **Step 3: Update docs (PROGRESS, DRIFT_LOG) + PARK the visual gate**

Mark M2.4 test-gate green in PROGRESS; PARK the visual gate (human flies low).
DRIFT_LOG: M2.4 spectral field built, test gate PASS, captures saved, PARKED for
the human; whether the DEM-spectral approach reads as believable is the human call.

- [ ] **Step 4: Commit**

```powershell
git add wg-13 "plans and docs/plans/"
git commit -F a-temp-message-file
```
Message: `[M2.4] spectral field: full suite green, visual gate PARKED (captures saved)`

- [ ] **Step 5: Launch for the human**

Run `.\run.ps1`; tell the human to fly LOW (and press V to correlate biome
colors with shape). The visual gate: does it read as believable real-world
terrain, distinct per biome, no cliffs? This is the make-or-break review of the
whole DEM-spectral pivot.

---

## Notes for the implementer

- **Commit mechanic:** write each message to a temp file, `git commit -F <file>`,
  ASCII, end with the repo's `Co-Authored-By: Claude Opus 4.8 (1M context)` trailer.
- **target-dir override:** every cargo command pins `$env:CARGO_TARGET_DIR`.
- **DLL lock:** close Godot (`run.ps1 -Stop`) before `cargo build -p wg13`.
- **GPU gates need `--rendering-driver vulkan`** (not headless).
- **The .tif hard rule still holds:** the runtime reads the small JSON of numbers,
  NEVER a `.tif`. If you find yourself adding a `.tif` read to the runtime, STOP.
- **If the visual gate fails:** this is the moment of truth. If spectral terrain
  still looks wrong, do NOT thrash on parameters — capture evidence, debug the ONE
  thing systematically, and if the spectrum approach itself is the problem, bring
  it to the human (it may mean the synthesis method needs rethinking, not tuning).
- **ridge_character** is intentionally NOT used yet (M2.3 flagged it weak). M2.4
  uses spectrum + slope only; ridge can come later if needed.
- **Performance is NOT this plan's concern** (M2.6). If the 8-octave warp is slow,
  note it for M2.6; don't optimize now.
```
