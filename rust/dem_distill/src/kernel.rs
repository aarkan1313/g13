//! M2.4d: offline DEM SURFACE-KERNEL extraction.
//!
//! A "kernel" is a real DEM patch with the continental trend removed and
//! normalized to [0,1] -> it carries the SURFACE CHARACTER (ridge structure,
//! drainage incision, fluting) of real terrain, NOT its absolute elevation. The
//! runtime macro blends these kernels in to give procedurally-placed structure a
//! believable real-world surface (M2.4d spec §5.1/§5.2).
//!
//! OFFLINE ONLY. The runtime NEVER opens a `.tif` (00 §6); it reads only the
//! compact binary asset emitted from these kernels.
//!
//! DETREND = subtract a large-sigma blur of the patch. The blur is the
//! continental/regional ramp (what procedural composition will place); the
//! residual is the texture (what real DEMs supply). NORMALIZE the residual to
//! [0,1] so kernels from different elevations/regions are comparable + blendable.
//!
//! SPIKE FINDINGS (2026-06-07, `dem_distill kernels`, patch 256 / stride 256 /
//! detrend_r 64, on the real mountain+grassland DEMs):
//!   - DIVERSITY is excellent: mean pairwise correlation ~0.00 (mountain 0.004,
//!     grassland -0.001) -> detrended kernels are statistically independent, so
//!     blending them does NOT visibly repeat. The #1 risk (non-repeating infinite
//!     world) is de-risked: real DEM patches carry plenty of distinct character.
//!   - RAW-ATLAS (ship every patch) is INFEASIBLE on size: ~1.9 GB/archetype,
//!     ~23 GB for 12 archetypes (it's basically the source DEMs).
//!   DECISION: ship a CURATED SUBSET (a modest set of representative kernels per
//!   archetype, optionally downsampled), blended + domain-warped at bake time.
//!   32 kernels/arche x12 @256^2 = 96 MB; @128^2 = 24 MB. Real DEM character
//!   (actual detrended patches, NOT synthesized stats — which failed before),
//!   at a shippable size. The exact (count, resolution, tracked-vs-regenerated)
//!   is set when the asset is emitted.

/// One extracted surface kernel: a square, detrended, [0,1]-normalized patch.
#[derive(Clone, Debug)]
pub struct Kernel {
    pub archetype: String,
    pub size: usize,      // side length in samples (square)
    pub data: Vec<f32>,   // detrended + normalized to [0,1], row-major (z*size + x)
}

impl Kernel {
    pub fn cell_count(&self) -> usize {
        self.size * self.size
    }
}

/// Separable box blur (radius `r`) on a `w x ht` grid, clamped at edges. A box
/// blur applied a few times approximates a Gaussian; for detrend we only need a
/// smooth low-pass, so a single wide box pass is enough and cheap. NaN/non-finite
/// inputs are treated as the local mean (so nodata holes don't poison the blur).
pub fn box_blur(src: &[f32], w: usize, ht: usize, r: usize) -> Vec<f32> {
    if r == 0 {
        return src.to_vec();
    }
    // Horizontal pass.
    let mut tmp = vec![0.0f32; w * ht];
    for z in 0..ht {
        for x in 0..w {
            let mut sum = 0.0f64;
            let mut n = 0u32;
            let lo = x.saturating_sub(r);
            let hi = (x + r).min(w - 1);
            for xx in lo..=hi {
                let v = src[z * w + xx];
                if v.is_finite() {
                    sum += v as f64;
                    n += 1;
                }
            }
            tmp[z * w + x] = if n > 0 { (sum / n as f64) as f32 } else { 0.0 };
        }
    }
    // Vertical pass.
    let mut out = vec![0.0f32; w * ht];
    for z in 0..ht {
        let lo = z.saturating_sub(r);
        let hi = (z + r).min(ht - 1);
        for x in 0..w {
            let mut sum = 0.0f64;
            let mut n = 0u32;
            for zz in lo..=hi {
                sum += tmp[zz * w + x] as f64;
                n += 1;
            }
            out[z * w + x] = (sum / n as f64) as f32;
        }
    }
    out
}

/// Detrend a square patch: subtract its large-sigma blur (the continental ramp),
/// leaving the surface texture residual. Then normalize the residual to [0,1].
/// Returns None if the patch is degenerate (flat, or has too many nodata cells)
/// — those carry no usable character.
///
/// `detrend_radius` = blur radius in samples (≈ patch/4 is a sensible start: wide
/// enough to be "the regional trend", narrow enough to leave real ridges/valleys).
pub fn detrend_patch(patch: &[f32], size: usize, detrend_radius: usize) -> Option<Vec<f32>> {
    let n = size * size;
    debug_assert_eq!(patch.len(), n);

    // Reject patches with too many non-finite (nodata) cells.
    let finite = patch.iter().filter(|v| v.is_finite()).count();
    if finite < (n * 9) / 10 {
        return None; // >10% nodata -> skip
    }

    let trend = box_blur(patch, size, size, detrend_radius);
    let mut resid = vec![0.0f32; n];
    for i in 0..n {
        let p = if patch[i].is_finite() { patch[i] } else { trend[i] };
        resid[i] = p - trend[i];
    }

    // Normalize residual to [0,1]. Reject if the residual range is tiny (flat
    // patch — nothing to learn from it).
    let mut lo = f32::INFINITY;
    let mut hi = f32::NEG_INFINITY;
    for &v in &resid {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    let range = hi - lo;
    if !range.is_finite() || range < 1.0 {
        return None; // <1 m of residual relief -> effectively flat
    }
    for v in resid.iter_mut() {
        *v = ((*v - lo) / range).clamp(0.0, 1.0);
    }
    Some(resid)
}

/// Tile a source DEM into `size`-square patches `stride` apart, detrend +
/// normalize each, drop degenerate ones. `archetype` labels every kernel.
/// `detrend_radius` is passed through to `detrend_patch`.
pub fn extract_kernels(
    heights: &[f32],
    w: usize,
    ht: usize,
    archetype: &str,
    size: usize,
    stride: usize,
    detrend_radius: usize,
) -> Vec<Kernel> {
    let mut kernels = Vec::new();
    if w < size || ht < size || stride == 0 {
        return kernels;
    }
    let mut z0 = 0;
    while z0 + size <= ht {
        let mut x0 = 0;
        while x0 + size <= w {
            // Copy the patch.
            let mut patch = vec![0.0f32; size * size];
            for pz in 0..size {
                for px in 0..size {
                    patch[pz * size + px] = heights[(z0 + pz) * w + (x0 + px)];
                }
            }
            if let Some(data) = detrend_patch(&patch, size, detrend_radius) {
                kernels.push(Kernel {
                    archetype: archetype.to_string(),
                    size,
                    data,
                });
            }
            x0 += stride;
        }
        z0 += stride;
    }
    kernels
}

// ---- spike measurements (the DECISION instruments) -----------------------

/// Pearson correlation between two equal-length kernels' data. Used to measure
/// DIVERSITY within an archetype: low correlation between distinct kernels ->
/// blending them won't visibly repeat. ~1.0 = identical, ~0 = unrelated.
pub fn correlation(a: &[f32], b: &[f32]) -> f64 {
    let n = a.len().min(b.len());
    if n == 0 {
        return 1.0;
    }
    let (mut sa, mut sb) = (0.0f64, 0.0f64);
    for i in 0..n {
        sa += a[i] as f64;
        sb += b[i] as f64;
    }
    let (ma, mb) = (sa / n as f64, sb / n as f64);
    let (mut cov, mut va, mut vb) = (0.0f64, 0.0f64, 0.0f64);
    for i in 0..n {
        let da = a[i] as f64 - ma;
        let db = b[i] as f64 - mb;
        cov += da * db;
        va += da * da;
        vb += db * db;
    }
    if va <= 0.0 || vb <= 0.0 {
        return 1.0;
    }
    cov / (va.sqrt() * vb.sqrt())
}

/// Bytes one kernel occupies if stored as raw f32 (the raw-atlas representation).
pub fn kernel_bytes(size: usize) -> usize {
    size * size * 4
}

// ---- curation + asset emission (the shippable representation) -------------

/// Downsample a square kernel from `size` to `out` (box-average each output
/// cell over its source block). `out` must divide `size` evenly (256->128->96
/// via integer factors; we use 256->128 = factor 2). Re-normalizes to [0,1].
pub fn downsample(data: &[f32], size: usize, out: usize) -> Vec<f32> {
    if out == size {
        return data.to_vec();
    }
    let mut o = vec![0.0f32; out * out];
    for oz in 0..out {
        for ox in 0..out {
            let z0 = oz * size / out;
            let z1 = ((oz + 1) * size / out).max(z0 + 1);
            let x0 = ox * size / out;
            let x1 = ((ox + 1) * size / out).max(x0 + 1);
            let mut sum = 0.0f64;
            let mut n = 0u32;
            for z in z0..z1 {
                for x in x0..x1 {
                    sum += data[z * size + x] as f64;
                    n += 1;
                }
            }
            o[oz * out + ox] = (sum / n as f64) as f32;
        }
    }
    // Re-normalize (box-average can shrink the range slightly).
    let mut lo = f32::INFINITY;
    let mut hi = f32::NEG_INFINITY;
    for &v in &o {
        lo = lo.min(v);
        hi = hi.max(v);
    }
    let range = (hi - lo).max(1e-6);
    for v in o.iter_mut() {
        *v = ((*v - lo) / range).clamp(0.0, 1.0);
    }
    o
}

/// Curate `keep` kernels SPREAD evenly across the input list (the spike showed
/// within-archetype correlation ~0, so any even spread is diverse; an even stride
/// also guarantees every source TILE contributes, since tiles were appended in
/// order). Downsamples each kept kernel to `out_size`. Returns the curated set.
pub fn curate(kernels: &[Kernel], keep: usize, out_size: usize) -> Vec<Kernel> {
    if kernels.is_empty() {
        return Vec::new();
    }
    let keep = keep.min(kernels.len());
    let stride = (kernels.len() as f64 / keep as f64).max(1.0);
    let mut out = Vec::with_capacity(keep);
    for i in 0..keep {
        let idx = ((i as f64) * stride) as usize;
        let idx = idx.min(kernels.len() - 1);
        let k = &kernels[idx];
        out.push(Kernel {
            archetype: k.archetype.clone(),
            size: out_size,
            data: downsample(&k.data, k.size, out_size),
        });
    }
    out
}

/// Serialize a curated kernel atlas to a compact binary blob. Format (all
/// little-endian, the runtime reads this — NEVER a .tif):
///   magic   : 4 bytes  b"WGK1"
///   size    : u32      kernel side length (samples; square)
///   n_arche : u32      number of archetype blocks
///   per archetype block:
///     name_len : u32; name : name_len bytes (UTF-8 archetype key)
///     n_kernels: u32
///     n_kernels * (size*size) f32  ([0,1] data, row-major)
/// `groups` maps archetype name -> its curated kernels (all same `size`).
pub fn serialize_atlas(groups: &[(String, Vec<Kernel>)], size: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(b"WGK1");
    buf.extend_from_slice(&size.to_le_bytes());
    buf.extend_from_slice(&(groups.len() as u32).to_le_bytes());
    for (name, ks) in groups {
        let nb = name.as_bytes();
        buf.extend_from_slice(&(nb.len() as u32).to_le_bytes());
        buf.extend_from_slice(nb);
        buf.extend_from_slice(&(ks.len() as u32).to_le_bytes());
        for k in ks {
            debug_assert_eq!(k.size as u32, size);
            for &v in &k.data {
                buf.extend_from_slice(&v.to_le_bytes());
            }
        }
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn box_blur_smooths_a_spike() {
        // A single spike in a flat field -> blur spreads it, peak drops.
        let s = 9;
        let mut g = vec![0.0f32; s * s];
        g[4 * s + 4] = 9.0;
        let b = box_blur(&g, s, s, 2);
        assert!(b[4 * s + 4] < 9.0, "blur should lower the spike peak");
        assert!(b[4 * s + 3] > 0.0, "blur should spread to neighbors");
    }

    #[test]
    fn detrend_removes_a_ramp_keeps_texture() {
        // height = linear ramp (continental trend) + a small checker (texture).
        let s = 32;
        let mut g = vec![0.0f32; s * s];
        for z in 0..s {
            for x in 0..s {
                let ramp = x as f32 * 50.0; // 0..~1550 m ramp
                let tex = if (x + z) % 2 == 0 { 8.0 } else { -8.0 };
                g[z * s + x] = ramp + tex;
            }
        }
        let resid = detrend_patch(&g, s, s / 4).expect("non-degenerate");
        // The ramp should be gone: residual left/right halves have similar means.
        let mean_half = |x_lo: usize, x_hi: usize| {
            let mut sum = 0.0f64;
            let mut n = 0u32;
            for z in 2..s - 2 {
                for x in x_lo..x_hi {
                    sum += resid[z * s + x] as f64;
                    n += 1;
                }
            }
            sum / n as f64
        };
        let left = mean_half(4, 12);
        let right = mean_half(20, 28);
        assert!(
            (left - right).abs() < 0.2,
            "ramp not removed: left {left:.3} vs right {right:.3}"
        );
        // Texture survives: residual has real spread.
        let lo = resid.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = resid.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo > 0.5, "texture lost; range {}", hi - lo);
    }

    #[test]
    fn detrend_rejects_flat_patch() {
        let s = 16;
        let g = vec![500.0f32; s * s]; // perfectly flat
        assert!(detrend_patch(&g, s, s / 4).is_none(), "flat patch must be rejected");
    }

    #[test]
    fn correlation_of_identical_is_one() {
        let a = vec![0.1f32, 0.5, 0.9, 0.3, 0.7];
        assert!((correlation(&a, &a) - 1.0).abs() < 1e-9);
    }

    #[test]
    fn downsample_halves_and_stays_normalized() {
        let s = 8;
        let mut g = vec![0.0f32; s * s];
        for i in 0..s * s {
            g[i] = (i as f32) / ((s * s - 1) as f32); // 0..1 ramp
        }
        let d = downsample(&g, s, 4);
        assert_eq!(d.len(), 16);
        let lo = d.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = d.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!((lo - 0.0).abs() < 1e-5 && (hi - 1.0).abs() < 1e-5, "renormalized to [0,1]");
    }

    #[test]
    fn atlas_serializes_with_header() {
        let k = Kernel { archetype: "mountain".into(), size: 2, data: vec![0.0, 0.5, 0.5, 1.0] };
        let blob = serialize_atlas(&[("mountain".to_string(), vec![k])], 2);
        assert_eq!(&blob[0..4], b"WGK1");
        // size=2 (u32 LE) at bytes 4..8
        assert_eq!(u32::from_le_bytes([blob[4], blob[5], blob[6], blob[7]]), 2);
        // n_arche=1 at 8..12
        assert_eq!(u32::from_le_bytes([blob[8], blob[9], blob[10], blob[11]]), 1);
    }

    #[test]
    fn curate_keeps_requested_count_at_out_size() {
        let mut ks = Vec::new();
        for i in 0..100 {
            ks.push(Kernel { archetype: "x".into(), size: 8, data: vec![(i as f32) / 100.0; 64] });
        }
        let c = curate(&ks, 32, 4);
        assert_eq!(c.len(), 32);
        assert!(c.iter().all(|k| k.size == 4 && k.data.len() == 16));
    }
}
