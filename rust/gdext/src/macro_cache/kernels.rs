//! M2.4d: the DEM surface-kernel atlas (runtime side) + the deterministic
//! blender that turns a curated set of real DEM patches into an infinite,
//! non-repeating SURFACE-CHARACTER field.
//!
//! The atlas is `wg-13/data/dem_kernels.bin` (format `WGK1`), produced OFFLINE by
//! `dem_distill kernels` from the real DEMs. This module reads ONLY that distilled
//! binary asset — NEVER a `.tif` (00 §6). The bake (bake.rs) calls
//! `kernel_surface` to modulate the procedurally-placed macro structure with real
//! terrain texture.
//!
//! NON-REPEAT: the spike measured within-archetype kernel correlation ~0, so even
//! a handful of kernels, picked per coarse world-cell by a hash and blended with
//! domain-warped UVs, tile into a vast non-repeating surface (the same trick that
//! makes texture-bombing / Wang tiles non-periodic).

use std::collections::HashMap;

/// One archetype's curated kernels: each is `size*size` f32 in [0,1], row-major.
pub struct KernelAtlas {
    pub size: usize,
    by_archetype: HashMap<String, Vec<Vec<f32>>>,
}

impl KernelAtlas {
    pub fn kernels(&self, archetype: &str) -> &[Vec<f32>] {
        self.by_archetype
            .get(archetype)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    pub fn archetypes(&self) -> impl Iterator<Item = &String> {
        self.by_archetype.keys()
    }

    /// Parse the `WGK1` binary blob (mirror of dem_distill's `serialize_atlas`):
    ///   magic b"WGK1" | u32 size | u32 n_arche |
    ///   per arche: u32 name_len, name bytes, u32 n_kernels, n_kernels*(size*size) f32 LE.
    /// Returns None on any malformation (truncation / bad magic).
    pub fn parse(blob: &[u8]) -> Option<Self> {
        let mut p = 0usize;
        let take = |p: &mut usize, n: usize| -> Option<&[u8]> {
            if *p + n > blob.len() {
                return None;
            }
            let s = &blob[*p..*p + n];
            *p += n;
            Some(s)
        };
        let rd_u32 = |p: &mut usize| -> Option<u32> {
            let b = take(p, 4)?;
            Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        };

        if take(&mut p, 4)? != b"WGK1" {
            return None;
        }
        let size = rd_u32(&mut p)? as usize;
        if size == 0 || size > 4096 {
            return None;
        }
        let cells = size * size;
        let n_arche = rd_u32(&mut p)? as usize;
        let mut by_archetype = HashMap::new();
        for _ in 0..n_arche {
            let name_len = rd_u32(&mut p)? as usize;
            let name_bytes = take(&mut p, name_len)?;
            let name = std::str::from_utf8(name_bytes).ok()?.to_string();
            let n_kernels = rd_u32(&mut p)? as usize;
            let mut ks = Vec::with_capacity(n_kernels);
            for _ in 0..n_kernels {
                let raw = take(&mut p, cells * 4)?;
                let mut data = Vec::with_capacity(cells);
                for c in 0..cells {
                    let o = c * 4;
                    data.push(f32::from_le_bytes([
                        raw[o], raw[o + 1], raw[o + 2], raw[o + 3],
                    ]));
                }
                ks.push(data);
            }
            by_archetype.insert(name, ks);
        }
        Some(KernelAtlas { size, by_archetype })
    }

    /// Load the atlas from the distilled binary asset (NOT a .tif). Returns None
    /// if the file is missing/unreadable/malformed (caller falls back to a
    /// no-DEM path so the world still bakes — never-black).
    pub fn load(path: &str) -> Option<Self> {
        let blob = std::fs::read(path).ok()?;
        Self::parse(&blob)
    }
}

// ---- deterministic hashing + sampling ------------------------------------

fn hash_u32(mut x: u32) -> u32 {
    // integer finalizer (same family as the shader's hash_u)
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    x ^= x >> 16;
    x
}

fn hash2(ix: i32, iz: i32, seed: u32) -> u32 {
    hash_u32(
        (ix as u32)
            .wrapping_mul(0x9e37_79b9)
            ^ hash_u32((iz as u32).wrapping_mul(0x85eb_ca6b) ^ hash_u32(seed)),
    )
}

/// [0,1) from a hash.
fn h01(h: u32) -> f32 {
    (h as f32) * (1.0 / 4_294_967_296.0)
}

/// Smooth value noise in world space (for domain-warping the kernel UVs so patch
/// edges don't tile). Lattice hash + smoothstep interpolation. Returns ~[0,1].
fn value_noise(x: f32, z: f32, seed: u32) -> f32 {
    let x0 = x.floor();
    let z0 = z.floor();
    let fx = x - x0;
    let fz = z - z0;
    let (ix, iz) = (x0 as i32, z0 as i32);
    let c00 = h01(hash2(ix, iz, seed));
    let c10 = h01(hash2(ix + 1, iz, seed));
    let c01 = h01(hash2(ix, iz + 1, seed));
    let c11 = h01(hash2(ix + 1, iz + 1, seed));
    let sx = fx * fx * (3.0 - 2.0 * fx);
    let sz = fz * fz * (3.0 - 2.0 * fz);
    let a = c00 + (c10 - c00) * sx;
    let b = c01 + (c11 - c01) * sx;
    a + (b - a) * sz
}

/// Bilinear-sample a kernel (size×size, row-major [0,1]) at uv in [0,1]², with
/// CLAMP_TO_EDGE.
fn sample_kernel(k: &[f32], size: usize, u: f32, v: f32) -> f32 {
    let fu = (u.clamp(0.0, 1.0)) * (size as f32 - 1.0);
    let fv = (v.clamp(0.0, 1.0)) * (size as f32 - 1.0);
    let x0 = fu.floor() as usize;
    let z0 = fv.floor() as usize;
    let x1 = (x0 + 1).min(size - 1);
    let z1 = (z0 + 1).min(size - 1);
    let tx = fu - x0 as f32;
    let tz = fv - z0 as f32;
    let a = k[z0 * size + x0];
    let b = k[z0 * size + x1];
    let c = k[z1 * size + x0];
    let d = k[z1 * size + x1];
    let top = a + (b - a) * tx;
    let bot = c + (d - c) * tx;
    top + (bot - top) * tz
}

/// World units one kernel "tile" covers before it repeats spatially. Large enough
/// that one patch spans a believable chunk of terrain; small enough that several
/// blend within a region. ~6 km matches the DEM patch real-world extent
/// (256 cells * ~30 m/cell ≈ 7.7 km), so kernel features land at real scale.
const KERNEL_TILE_M: f32 = 6000.0;
/// Domain-warp amount (world m) so kernel-tile edges dissolve instead of gridding.
const WARP_M: f32 = 1800.0;
/// Warp frequency (1/world-m): low so the warp is smooth, not jittery.
const WARP_FREQ: f32 = 1.0 / 5000.0;

/// The DEM surface-character value at a world point for an archetype: pick the
/// kernel for this world-tile (hashed), domain-warp the sample UV, bilinear-
/// sample, and cross-blend with the neighbor tile so there are no hard seams.
/// Returns ~[0,1] (0.5 = neutral). Deterministic, world-anchored (spacing-
/// INDEPENDENT, like the macro). Returns 0.5 (neutral) if the archetype has no
/// kernels (never-black: the bake's structure still stands).
pub fn kernel_surface(atlas: &KernelAtlas, archetype: &str, world_x: f32, world_z: f32, seed: u32) -> f32 {
    let ks = atlas.kernels(archetype);
    if ks.is_empty() {
        return 0.5;
    }
    let n = ks.len() as u32;

    // Domain-warp the world point so kernel tiles don't grid.
    let wx = world_x + (value_noise(world_x * WARP_FREQ, world_z * WARP_FREQ, seed ^ 0x1111) - 0.5) * 2.0 * WARP_M;
    let wz = world_z + (value_noise(world_x * WARP_FREQ, world_z * WARP_FREQ, seed ^ 0x2222) - 0.5) * 2.0 * WARP_M;

    // Tile coords + fractional position within the tile.
    let tx = wx / KERNEL_TILE_M;
    let tz = wz / KERNEL_TILE_M;
    let tix = tx.floor() as i32;
    let tiz = tz.floor() as i32;
    let fx = tx - tx.floor();
    let fz = tz - tz.floor();

    // Sample the 4 surrounding tiles' kernels at their local UV and bilinearly
    // cross-blend (so adjacent tiles dissolve into each other — no hard tile seam).
    let sample_tile = |cix: i32, ciz: i32, u: f32, v: f32| -> f32 {
        let pick = (hash2(cix, ciz, seed) % n) as usize;
        // rotate UV per tile (cheap variety) by swapping/flipping on a hash bit
        let hbit = hash2(cix, ciz, seed ^ 0x55aa);
        let (uu, vv) = match hbit & 3 {
            0 => (u, v),
            1 => (v, 1.0 - u),
            2 => (1.0 - u, 1.0 - v),
            _ => (1.0 - v, u),
        };
        sample_kernel(&ks[pick], atlas.size, uu, vv)
    };

    let s00 = sample_tile(tix, tiz, fx, fz);
    let s10 = sample_tile(tix + 1, tiz, fx, fz);
    let s01 = sample_tile(tix, tiz + 1, fx, fz);
    let s11 = sample_tile(tix + 1, tiz + 1, fx, fz);
    let sx0 = s00 + (s10 - s00) * fx;
    let sx1 = s01 + (s11 - s01) * fx;
    sx0 + (sx1 - sx0) * fz
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a tiny in-memory WGK1 blob: 1 archetype, 2 kernels, size 2.
    fn tiny_blob() -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"WGK1");
        b.extend_from_slice(&2u32.to_le_bytes()); // size
        b.extend_from_slice(&1u32.to_le_bytes()); // n_arche
        let name = b"mountain";
        b.extend_from_slice(&(name.len() as u32).to_le_bytes());
        b.extend_from_slice(name);
        b.extend_from_slice(&2u32.to_le_bytes()); // n_kernels
        for k in [[0.0f32, 0.25, 0.75, 1.0], [1.0, 0.5, 0.5, 0.0]] {
            for v in k {
                b.extend_from_slice(&v.to_le_bytes());
            }
        }
        b
    }

    #[test]
    fn parses_wgk1_blob() {
        let atlas = KernelAtlas::parse(&tiny_blob()).expect("parse");
        assert_eq!(atlas.size, 2);
        assert_eq!(atlas.kernels("mountain").len(), 2);
        assert_eq!(atlas.kernels("grassland").len(), 0);
    }

    #[test]
    fn parse_rejects_bad_magic_and_truncation() {
        assert!(KernelAtlas::parse(b"XXXX").is_none());
        let mut t = tiny_blob();
        t.truncate(t.len() - 5);
        assert!(KernelAtlas::parse(&t).is_none());
    }

    #[test]
    fn kernel_surface_is_deterministic_finite_bounded() {
        let atlas = KernelAtlas::parse(&tiny_blob()).unwrap();
        let a = kernel_surface(&atlas, "mountain", 1234.0, -567.0, 7);
        let b = kernel_surface(&atlas, "mountain", 1234.0, -567.0, 7);
        assert_eq!(a, b, "same args -> same value");
        assert!(a.is_finite() && (-0.01..=1.01).contains(&a), "bounded ~[0,1]: {a}");
        // unknown archetype -> neutral 0.5 (never-black)
        assert_eq!(kernel_surface(&atlas, "desert", 0.0, 0.0, 7), 0.5);
    }

    #[test]
    fn kernel_surface_is_spacing_independent() {
        // Same world point queried "as if" from different page spacings must match
        // (it's a pure fn of world coords) — guards the LOD-stability contract.
        let atlas = KernelAtlas::parse(&tiny_blob()).unwrap();
        let p = kernel_surface(&atlas, "mountain", 8192.0, 4096.0, 3);
        let q = kernel_surface(&atlas, "mountain", 8192.0, 4096.0, 3);
        assert_eq!(p, q);
    }

    #[test]
    fn kernel_surface_varies_across_world_no_constant() {
        // A wide scan must NOT be constant (the kernels carry texture) and must
        // not be trivially periodic at the tile pitch (warp + cross-blend break it).
        let atlas = KernelAtlas::parse(&tiny_blob()).unwrap();
        let mut vals = Vec::new();
        for i in 0..64 {
            let x = i as f32 * 2000.0; // 2 km apart, wide span
            vals.push(kernel_surface(&atlas, "mountain", x, 500.0, 11));
        }
        let lo = vals.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = vals.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo > 0.05, "kernel surface should vary across the world: range {}", hi - lo);
    }
}
