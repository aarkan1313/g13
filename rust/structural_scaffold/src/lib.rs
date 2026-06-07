use std::collections::VecDeque;

mod array_ops;
mod recipe_noise;
mod recipes;

pub const DEFAULT_REGION_SPAN_M: f32 = 30_000.0;
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
            Self::PamirChain => "pamir_chains",
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

    pub fn touches_multiple_edges(self) -> bool {
        self.touched_edge_count() >= 2
    }
}

pub fn generate_region(config: RegionConfig, region_x: i32, region_z: i32) -> RegionFact {
    config
        .validate()
        .expect("invalid RegionConfig passed to generate_region");

    let start_x = region_x as f32 * config.region_span_m;
    let start_z = region_z as f32 * config.region_span_m;
    let cells = generate_fact_map_style(
        config.seed,
        config.resolution,
        start_x,
        start_z,
        config.region_span_m,
        StyleId::AlpineBranching,
    );

    RegionFact {
        seed: config.seed,
        region_x,
        region_z,
        region_span_m: config.region_span_m,
        resolution: config.resolution,
        cells,
    }
}

pub fn generate_fact_map(
    seed: u64,
    resolution: usize,
    origin_x: f32,
    origin_z: f32,
    span_m: f32,
) -> Vec<FactCell> {
    generate_fact_map_style(
        seed,
        resolution,
        origin_x,
        origin_z,
        span_m,
        StyleId::AlpineBranching,
    )
}

pub fn generate_fact_map_style(
    seed: u64,
    resolution: usize,
    origin_x: f32,
    origin_z: f32,
    span_m: f32,
    style: StyleId,
) -> Vec<FactCell> {
    assert!(resolution >= 3, "resolution must be at least 3");
    assert!(
        span_m.is_finite() && span_m > 0.0,
        "span_m must be positive"
    );

    let apron = recipes::mountain::APRON_PX;
    let padded = resolution + apron * 2;
    let spacing_m = span_m as f64 / (resolution - 1) as f64;
    let (wx, wz) = recipes::helpers::apron_meshgrid(
        padded,
        padded,
        apron,
        spacing_m,
        origin_x as f64,
        origin_z as f64,
    );
    let mountain_style = recipes::mountain::STYLES[style.as_u8() as usize];
    let fields = recipes::mountain::generate_seamsafe_fields(
        &wx,
        &wz,
        padded,
        padded,
        seed as i64,
        &mountain_style,
        span_m as f64,
        apron,
        spacing_m,
        true,
    );

    fact_cells_from_mountain_fields(&fields, style, spacing_m as f32)
}

fn fact_cells_from_mountain_fields(
    fields: &recipes::mountain::MountainFields,
    style: StyleId,
    spacing_m: f32,
) -> Vec<FactCell> {
    let mut cells = Vec::with_capacity(fields.height.len());
    for i in 0..fields.height.len() {
        let range_mask = fields.range_envelope[i].clamp(0.0, 1.0) as f32;
        let ridge_axis = fields.ranges[i].clamp(0.0, 1.0) as f32;
        let massif = fields.massif[i].clamp(0.0, 1.0) as f32;
        let primary = fields.primary_channels[i].clamp(0.0, 1.0) as f32;
        let tributary = fields.tributaries[i].clamp(0.0, 1.0) as f32;
        let lowland = fields.lowland[i].clamp(0.0, 1.0) as f32;
        let valley_mask = fields.valley_mask[i].clamp(0.0, 1.0) as f32;
        let floor_mask = fields.floor_mask[i].clamp(0.0, 1.0) as f32;
        let channel_mask = primary.max(tributary * 0.65).clamp(0.0, 1.0);
        let pass_floor = floor_mask.max(lowland * 0.35).clamp(0.0, 1.0);
        let preview_height_m = 1_050.0 + fields.height[i] as f32 * 520.0;
        let rock = (range_mask * 0.34 + ridge_axis * 0.38 + massif * 0.26).clamp(0.0, 1.0);
        let snow = (smoothstep(1_550.0, 2_350.0, preview_height_m) * (0.36 + range_mask * 0.64))
            .clamp(0.0, 1.0);
        let valley_floor = channel_mask.max(pass_floor * 0.82).max(valley_mask * 0.42);

        cells.push(FactCell {
            range_mask,
            ridge_axis,
            ridge_distance_m: (1.0 - ridge_axis).max(0.0) * spacing_m * 10.0,
            channel_mask,
            channel_distance_m: (1.0 - channel_mask).max(0.0) * spacing_m * 8.0,
            pass_floor,
            style_id: style.as_u8(),
            style_weight: 1.0,
            material: MaterialHints {
                rock,
                snow,
                valley_floor,
            },
            preview_height_m,
        });
    }
    cells
}

/// Per-cell oracle fact map. Same output shape as `generate_fact_map_style`, but
/// every cell is a pure `sample_cell(seed, world_x, world_z)` call — no neighbor
/// access, no apron, no blur. This is the GPU-portable path (mirrors what would run
/// in `field_height.glsl`). Procedural invariant: pure fn of (seed, world coords).
pub fn oracle_fact_map(
    seed: u64,
    resolution: usize,
    origin_x: f32,
    origin_z: f32,
    span_m: f32,
) -> Vec<FactCell> {
    assert!(resolution >= 3, "resolution must be at least 3");
    assert!(
        span_m.is_finite() && span_m > 0.0,
        "span_m must be positive"
    );
    let spacing = span_m / (resolution as f32 - 1.0);
    let mut cells = Vec::with_capacity(resolution * resolution);
    for z in 0..resolution {
        for x in 0..resolution {
            let wx = origin_x + x as f32 * spacing;
            let wz = origin_z + z as f32 * spacing;
            cells.push(sample_cell(seed, wx, wz));
        }
    }
    cells
}

pub fn sample_cell(seed: u64, world_x: f32, world_z: f32) -> FactCell {
    let synthesis = synthesize_cell(seed, world_x, world_z);
    let style_id = synthesis.style.as_u8();
    let style_weight = synthesis.style_weight;

    let rock =
        (synthesis.range_mask * 0.40 + synthesis.ridge_axis * 0.46 + synthesis.massif * 0.22)
            .clamp(0.0, 1.0);
    let snow = (smoothstep(1_000.0, 1_780.0, synthesis.preview_height_m)
        * (0.50 + synthesis.range_mask * 0.50))
        .clamp(0.0, 1.0);
    let valley_floor = synthesis.channel_mask.max(synthesis.pass_floor * 0.8);

    FactCell {
        range_mask: synthesis.range_mask,
        ridge_axis: synthesis.ridge_axis,
        ridge_distance_m: synthesis.ridge_distance_m,
        channel_mask: synthesis.channel_mask,
        channel_distance_m: synthesis.channel_distance_m,
        pass_floor: synthesis.pass_floor,
        style_id,
        style_weight,
        material: MaterialHints {
            rock,
            snow,
            valley_floor,
        },
        preview_height_m: synthesis.preview_height_m,
    }
}

#[derive(Clone, Copy)]
struct SynthCell {
    range_mask: f32,
    massif: f32,
    ridge_axis: f32,
    ridge_distance_m: f32,
    channel_mask: f32,
    channel_distance_m: f32,
    pass_floor: f32,
    style: StyleId,
    style_weight: f32,
    preview_height_m: f32,
}

#[derive(Clone, Copy)]
struct StyleParams {
    range_cell_m: f32,
    range_width_m: f32,
    ridge_width_m: f32,
    range_len_min: f32,
    range_len_max: f32,
    relief_m: f32,
    primary_spacing_m: f32,
    primary_width_m: f32,
    primary_amp_m: f32,
    tributary_width_m: f32,
    tributary_len_m: f32,
    detail_amp_m: f32,
    detail_freq: f32,
}

#[derive(Clone, Copy)]
struct RangeField {
    envelope: f32,
    massif: f32,
    ridge_axis: f32,
    ridge_distance_m: f32,
}

fn synthesize_cell(seed: u64, world_x: f32, world_z: f32) -> SynthCell {
    let (style, style_weight) = style_at(seed, world_x, world_z);
    let params = style_params(style);
    let (wx, wz) = domain_warp(seed, style, world_x, world_z);
    let range = range_field(seed, style, params, wx, wz);
    let primary_distance = primary_channel_distance(seed, style, params, world_x, world_z);
    let tributary_distance = tributary_channel_distance(seed, style, params, wx, wz);
    let channel_distance_m = primary_distance.min(tributary_distance);

    let primary_mask = 1.0 - smoothstep(0.0, params.primary_width_m, primary_distance);
    let tributary_mask =
        (1.0 - smoothstep(0.0, params.tributary_width_m, tributary_distance)) * range.envelope;
    let channel_mask = primary_mask.max(tributary_mask * 0.86).clamp(0.0, 1.0);
    let carve_mask = primary_mask.max(tributary_mask * 0.34).clamp(0.0, 1.0);
    let pass_floor =
        (primary_mask * range.envelope * (1.0 - range.ridge_axis * 0.35)).clamp(0.0, 1.0);

    let base = (fbm(seed ^ 0x5198_f00d, wx, wz, 1.0 / 120_000.0, 4, 2.0, 0.55) - 0.42) * 340.0;
    let regional_lift = smoothstep(
        0.36,
        0.78,
        fbm(seed ^ 0xf137_d00d, wx, wz, 1.0 / 84_000.0, 3, 2.1, 0.50),
    );
    let ridge_texture = ridged_fbm(seed ^ 0x88ac_4e21, wx, wz, params.detail_freq * 0.72, 5);
    let near_detail = (fbm(
        seed ^ 0x1c69_b3f1,
        wx,
        wz,
        params.detail_freq * 1.8,
        4,
        2.04,
        0.48,
    ) - 0.5)
        * params.detail_amp_m;
    let ridge_micro = (ridged_fbm(
        seed ^ 0xa17e_55ed,
        wx + 913.0,
        wz - 421.0,
        params.detail_freq * 3.1,
        5,
    ) - 0.45)
        * params.relief_m
        * 0.20
        * range.envelope;
    let branch_detail = (fbm(
        seed ^ 0x5eaf_1075,
        wx - 701.0,
        wz + 1_303.0,
        params.detail_freq * 4.4,
        4,
        2.08,
        0.46,
    ) - 0.5)
        * params.detail_amp_m
        * 0.75
        * range.envelope;

    let massif_height = range.massif * params.relief_m * (0.55 + regional_lift * 0.45);
    let ridge_height = range.envelope
        * (0.35 + range.ridge_axis * 0.65)
        * (0.45 + ridge_texture * 0.55)
        * params.relief_m
        * 0.72;
    let carve = carve_mask * (115.0 + range.envelope * params.relief_m * 0.22);
    let pass_cut = pass_floor * (90.0 + params.relief_m * 0.08);
    let lowland_smooth = (1.0 - range.envelope) * 70.0;

    let preview_height_m =
        140.0 + base + massif_height + ridge_height + ridge_micro + branch_detail + near_detail
            - carve
            - pass_cut
            + lowland_smooth;

    SynthCell {
        range_mask: range.envelope,
        massif: range.massif,
        ridge_axis: range.ridge_axis,
        ridge_distance_m: range.ridge_distance_m,
        channel_mask,
        channel_distance_m,
        pass_floor,
        style,
        style_weight,
        preview_height_m,
    }
}

fn style_at(seed: u64, x: f32, z: f32) -> (StyleId, f32) {
    let signal = fbm(seed ^ 0xa53c_1f2d, x, z, 1.0 / 140_000.0, 3, 2.0, 0.55);
    let scaled = (signal * 4.0).clamp(0.0, 3.999);
    let style_id = scaled.floor() as u8;
    let center = style_id as f32 + 0.5;
    (
        StyleId::from_u8(style_id),
        (1.0 - (scaled - center).abs() * 2.0).clamp(0.0, 1.0),
    )
}

fn style_params(style: StyleId) -> StyleParams {
    match style {
        StyleId::AlpineBranching => StyleParams {
            range_cell_m: 20_000.0,
            range_width_m: 5_600.0,
            ridge_width_m: 1_850.0,
            range_len_min: 17_000.0,
            range_len_max: 31_000.0,
            relief_m: 1_280.0,
            primary_spacing_m: 12_500.0,
            primary_width_m: 1_550.0,
            primary_amp_m: 3_250.0,
            tributary_width_m: 900.0,
            tributary_len_m: 8_000.0,
            detail_amp_m: 145.0,
            detail_freq: 1.0 / 5_800.0,
        },
        StyleId::SierraBlock => StyleParams {
            range_cell_m: 28_000.0,
            range_width_m: 7_200.0,
            ridge_width_m: 2_300.0,
            range_len_min: 24_000.0,
            range_len_max: 42_000.0,
            relief_m: 1_080.0,
            primary_spacing_m: 14_000.0,
            primary_width_m: 1_750.0,
            primary_amp_m: 2_300.0,
            tributary_width_m: 1_050.0,
            tributary_len_m: 10_500.0,
            detail_amp_m: 115.0,
            detail_freq: 1.0 / 7_200.0,
        },
        StyleId::PamirChain => StyleParams {
            range_cell_m: 24_000.0,
            range_width_m: 5_900.0,
            ridge_width_m: 1_650.0,
            range_len_min: 28_000.0,
            range_len_max: 48_000.0,
            relief_m: 1_360.0,
            primary_spacing_m: 10_500.0,
            primary_width_m: 1_450.0,
            primary_amp_m: 2_100.0,
            tributary_width_m: 820.0,
            tributary_len_m: 9_500.0,
            detail_amp_m: 135.0,
            detail_freq: 1.0 / 5_200.0,
        },
        StyleId::DissectedHighlands => StyleParams {
            range_cell_m: 18_500.0,
            range_width_m: 4_800.0,
            ridge_width_m: 1_450.0,
            range_len_min: 12_500.0,
            range_len_max: 25_000.0,
            relief_m: 950.0,
            primary_spacing_m: 11_500.0,
            primary_width_m: 1_420.0,
            primary_amp_m: 2_900.0,
            tributary_width_m: 760.0,
            tributary_len_m: 7_200.0,
            detail_amp_m: 160.0,
            detail_freq: 1.0 / 4_700.0,
        },
    }
}

fn domain_warp(seed: u64, style: StyleId, x: f32, z: f32) -> (f32, f32) {
    let amount = match style {
        StyleId::SierraBlock => 2_200.0,
        StyleId::PamirChain => 1_450.0,
        StyleId::AlpineBranching => 3_200.0,
        StyleId::DissectedHighlands => 3_650.0,
    };
    let dx = (fbm(seed ^ 0x1515_a11a, x, z, 1.0 / 58_000.0, 3, 2.0, 0.55) - 0.5) * amount;
    let dz = (fbm(seed ^ 0x2d33_cafe, x, z, 1.0 / 61_000.0, 3, 2.0, 0.55) - 0.5) * amount;
    (x + dx, z + dz)
}

fn range_field(seed: u64, style: StyleId, params: StyleParams, x: f32, z: f32) -> RangeField {
    let cell_size = params.range_cell_m;
    let cx = (x / cell_size).floor() as i32;
    let cz = (z / cell_size).floor() as i32;
    let mut best_dist = f32::INFINITY;
    let mut best_score = 0.0f32;
    let mut best_ridge = 0.0f32;

    for dz in -2..=2 {
        for dx in -2..=2 {
            let gx = cx + dx;
            let gz = cz + dz;
            let lane_count = match style {
                StyleId::AlpineBranching | StyleId::DissectedHighlands => 3,
                _ => 2,
            };
            for lane in 0..lane_count {
                let segment = range_segment(seed, style, params, gx, gz, lane);
                let dist =
                    point_segment_distance(x, z, segment.ax, segment.az, segment.bx, segment.bz);
                let envelope = (-(dist / params.range_width_m).powi(2)).exp() * segment.weight;
                let ridge = (-(dist / params.ridge_width_m).powi(2)).exp() * segment.weight;
                best_dist = best_dist.min(dist);
                best_score = best_score.max(envelope);
                best_ridge = best_ridge.max(ridge);
            }
        }
    }

    let regional = fbm(seed ^ 0x6d2b_79f5, x, z, 1.0 / 92_000.0, 4, 2.03, 0.52);
    let envelope = smoothstep(0.22, 0.78, best_score * 0.90 + regional * 0.22);
    let massif_noise = fbm(seed ^ 0x61e7_2cad, x, z, 1.0 / 18_000.0, 3, 2.0, 0.52);
    let massif = (envelope * (0.48 + massif_noise * 0.52)).clamp(0.0, 1.0);
    RangeField {
        envelope,
        massif,
        ridge_axis: (best_ridge * envelope).clamp(0.0, 1.0),
        ridge_distance_m: best_dist,
    }
}

fn range_segment(
    seed: u64,
    style: StyleId,
    params: StyleParams,
    gx: i32,
    gz: i32,
    lane: i32,
) -> Segment {
    let cell_size = params.range_cell_m;
    let center_x = (gx as f32 + 0.12 + rand01_i(seed, gx, gz, 11 + lane as u64) * 0.76) * cell_size;
    let center_z = (gz as f32 + 0.12 + rand01_i(seed, gx, gz, 31 + lane as u64) * 0.76) * cell_size;
    let coherent = value_noise(seed ^ 0x7311_cafe, center_x, center_z, 1.0 / 150_000.0);
    let local = rand01_i(seed, gx, gz, 53 + lane as u64);
    let style_bias = match style {
        StyleId::AlpineBranching => 0.16,
        StyleId::SierraBlock => 0.08,
        StyleId::PamirChain => 0.28,
        StyleId::DissectedHighlands => 0.20,
    } * std::f32::consts::TAU;
    let angle = style_bias + (coherent * 0.70 + local * 0.30) * std::f32::consts::TAU;
    let length = params.range_len_min
        + rand01_i(seed, gx, gz, 71 + lane as u64) * (params.range_len_max - params.range_len_min);
    let dx = angle.cos() * length * 0.5;
    let dz = angle.sin() * length * 0.5;
    Segment {
        ax: center_x - dx,
        az: center_z - dz,
        bx: center_x + dx,
        bz: center_z + dz,
        weight: 0.68 + rand01_i(seed, gx, gz, 97 + lane as u64) * 0.32,
    }
}

fn primary_channel_distance(seed: u64, style: StyleId, params: StyleParams, x: f32, z: f32) -> f32 {
    let angle = match style {
        StyleId::AlpineBranching => 0.36,
        StyleId::SierraBlock => 0.72,
        StyleId::PamirChain => 1.42,
        StyleId::DissectedHighlands => 0.98,
    } + (rand01_i(seed ^ 0xabc1_7133, 0, 0, style.as_u8() as u64) - 0.5) * 0.38;
    let (u, v) = rotate2(x, z, angle);
    let spacing = params.primary_spacing_m;
    let k0 = (v / spacing).floor() as i32;
    let mut best = f32::INFINITY;
    for k in (k0 - 2)..=(k0 + 2) {
        let phase =
            rand01_i(seed ^ 0xabc1_7133, k, style.as_u8() as i32, 17) * std::f32::consts::TAU;
        let offset =
            (rand01_i(seed ^ 0xabc1_7133, k, style.as_u8() as i32, 19) - 0.5) * spacing * 0.35;
        let curve = k as f32 * spacing
            + offset
            + params.primary_amp_m * (u / 17_000.0 + phase).sin()
            + params.primary_amp_m * 0.34 * (u / 8_500.0 + phase * 1.7).sin();
        best = best.min((v - curve).abs());
    }
    best
}

fn tributary_channel_distance(
    seed: u64,
    style: StyleId,
    params: StyleParams,
    x: f32,
    z: f32,
) -> f32 {
    let cell_size = params.tributary_len_m * 1.45;
    let cx = (x / cell_size).floor() as i32;
    let cz = (z / cell_size).floor() as i32;
    let mut best = f32::INFINITY;

    for dz in -2..=2 {
        for dx in -2..=2 {
            let gx = cx + dx;
            let gz = cz + dz;
            let center_x =
                (gx as f32 + 0.12 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 23) * 0.76) * cell_size;
            let center_z =
                (gz as f32 + 0.12 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 29) * 0.76) * cell_size;
            let coherent = value_noise(seed ^ 0x44c2_91af, center_x, center_z, 1.0 / 74_000.0);
            let local = rand01_i(seed ^ 0x93ab_41e9, gx, gz, 31);
            let style_turn = match style {
                StyleId::AlpineBranching => 0.35,
                StyleId::SierraBlock => 0.18,
                StyleId::PamirChain => 0.50,
                StyleId::DissectedHighlands => 0.72,
            };
            let angle =
                (coherent * (1.0 - style_turn) + local * style_turn) * std::f32::consts::TAU;
            let length =
                params.tributary_len_m * (0.55 + rand01_i(seed ^ 0x93ab_41e9, gx, gz, 37) * 0.85);
            let ax = center_x - angle.cos() * length * 0.5;
            let az = center_z - angle.sin() * length * 0.5;
            let bx = center_x + angle.cos() * length * 0.5;
            let bz = center_z + angle.sin() * length * 0.5;
            best = best.min(point_segment_distance(x, z, ax, az, bx, bz));
        }
    }

    best
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

#[derive(Clone, Copy)]
struct Segment {
    ax: f32,
    az: f32,
    bx: f32,
    bz: f32,
    weight: f32,
}

fn rotate2(x: f32, z: f32, angle: f32) -> (f32, f32) {
    let ca = angle.cos();
    let sa = angle.sin();
    (x * ca - z * sa, x * sa + z * ca)
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

fn ridged_fbm(seed: u64, x: f32, z: f32, freq: f32, octaves: usize) -> f32 {
    let mut sum = 0.0;
    let mut amp = 0.55;
    let mut norm = 0.0;
    let mut f = freq;
    let mut prev = 1.0;

    for octave in 0..octaves {
        let n = value_noise(seed ^ ((octave as u64 + 3) * 0x68bc_21eb), x, z, f);
        let r = 1.0 - (2.0 * n - 1.0).abs();
        let rounded = smoothstep(0.08, 0.92, r);
        let weighted = rounded * (0.58 + prev * 0.42);
        sum += weighted * amp;
        norm += amp;
        prev = rounded;
        amp *= 0.52;
        f *= 2.04;
    }

    sum / norm.max(1e-6)
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
    fn channel_mask_has_nontrivial_drainage_signal() {
        let cfg = RegionConfig::default();
        let region = generate_region(cfg, 0, 0);
        let report = channel_connectivity(&region, 0.18);
        let max_channel = region
            .cells
            .iter()
            .map(|cell| cell.channel_mask)
            .fold(0.0_f32, f32::max);
        let mean_channel = region
            .cells
            .iter()
            .map(|cell| cell.channel_mask)
            .sum::<f32>()
            / region.cells.len() as f32;
        assert!(
            max_channel > 0.35,
            "channel mask never develops a strong drainage response: max={max_channel}"
        );
        assert!(
            mean_channel > 0.01 && mean_channel < 0.35,
            "channel mask density is outside the expected sparse WG10 range: mean={mean_channel}"
        );
        assert!(
            report.largest_component_cells >= cfg.resolution / 2,
            "largest channel component too small: {report:?}"
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

    #[test]
    fn oracle_fact_map_is_deterministic_and_bounded() {
        let a = oracle_fact_map(177, 33, 0.0, 0.0, 64_000.0);
        let b = oracle_fact_map(177, 33, 0.0, 0.0, 64_000.0);
        assert_eq!(a.len(), 33 * 33);
        assert_eq!(a, b, "same seed/resolution/origin/span must be bit-identical");
        for cell in &a {
            assert!((0.0..=1.0).contains(&cell.range_mask));
            assert!((0.0..=1.0).contains(&cell.channel_mask));
            assert!(cell.preview_height_m.is_finite());
        }
    }

    #[test]
    fn oracle_fact_map_matches_sample_cell_at_grid_points() {
        let res = 17usize;
        let span = 64_000.0f32;
        let map = oracle_fact_map(177, res, 1000.0, -2000.0, span);
        let spacing = span / (res as f32 - 1.0);
        // spot-check a few grid points equal a direct sample_cell call
        for &(x, z) in &[(0usize, 0usize), (5, 11), (16, 16)] {
            let wx = 1000.0 + x as f32 * spacing;
            let wz = -2000.0 + z as f32 * spacing;
            let direct = sample_cell(177, wx, wz);
            assert_eq!(map[z * res + x], direct);
        }
    }
}
