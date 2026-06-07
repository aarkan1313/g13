//! M2.4c: the cached macro layer's data types — one baked super-region's
//! structural fields (flat f32, row-major z*res+x) and the bake tunables.

/// Tunable bake parameters (data-driven; defaults set by the caller, picked by
/// visual gate per the spec — NOT hardcoded terrain values).
#[derive(Clone, Copy, Debug)]
pub struct MacroBakeConfig {
    pub bake_spacing_m: f32,   // metres per macro cell (start ~256; tunable)
    pub super_region_m: f32,   // world span one super-region covers (~30km; tunable)
}

impl MacroBakeConfig {
    /// Core macro cells per side: ceil(super_region / spacing) so the core covers
    /// the whole region (the bake adds an apron around this, cropped after).
    pub fn resolution(&self) -> usize {
        (self.super_region_m / self.bake_spacing_m).ceil() as usize
    }
    /// World span the core grid covers (shared-boundary convention: (res-1)*spacing).
    pub fn core_span_m(&self) -> f32 {
        (self.resolution() as f32 - 1.0) * self.bake_spacing_m
    }
}

/// One baked super-region's structural fields. Flat f32, row-major (z*res + x).
/// These are what fine pages will sample (Approach C step 2). Mirrors the WG10
/// fact vocabulary: height + the masks that drive material/biome bias.
#[derive(Clone, Debug, PartialEq)]
pub struct RegionMacro {
    pub region_x: i32,
    pub region_z: i32,
    pub resolution: usize,
    pub height: Vec<f32>,        // world Y (metres)
    pub range_mask: Vec<f32>,    // [0,1] where highland mass stands
    pub channel_mask: Vec<f32>,  // [0,1] drainage/valley corridors
    pub pass_floor: Vec<f32>,    // [0,1] graded traversable corridor
    pub massif: Vec<f32>,        // [0,1] inner massif weight
    pub rock: Vec<f32>,          // [0,1] material hint
    pub snow: Vec<f32>,          // [0,1] material hint
    pub valley_floor: Vec<f32>,  // [0,1] material hint
}

impl RegionMacro {
    pub fn zeroed(region_x: i32, region_z: i32, resolution: usize) -> Self {
        let n = resolution * resolution;
        Self {
            region_x, region_z, resolution,
            height: vec![0.0; n],
            range_mask: vec![0.0; n],
            channel_mask: vec![0.0; n],
            pass_floor: vec![0.0; n],
            massif: vec![0.0; n],
            rock: vec![0.0; n],
            snow: vec![0.0; n],
            valley_floor: vec![0.0; n],
        }
    }
    pub fn cell_count(&self) -> usize { self.resolution * self.resolution }
    pub fn height_at(&self, x: usize, z: usize) -> f32 { self.height[z * self.resolution + x] }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn region_macro_indexing_is_row_major() {
        let res = 4;
        let mut rm = RegionMacro::zeroed(7, 11, res);
        rm.height[2 * res + 3] = 42.0;          // (x=3, z=2)
        assert_eq!(rm.cell_count(), res * res);
        assert_eq!(rm.height_at(3, 2), 42.0);
        assert_eq!(rm.region_x, 7);
        assert_eq!(rm.region_z, 11);
        assert_eq!(rm.resolution, res);
    }

    #[test]
    fn config_core_span_and_resolution_are_consistent() {
        let cfg = MacroBakeConfig { bake_spacing_m: 256.0, super_region_m: 30000.0 };
        // resolution = ceil(super_region / spacing) so the core covers the region.
        assert_eq!(cfg.resolution(), 118);
        assert!((cfg.core_span_m() - (118.0 - 1.0) * 256.0).abs() < 1.0);
    }
}
