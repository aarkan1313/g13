//! M2.4c: bake ONE super-region's structural fields by reusing the proven
//! window-port (structural_scaffold::bake::generate_seamsafe_fields). Pure
//! compute: (seed, rx, rz, cfg) -> RegionMacro. No threads/GPU here (the
//! scheduler in step 3 runs this off-frame).

use crate::macro_cache::{MacroBakeConfig, RegionMacro};
use structural_scaffold::bake::{
    apron_meshgrid, generate_seamsafe_fields, ALPINE_BRANCHING, APRON_PX, S_REF,
};

pub struct MacroBake;

impl MacroBake {
    pub fn bake_region(seed: u64, rx: i32, rz: i32, cfg: MacroBakeConfig) -> RegionMacro {
        let res = cfg.resolution();
        let spacing = cfg.bake_spacing_m as f64;
        let core_span = cfg.core_span_m() as f64;

        // World-anchored apron in CELLS: cover the same ~APRON_PX*S_REF world distance
        // at this spacing (so the blur/flow halo is scale-correct, like the window-port).
        let apron = (((APRON_PX as f64) * S_REF) / spacing).round() as usize;
        let padded = res + apron * 2;

        // Region origin tiles seamlessly: (rx,rz) * core_span (shared-boundary).
        let origin_x = rx as f64 * core_span;
        let origin_z = rz as f64 * core_span;

        // apron_meshgrid offsets by -apron cells, so world coords line up across regions.
        let (wx, wz) = apron_meshgrid(padded, padded, apron, spacing, origin_x, origin_z);

        // Step 1 bakes every region with ALPINE_BRANCHING. STYLES + MountainStyle are
        // already in structural_scaffold::bake; style routing (pick per region coord /
        // climate, likely a new MacroBakeConfig field) is a later step (M2.4c step 3/4),
        // and the call below is where it plugs in. Kept single-style now (YAGNI).
        let fields = generate_seamsafe_fields(
            &wx, &wz, padded, padded, seed as i64, &ALPINE_BRANCHING,
            core_span, apron, spacing, true, // flow_on = true (drainage)
        );

        // fields are already core-cropped (length res*res). Derive material masks the
        // same way structural_scaffold::fact_cells_from_mountain_fields does, downcast f32.
        let n = res * res;
        let mut rm = RegionMacro::zeroed(rx, rz, res);
        for i in 0..n {
            let range = fields.range_envelope[i].clamp(0.0, 1.0) as f32;
            let ridge = fields.ranges[i].clamp(0.0, 1.0) as f32;
            let massif = fields.massif[i].clamp(0.0, 1.0) as f32;
            let primary = fields.primary_channels[i].clamp(0.0, 1.0) as f32;
            let tributary = fields.tributaries[i].clamp(0.0, 1.0) as f32;
            let lowland = fields.lowland[i].clamp(0.0, 1.0) as f32;
            let valley_mask = fields.valley_mask[i].clamp(0.0, 1.0) as f32;
            let floor_mask = fields.floor_mask[i].clamp(0.0, 1.0) as f32;

            let channel = primary.max(tributary * 0.65).clamp(0.0, 1.0);
            let pass = floor_mask.max(lowland * 0.35).clamp(0.0, 1.0);
            // preview_height_m convention from structural_scaffold: 1050 + h*520.
            let height = 1_050.0 + fields.height[i] as f32 * 520.0;
            let rock = (range * 0.34 + ridge * 0.38 + massif * 0.26).clamp(0.0, 1.0);
            let snow = (smoothstep(1_550.0, 2_350.0, height) * (0.36 + range * 0.64)).clamp(0.0, 1.0);
            let valley_floor = channel.max(pass * 0.82).max(valley_mask * 0.42);

            rm.height[i] = height;
            rm.range_mask[i] = range;
            rm.channel_mask[i] = channel;
            rm.pass_floor[i] = pass;
            rm.massif[i] = massif;
            rm.rock[i] = rock;
            rm.snow[i] = snow;
            rm.valley_floor[i] = valley_floor;
        }
        rm
    }
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::macro_cache::MacroBakeConfig;

    fn cfg() -> MacroBakeConfig {
        // small + coarse so the test is fast (apron is large; keep res modest)
        MacroBakeConfig { bake_spacing_m: 256.0, super_region_m: 8000.0 }
    }

    #[test]
    fn bake_is_deterministic() {
        let a = MacroBake::bake_region(177, 2, -1, cfg());
        let b = MacroBake::bake_region(177, 2, -1, cfg());
        assert_eq!(a, b, "same seed/region/cfg must be bit-identical");
    }

    #[test]
    fn bake_fields_are_finite_and_sized() {
        let rm = MacroBake::bake_region(177, 0, 0, cfg());
        let res = cfg().resolution();
        assert_eq!(rm.resolution, res);
        assert_eq!(rm.height.len(), res * res);
        assert_eq!(rm.channel_mask.len(), res * res);
        for &h in &rm.height { assert!(h.is_finite()); }
        for &c in &rm.channel_mask { assert!((0.0..=1.0).contains(&c)); }
        for &r in &rm.range_mask { assert!((0.0..=1.0).contains(&r)); }
        for &v in &rm.rock { assert!((0.0..=1.0).contains(&v)); }
        for &v in &rm.snow { assert!((0.0..=1.0).contains(&v)); }
        for &v in &rm.pass_floor { assert!((0.0..=1.0).contains(&v)); }
        for &v in &rm.massif { assert!((0.0..=1.0).contains(&v)); }
        for &v in &rm.valley_floor { assert!((0.0..=1.0).contains(&v)); }
    }

    #[test]
    fn bake_has_real_relief_not_flat() {
        let rm = MacroBake::bake_region(177, 0, 0, cfg());
        let lo = rm.height.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = rm.height.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo > 100.0, "macro height should have real relief, got {} m", hi - lo);
    }

    #[test]
    fn adjacent_regions_agree_on_shared_border() {
        // East border of (0,0) core vs west border of (1,0) core: same world column,
        // so heights must match closely (seam-safe apron -> tight agreement).
        let west = MacroBake::bake_region(177, 0, 0, cfg());
        let east = MacroBake::bake_region(177, 1, 0, cfg());
        let res = cfg().resolution();
        let mut max_delta = 0.0f32;
        for z in 0..res {
            let w = west.height[z * res + (res - 1)]; // east edge of west region
            let e = east.height[z * res + 0];          // west edge of east region
            max_delta = max_delta.max((w - e).abs());
        }
        assert!(max_delta < 1.0, "shared border height delta {} m too large (seam)", max_delta);
    }
}
