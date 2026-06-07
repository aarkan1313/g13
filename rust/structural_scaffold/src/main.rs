use std::fs;
use std::path::{Path, PathBuf};

use structural_scaffold::{
    channel_connectivity, generate_fact_map_style, generate_region, max_east_west_border_delta,
    max_south_north_border_delta, RegionConfig, StyleId,
};

fn main() {
    if let Err(err) = run() {
        eprintln!("ERROR: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    let command = args.first().map(|s| s.as_str()).unwrap_or("review");
    match command {
        "review" => run_review(&args[1..]),
        "-h" | "--help" | "help" => {
            print_usage();
            Ok(())
        }
        other => Err(format!("unknown command '{other}'")),
    }
}

fn print_usage() {
    println!(
        "usage: cargo run -p structural_scaffold -- review [--seed N] [--radius N] [--tile-px N] [--out PATH] [--report PATH]"
    );
}

fn run_review(args: &[String]) -> Result<(), String> {
    let seed = parse_u64(args, "--seed", 177)?;
    let radius = parse_i32(args, "--radius", 1)?;
    let tile_px = parse_usize(args, "--tile-px", 128)?;
    let out = parse_path(
        args,
        "--out",
        PathBuf::from("wg-13/_captures/m2_4b_scaffold_review.png"),
    );
    let report = parse_path(
        args,
        "--report",
        PathBuf::from("wg-13/_captures/m2_4b_scaffold_review.md"),
    );

    if radius < 1 {
        return Err("--radius must be at least 1".to_string());
    }
    if tile_px < 32 {
        return Err("--tile-px must be at least 32".to_string());
    }

    let review = render_review(seed, radius, tile_px)?;
    write_png_rgb(&out, review.width, review.height, &review.rgb)?;

    let report_text = build_report(seed, radius, tile_px, &out);
    write_text(&report, &report_text)?;

    println!("Wrote {}", out.display());
    println!("Wrote {}", report.display());
    Ok(())
}

fn parse_u64(args: &[String], flag: &str, default: u64) -> Result<u64, String> {
    match arg_value(args, flag) {
        Some(v) => v
            .parse::<u64>()
            .map_err(|_| format!("{flag} expects an unsigned integer")),
        None => Ok(default),
    }
}

fn parse_i32(args: &[String], flag: &str, default: i32) -> Result<i32, String> {
    match arg_value(args, flag) {
        Some(v) => v
            .parse::<i32>()
            .map_err(|_| format!("{flag} expects an integer")),
        None => Ok(default),
    }
}

fn parse_usize(args: &[String], flag: &str, default: usize) -> Result<usize, String> {
    match arg_value(args, flag) {
        Some(v) => v
            .parse::<usize>()
            .map_err(|_| format!("{flag} expects an unsigned integer")),
        None => Ok(default),
    }
}

fn parse_path(args: &[String], flag: &str, default: PathBuf) -> PathBuf {
    arg_value(args, flag).map(PathBuf::from).unwrap_or(default)
}

fn arg_value<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].as_str())
}

struct ReviewImage {
    width: usize,
    height: usize,
    rgb: Vec<u8>,
}

fn render_review(seed: u64, radius: i32, tile_px: usize) -> Result<ReviewImage, String> {
    let grid_regions = (radius * 2 + 1) as usize;
    let map_px = grid_regions * tile_px;
    let panel_count = 4usize;
    let gutter = 12usize;
    let width = panel_count * map_px + (panel_count - 1) * gutter;
    let height = map_px;

    let mut image = Image::new(width, height, [238, 238, 232]);
    let world_min = 0.0f32;
    let world_span = 200_000.0f32;
    let styles = [
        StyleId::AlpineBranching,
        StyleId::SierraBlock,
        StyleId::PamirChain,
        StyleId::DissectedHighlands,
    ];
    let style_maps = styles
        .iter()
        .map(|&style| {
            generate_fact_map_style(seed, map_px, world_min, world_min, world_span, style)
        })
        .collect::<Vec<_>>();

    for panel in 0..panel_count {
        let offset_x = panel * (map_px + gutter);
        let facts = &style_maps[panel];
        let (min_h, max_h) = facts
            .iter()
            .fold((f32::INFINITY, f32::NEG_INFINITY), |acc, c| {
                (acc.0.min(c.preview_height_m), acc.1.max(c.preview_height_m))
            });
        for y in 0..map_px {
            for x in 0..map_px {
                let color = terrain_panel_color(facts, map_px, x, y, min_h, max_h);
                image.set(offset_x + x, y, color);
            }
        }
    }

    Ok(ReviewImage {
        width,
        height,
        rgb: image.rgb,
    })
}

fn terrain_panel_color(
    facts: &[structural_scaffold::FactCell],
    map_px: usize,
    x: usize,
    y: usize,
    min_h: f32,
    max_h: f32,
) -> [u8; 3] {
    let inv_range = 1.0 / (max_h - min_h).max(1e-6);
    let sample = |sx: usize, sy: usize| -> f32 {
        (facts[sy * map_px + sx].preview_height_m - min_h) * inv_range
    };
    let left = sample(x.saturating_sub(1), y);
    let right = sample((x + 1).min(map_px - 1), y);
    let up = sample(x, y.saturating_sub(1));
    let down = sample(x, (y + 1).min(map_px - 1));
    let gx = (right - left) * 40.0;
    let gy = (down - up) * 40.0;
    let slope = std::f32::consts::FRAC_PI_2 - (gx * gx + gy * gy).sqrt().atan();
    let aspect = (-gx).atan2(gy);
    let az = 135.0_f32.to_radians();
    let alt = 45.0_f32.to_radians();
    let shade =
        (alt.sin() * slope.sin() + alt.cos() * slope.cos() * (az - aspect).cos()).clamp(0.0, 1.0);
    let g = (shade * 255.0).round() as u8;
    [g, g, g]
}

fn build_report(seed: u64, radius: i32, tile_px: usize, out: &Path) -> String {
    let config = RegionConfig {
        seed,
        ..RegionConfig::default()
    };
    let mut regions = Vec::new();
    let mut min_h = f32::INFINITY;
    let mut max_h = f32::NEG_INFINITY;
    let mut max_ew = 0.0f32;
    let mut max_sn = 0.0f32;
    let mut min_largest_route = usize::MAX;
    let mut max_channel = 0.0f32;
    let mut channel_sum = 0.0f32;
    let mut channel_count = 0usize;

    for z in -radius..=radius {
        for x in -radius..=radius {
            let fact = generate_region(config, x, z);
            for c in &fact.cells {
                min_h = min_h.min(c.preview_height_m);
                max_h = max_h.max(c.preview_height_m);
                max_channel = max_channel.max(c.channel_mask);
                channel_sum += c.channel_mask;
                channel_count += 1;
            }
            let connectivity = channel_connectivity(&fact, 0.18);
            min_largest_route = min_largest_route.min(connectivity.largest_component_cells);
            regions.push(((x, z), fact));
        }
    }

    for ((x, z), region) in &regions {
        if let Some((_, east)) = regions
            .iter()
            .find(|((ex, ez), _)| *ex == *x + 1 && *ez == *z)
        {
            max_ew = max_ew.max(max_east_west_border_delta(region, east));
        }
    }

    for ((x, z), region) in &regions {
        if let Some((_, south)) = regions
            .iter()
            .find(|((sx, sz), _)| *sx == *x && *sz == *z + 1)
        {
            max_sn = max_sn.max(max_south_north_border_delta(region, south));
        }
    }

    format!(
        "# M2.4b structural scaffold review\n\n\
Seed: `{seed}`\n\
Regions: `{}` x `{}` (`radius={radius}`)\n\
Region span: `{}` m\n\
Review span: `200000` m\n\
Region resolution: `{}` samples per axis\n\
Review tile: `{tile_px}` px per region\n\
Image: `{}`\n\n\
## What this is\n\n\
This is the Step 2/3 prototype lane: deterministic Rust structural facts plus a static review sheet. It is not runtime page integration and it does not replace the accepted M2.3 terrain.\n\n\
Panels, left to right: alpine branching, sierra block, pamir chains, dissected highlands. Each panel is height shading from the copied WG10 mountain recipe fields, not the old line-segment scaffold.\n\n\
## Metrics\n\n\
- preview height range: `{:.1}` to `{:.1}` m\n\
- max east/west seam fact delta: `{:.8}`\n\
- max south/north seam fact delta: `{:.8}`\n\
- max channel response: `{:.3}`\n\
- mean channel density: `{:.3}`\n\
- minimum largest high-discharge component at threshold 0.18: `{}` cells\n\n\
## Read this honestly\n\n\
This sheet should be judged against the WG10 mountain synthesis look first. If it does not read like those sources, keep tuning this offline recipe port before touching the live shader.\n",
        radius * 2 + 1,
        radius * 2 + 1,
        config.region_span_m,
        config.resolution,
        out.display(),
        min_h,
        max_h,
        max_ew,
        max_sn,
        max_channel,
        channel_sum / channel_count.max(1) as f32,
        min_largest_route,
    )
}

struct Image {
    width: usize,
    height: usize,
    rgb: Vec<u8>,
}

impl Image {
    fn new(width: usize, height: usize, fill: [u8; 3]) -> Self {
        let mut rgb = vec![0; width * height * 3];
        for px in rgb.chunks_exact_mut(3) {
            px.copy_from_slice(&fill);
        }
        Self { width, height, rgb }
    }

    fn set(&mut self, x: usize, y: usize, color: [u8; 3]) {
        if x >= self.width || y >= self.height {
            return;
        }
        let idx = (y * self.width + x) * 3;
        self.rgb[idx..idx + 3].copy_from_slice(&color);
    }
}

fn write_text(path: &Path, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }
    fs::write(path, text).map_err(|e| format!("write {}: {e}", path.display()))
}

fn write_png_rgb(path: &Path, width: usize, height: usize, rgb: &[u8]) -> Result<(), String> {
    if rgb.len() != width * height * 3 {
        return Err("rgb buffer size does not match width/height".to_string());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("create {}: {e}", parent.display()))?;
    }

    let mut raw = Vec::with_capacity((width * 3 + 1) * height);
    for y in 0..height {
        raw.push(0);
        let start = y * width * 3;
        raw.extend_from_slice(&rgb[start..start + width * 3]);
    }

    let mut png = Vec::new();
    png.extend_from_slice(&[137, 80, 78, 71, 13, 10, 26, 10]);

    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&(width as u32).to_be_bytes());
    ihdr.extend_from_slice(&(height as u32).to_be_bytes());
    ihdr.push(8);
    ihdr.push(2);
    ihdr.push(0);
    ihdr.push(0);
    ihdr.push(0);
    push_png_chunk(&mut png, b"IHDR", &ihdr);

    let compressed = zlib_store(&raw);
    push_png_chunk(&mut png, b"IDAT", &compressed);
    push_png_chunk(&mut png, b"IEND", &[]);

    fs::write(path, png).map_err(|e| format!("write {}: {e}", path.display()))
}

fn push_png_chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    let mut crc_input = Vec::with_capacity(kind.len() + data.len());
    crc_input.extend_from_slice(kind);
    crc_input.extend_from_slice(data);
    out.extend_from_slice(&crc32(&crc_input).to_be_bytes());
}

fn zlib_store(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x78, 0x01];
    let mut offset = 0usize;
    while offset < data.len() {
        let remaining = data.len() - offset;
        let len = remaining.min(65_535);
        let final_block = if offset + len == data.len() { 1u8 } else { 0u8 };
        out.push(final_block);
        let len16 = len as u16;
        out.extend_from_slice(&len16.to_le_bytes());
        out.extend_from_slice(&(!len16).to_le_bytes());
        out.extend_from_slice(&data[offset..offset + len]);
        offset += len;
    }
    out.extend_from_slice(&adler32(data).to_be_bytes());
    out
}

fn adler32(data: &[u8]) -> u32 {
    const MOD: u32 = 65_521;
    let mut a = 1u32;
    let mut b = 0u32;
    for &byte in data {
        a = (a + byte as u32) % MOD;
        b = (b + a) % MOD;
    }
    (b << 16) | a
}

fn crc32(data: &[u8]) -> u32 {
    let mut crc = 0xffff_ffffu32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            let mask = 0u32.wrapping_sub(crc & 1);
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    !crc
}
