use std::collections::VecDeque;

pub const DEFAULT_REGION_SPAN_M: f32 = 16_384.0;
pub const DEFAULT_RESOLUTION: usize = 65;

#[derive(Clone, Copy, Debug)]
pub struct RegionConfig {
    pub seed: u64,
    pub region_span_m: f32,
    pub resolution: usize,
}

impl Default for RegionConfig {
    fn default() -> Self {
        Self {
            seed: 13,
            region_span_m: DEFAULT_REGION_SPAN_M,
            resolution: DEFAULT_RESOLUTION,
        }
    }
}

impl RegionConfig {
    pub fn validate(&self) -> Result<(), String> {
        if !self.region_span_m.is_finite() || self.region_span_m <= 0.0 {
            return Err("region_span_m must be finite and positive".to_string());
        }
        if self.resolution < 3 {
            return Err("resolution must be at least 3".to_string());
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StyleId {
    AlpineBranching = 0,
    SierraBlock = 1,
    PamirChain = 2,
    DissectedHighlands = 3,
}

impl StyleId {
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::AlpineBranching,
            1 => Self::SierraBlock,
            2 => Self::PamirChain,
            _ => Self::DissectedHighlands,
        }
    }

    pub fn as_u8(self) -> u8 {
        self as u8
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::AlpineBranching => "alpine_branching",
            Self::SierraBlock => "sierra_block",
            Self::PamirChain => "pamir_chain",
            Self::DissectedHighlands => "dissected_highlands",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaterialHints {
    pub rock: f32,
    pub snow: f32,
    pub valley_floor: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FactCell {
    pub range_mask: f32,
    pub ridge_axis: f32,
    pub ridge_distance_m: f32,
    pub channel_mask: f32,
    pub channel_distance_m: f32,
    pub pass_floor: f32,
    pub style_id: u8,
    pub style_weight: f32,
    pub material: MaterialHints,
    pub preview_height_m: f32,
}

impl FactCell {
    pub fn max_abs_delta(self, other: Self) -> f32 {
        let material_delta = (self.material.rock - other.material.rock)
            .abs()
            .max((self.material.snow - other.material.snow).abs())
            .max((self.material.valley_floor - other.material.valley_floor).abs());
        (self.range_mask - other.range_mask)
            .abs()
            .max((self.ridge_axis - other.ridge_axis).abs())
            .max((self.ridge_distance_m - other.ridge_distance_m).abs())
            .max((self.channel_mask - other.channel_mask).abs())
            .max((self.channel_distance_m - other.channel_distance_m).abs())
            .max((self.pass_floor - other.pass_floor).abs())
            .max((self.style_id as f32 - other.style_id as f32).abs())
            .max((self.style_weight - other.style_weight).abs())
            .max(material_delta)
            .max((self.preview_height_m - other.preview_height_m).abs())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct RegionFact {
    pub seed: u64,
    pub region_x: i32,
    pub region_z: i32,
    pub region_span_m: f32,
    pub resolution: usize,
    pub cells: Vec<FactCell>,
}

impl RegionFact {
    pub fn cell(&self, x: usize, z: usize) -> FactCell {
        self.cells[z * self.resolution + x]
    }

    pub fn east_border(&self) -> impl Iterator<Item = FactCell> + '_ {
        (0..self.resolution).map(|z| self.cell(self.resolution - 1, z))
    }

    pub fn west_border(&self) -> impl Iterator<Item = FactCell> + '_ {
        (0..self.resolution).map(|z| self.cell(0, z))
    }

    pub fn south_border(&self) -> impl Iterator<Item = FactCell> + '_ {
        (0..self.resolution).map(|x| self.cell(x, self.resolution - 1))
    }

    pub fn north_border(&self) -> impl Iterator<Item = FactCell> + '_ {
        (0..self.resolution).map(|x| self.cell(x, 0))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectivityReport {
    pub largest_component_cells: usize,
    pub largest_component_edge_mask: u8,
    pub components: usize,
}

impl ConnectivityReport {
    pub fn touched_edge_count(self) -> u32 {
        self.largest_component_edge_mask.count_ones()
    }

    pub fn touches_opposing_edges(self) -> bool {
        let north_south = self.largest_component_edge_mask & 0b0011 == 0b0011;
        let west_east = self.largest_component_edge_mask & 0b1100 == 0b1100;
        north_south || west_east
    }
}

pub fn generate_region(config: RegionConfig, region_x: i32, region_z: i32) -> RegionFact {
    config
        .validate()
        .expect("invalid RegionConfig passed to generate_region");

    let mut cells = Vec::with_capacity(config.resolution * config.resolution);
    let denom = (config.resolution - 1) as f32;
    let start_x = region_x as f32 * config.region_span_m;
    let start_z = region_z as f32 * config.region_span_m;

    for z in 0..config.resolution {
        for x in 0..config.resolution {
            let world_x = start_x + (x as f32 / denom) * config.region_span_m;
            let world_z = start_z + (z as f32 / denom) * config.region_span_m;
            cells.push(sample_cell(config.seed, world_x, world_z));
        }
    }

    RegionFact {
        seed: config.seed,
        region_x,
        region_z,
        region_span_m: config.region_span_m,
        resolution: config.resolution,
        cells,
    }
}

pub fn sample_cell(seed: u64, world_x: f32, world_z: f32) -> FactCell {
    let (ridge_distance_m, ridge_axis_raw) = nearest_ridge_axis(seed, world_x, world_z);
    let channel_distance_m = nearest_channel(seed, world_x, world_z);

    let macro_shape = fbm(
        seed ^ 0x6d2b_79f5,
        world_x,
        world_z,
        1.0 / 78_000.0,
        4,
        2.03,
        0.52,
    );
    let highland_belt = 1.0 - smoothstep(4_500.0, 18_000.0, ridge_distance_m);
    let range_mask = smoothstep(0.58, 0.90, macro_shape * 0.76 + highland_belt * 0.34);
    let ridge_axis = ridge_axis_raw * range_mask;

    let channel_mask = 1.0 - smoothstep(0.0, 1_850.0, channel_distance_m);
    let pass_floor = (range_mask * channel_mask).clamp(0.0, 1.0);

    let style_signal = fbm(
        seed ^ 0xa53c_1f2d,
        world_x,
        world_z,
        1.0 / 96_000.0,
        3,
        2.0,
        0.55,
    );
    let style_scaled = (style_signal * 4.0).clamp(0.0, 3.999);
    let style_id = style_scaled.floor() as u8;
    let style_center = style_id as f32 + 0.5;
    let style_weight = (1.0 - (style_scaled - style_center).abs() * 2.0).clamp(0.0, 1.0);

    let ridge_profile = (-(ridge_distance_m / 2_650.0).powi(2)).exp() * range_mask;
    let residual = (fbm(
        seed ^ 0x1c69_b3f1,
        world_x,
        world_z,
        1.0 / 6_500.0,
        3,
        2.05,
        0.48,
    ) - 0.5)
        * 110.0;
    let preview_height_m = 120.0 + range_mask * 980.0 + ridge_profile * 680.0
        - channel_mask * (190.0 + range_mask * 520.0)
        - pass_floor * 220.0
        + residual;

    let rock = (range_mask * 0.54 + ridge_profile * 0.48 + ridge_axis * 0.16).clamp(0.0, 1.0);
    let snow =
        (smoothstep(980.0, 1_620.0, preview_height_m) * (0.55 + range_mask * 0.45)).clamp(0.0, 1.0);
    let valley_floor = channel_mask.max(pass_floor * 0.8).clamp(0.0, 1.0);

    FactCell {
        range_mask,
        ridge_axis,
        ridge_distance_m,
        channel_mask,
        channel_distance_m,
        pass_floor,
        style_id,
        style_weight,
        material: MaterialHints {
            rock,
            snow,
            valley_floor,
        },
        preview_height_m,
    }
}

pub fn max_east_west_border_delta(west: &RegionFact, east: &RegionFact) -> f32 {
    west.east_border()
        .zip(east.west_border())
        .fold(0.0, |acc, (a, b)| acc.max(a.max_abs_delta(b)))
}

pub fn max_south_north_border_delta(north: &RegionFact, south: &RegionFact) -> f32 {
    north
        .south_border()
        .zip(south.north_border())
        .fold(0.0, |acc, (a, b)| acc.max(a.max_abs_delta(b)))
}

pub fn channel_connectivity(region: &RegionFact, threshold: f32) -> ConnectivityReport {
    let n = region.resolution;
    let mut seen = vec![false; n * n];
    let mut largest_component_cells = 0;
    let mut largest_component_edge_mask = 0;
    let mut components = 0;

    for start_z in 0..n {
        for start_x in 0..n {
            let start_idx = start_z * n + start_x;
            if seen[start_idx] || region.cell(start_x, start_z).channel_mask < threshold {
                continue;
            }

            components += 1;
            let mut queue = VecDeque::new();
            queue.push_back((start_x, start_z));
            seen[start_idx] = true;

            let mut component_cells = 0;
            let mut edge_mask = 0u8;

            while let Some((x, z)) = queue.pop_front() {
                component_cells += 1;
                if z == 0 {
                    edge_mask |= 0b0001;
                }
                if z == n - 1 {
                    edge_mask |= 0b0010;
                }
                if x == 0 {
                    edge_mask |= 0b0100;
                }
                if x == n - 1 {
                    edge_mask |= 0b1000;
                }

                for (nx, nz) in neighbors4(x, z, n) {
                    let idx = nz * n + nx;
                    if !seen[idx] && region.cell(nx, nz).channel_mask >= threshold {
                        seen[idx] = true;
                        queue.push_back((nx, nz));
                    }
                }
            }

            if component_cells > largest_component_cells {
                largest_component_cells = component_cells;
                largest_component_edge_mask = edge_mask;
            }
        }
    }

    ConnectivityReport {
        largest_component_cells,
        largest_component_edge_mask,
        components,
    }
}

fn neighbors4(x: usize, z: usize, n: usize) -> impl Iterator<Item = (usize, usize)> {
    let mut out = [(usize::MAX, usize::MAX); 4];
    let mut count = 0;
    if x > 0 {
        out[count] = (x - 1, z);
        count += 1;
    }
    if x + 1 < n {
        out[count] = (x + 1, z);
        count += 1;
    }
    if z > 0 {
        out[count] = (x, z - 1);
        count += 1;
    }
    if z + 1 < n {
        out[count] = (x, z + 1);
        count += 1;
    }
    out.into_iter().take(count)
}

fn nearest_ridge_axis(seed: u64, x: f32, z: f32) -> (f32, f32) {
    let cell_size = 22_000.0;
    let cx = (x / cell_size).floor() as i32;
    let cz = (z / cell_size).floor() as i32;
    let mut best = f32::INFINITY;
    let mut best_weight = 0.0;

    for dz in -2..=2 {
        for dx in -2..=2 {
            let gx = cx + dx;
            let gz = cz + dz;
            for lane in 0..2 {
                let segment = ridge_segment(seed, gx, gz, lane, cell_size);
                let dist =
                    point_segment_distance(x, z, segment.ax, segment.az, segment.bx, segment.bz);
                if dist < best {
                    best = dist;
                    best_weight = segment.weight;
                }
            }
        }
    }

    let axis = (1.0 - smoothstep(0.0, 4_200.0, best)) * best_weight;
    (best, axis.clamp(0.0, 1.0))
}

#[derive(Clone, Copy)]
struct Segment {
    ax: f32,
    az: f32,
    bx: f32,
    bz: f32,
    weight: f32,
}

fn ridge_segment(seed: u64, gx: i32, gz: i32, lane: i32, cell_size: f32) -> Segment {
    let center_x = (gx as f32 + 0.18 + rand01_i(seed, gx, gz, 11 + lane as u64) * 0.64) * cell_size;
    let center_z = (gz as f32 + 0.18 + rand01_i(seed, gx, gz, 31 + lane as u64) * 0.64) * cell_size;
    let coherent = value_noise(seed ^ 0x7311_cafe, center_x, center_z, 1.0 / 120_000.0);
    let local = rand01_i(seed, gx, gz, 53 + lane as u64);
    let angle = (coherent * 0.72 + local * 0.28) * std::f32::consts::TAU;
    let length = cell_size * (0.68 + rand01_i(seed, gx, gz, 71 + lane as u64) * 0.82);
    let dx = angle.cos() * length * 0.5;
    let dz = angle.sin() * length * 0.5;
    Segment {
        ax: center_x - dx,
        az: center_z - dz,
        bx: center_x + dx,
        bz: center_z + dz,
        weight: 0.72 + rand01_i(seed, gx, gz, 97 + lane as u64) * 0.28,
    }
}

fn nearest_channel(seed: u64, x: f32, z: f32) -> f32 {
    let period = 13_500.0;
    let amp = 2_250.0;
    let freq = 1.0 / 15_500.0;
    let mut best = f32::INFINITY;

    let kx = (x / period).floor() as i32;
    for k in (kx - 2)..=(kx + 2) {
        let phase = rand01_i(seed ^ 0xabc1_7133, k, 0, 17) * std::f32::consts::TAU;
        let offset = (rand01_i(seed ^ 0xabc1_7133, k, 0, 19) - 0.5) * period * 0.22;
        let curve_x = k as f32 * period + offset + amp * (z * freq + phase).sin();
        best = best.min((x - curve_x).abs());
    }

    best.min(nearest_tributary(seed, x, z) * 1.12)
}

fn nearest_tributary(seed: u64, x: f32, z: f32) -> f32 {
    let cell_size = 12_500.0;
    let cx = (x / cell_size).floor() as i32;
    let cz = (z / cell_size).floor() as i32;
    let mut best = f32::INFINITY;

    for dz in -2..=2 {
        for dx in -2..=2 {
            let gx = cx + dx;
            let gz = cz + dz;
            let center_x =
                (gx as f32 + 0.18 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 23) * 0.64) * cell_size;
            let center_z =
                (gz as f32 + 0.18 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 29) * 0.64) * cell_size;
            let coherent = value_noise(seed ^ 0x44c2_91af, center_x, center_z, 1.0 / 96_000.0);
            let local = rand01_i(seed ^ 0x93ab_41e9, gx, gz, 31);
            let angle = (coherent * 0.58 + local * 0.42) * std::f32::consts::TAU;
            let length = cell_size * (0.38 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 37) * 0.54);
            let ax = center_x - angle.cos() * length * 0.5;
            let az = center_z - angle.sin() * length * 0.5;
            let bx = center_x + angle.cos() * length * 0.5;
            let bz = center_z + angle.sin() * length * 0.5;
            best = best.min(point_segment_distance(x, z, ax, az, bx, bz));
        }
    }

    best
}

fn point_segment_distance(px: f32, pz: f32, ax: f32, az: f32, bx: f32, bz: f32) -> f32 {
    let vx = bx - ax;
    let vz = bz - az;
    let wx = px - ax;
    let wz = pz - az;
    let denom = vx * vx + vz * vz;
    if denom <= f32::EPSILON {
        return ((px - ax).powi(2) + (pz - az).powi(2)).sqrt();
    }
    let t = ((wx * vx + wz * vz) / denom).clamp(0.0, 1.0);
    let cx = ax + vx * t;
    let cz = az + vz * t;
    ((px - cx).powi(2) + (pz - cz).powi(2)).sqrt()
}

fn fbm(seed: u64, x: f32, z: f32, freq: f32, octaves: usize, lacunarity: f32, gain: f32) -> f32 {
    let mut sum = 0.0;
    let mut amp = 1.0;
    let mut norm = 0.0;
    let mut f = freq;
    for octave in 0..octaves {
        sum += value_noise(seed ^ ((octave as u64 + 1) * 0x9e37_79b9), x, z, f) * amp;
        norm += amp;
        amp *= gain;
        f *= lacunarity;
    }
    sum / norm.max(1e-6)
}

fn value_noise(seed: u64, x: f32, z: f32, freq: f32) -> f32 {
    let sx = x * freq;
    let sz = z * freq;
    let x0 = sx.floor() as i32;
    let z0 = sz.floor() as i32;
    let fx = sx - x0 as f32;
    let fz = sz - z0 as f32;
    let ux = smootherstep(fx);
    let uz = smootherstep(fz);

    let n00 = rand01_i(seed, x0, z0, 0);
    let n10 = rand01_i(seed, x0 + 1, z0, 0);
    let n01 = rand01_i(seed, x0, z0 + 1, 0);
    let n11 = rand01_i(seed, x0 + 1, z0 + 1, 0);
    let nx0 = lerp(n00, n10, ux);
    let nx1 = lerp(n01, n11, ux);
    lerp(nx0, nx1, uz)
}

fn rand01_i(seed: u64, x: i32, z: i32, salt: u64) -> f32 {
    let h = mix64(
        seed ^ salt.wrapping_mul(0x9e37_79b9_7f4a_7c15)
            ^ (x as i64 as u64).wrapping_mul(0xbf58_476d_1ce4_e5b9)
            ^ (z as i64 as u64).wrapping_mul(0x94d0_49bb_1331_11eb),
    );
    ((h >> 40) as f32) / ((1u64 << 24) as f32)
}

fn mix64(mut x: u64) -> u64 {
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^ (x >> 31)
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) -> f32 {
    let t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

fn smootherstep(x: f32) -> f32 {
    let t = x.clamp(0.0, 1.0);
    t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
}

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_region_is_deterministic() {
        let cfg = RegionConfig::default();
        let a = generate_region(cfg, -2, 3);
        let b = generate_region(cfg, -2, 3);
        assert_eq!(a, b);
    }

    #[test]
    fn adjacent_region_borders_match_exactly_enough() {
        let cfg = RegionConfig::default();
        let center = generate_region(cfg, 0, 0);
        let east = generate_region(cfg, 1, 0);
        let south = generate_region(cfg, 0, 1);

        let ew = max_east_west_border_delta(&center, &east);
        let sn = max_south_north_border_delta(&center, &south);
        assert!(ew <= 1e-5, "east/west border delta {ew}");
        assert!(sn <= 1e-5, "south/north border delta {sn}");
    }

    #[test]
    fn channel_mask_has_connected_edge_to_edge_routes() {
        let cfg = RegionConfig::default();
        let region = generate_region(cfg, 0, 0);
        let report = channel_connectivity(&region, 0.45);
        assert!(
            report.largest_component_cells >= cfg.resolution,
            "largest channel component too small: {report:?}"
        );
        assert!(
            report.touches_opposing_edges() || report.touched_edge_count() >= 3,
            "largest channel component does not cross the region: {report:?}"
        );
    }

    #[test]
    fn generated_values_are_bounded_and_finite() {
        let cfg = RegionConfig::default();
        let region = generate_region(cfg, -1, 2);
        for cell in region.cells {
            assert!((0.0..=1.0).contains(&cell.range_mask));
            assert!((0.0..=1.0).contains(&cell.ridge_axis));
            assert!((0.0..=1.0).contains(&cell.channel_mask));
            assert!((0.0..=1.0).contains(&cell.pass_floor));
            assert!(cell.ridge_distance_m.is_finite() && cell.ridge_distance_m >= 0.0);
            assert!(cell.channel_distance_m.is_finite() && cell.channel_distance_m >= 0.0);
            assert!(cell.style_id <= 3);
            assert!((0.0..=1.0).contains(&cell.style_weight));
            assert!((0.0..=1.0).contains(&cell.material.rock));
            assert!((0.0..=1.0).contains(&cell.material.snow));
            assert!((0.0..=1.0).contains(&cell.material.valley_floor));
            assert!(cell.preview_height_m.is_finite());
        }
    }
}
