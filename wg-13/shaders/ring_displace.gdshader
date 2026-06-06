shader_type spatial;
// WG13 ring_displace — PRESENTS a height page; never generates terrain
// (00_ARCHITECTURE §4). Samples an R32F height texture and displaces a flat
// subdivided plane into terrain. Untextured: flat shading from computed normals.
//
// M2.1: also samples the page's CLIMATE textures (temperature, moisture, both
// R32F, same production as height) and, in the climate view modes, tints the
// ground by them. view_mode 0 = normal height shading, 1 = temperature
// (cold blue -> hot red), 2 = moisture (dry tan -> wet blue). The shader only
// READS the field's climate output and draws it (the renderer never decides
// climate, 00 §2.2) — same render path biome color will use (M2.2).

render_mode cull_back, diffuse_burley;

// The height page as an R32F texture (one height per texel).
uniform sampler2D height_tex : filter_linear, repeat_disable;
// M2.1 climate pages (R32F), bound per page alongside height_tex.
uniform sampler2D temp_tex : filter_linear, repeat_disable;
uniform sampler2D moist_tex : filter_linear, repeat_disable;
// View mode: 0 = normal height shading, 1 = temperature, 2 = moisture.
uniform int view_mode = 0;
// World extent the page covers (page_res * spacing), so UVs map to the plane.
uniform float page_world_size = 256.0;
// Vertical scale already baked into the heights; this just lets us tune visually.
uniform float height_scale = 1.0;
// Spacing between cells in world units (for finite-difference normals).
uniform float cell_spacing = 4.0;

varying float v_height;

// Sample height at a UV (clamped to [0,1]).
float sample_h(vec2 uv) {
	return texture(height_tex, clamp(uv, vec2(0.0), vec2(1.0))).r * height_scale;
}

void vertex() {
	// PlaneMesh lies in XZ with VERTEX.xz in [-size/2, size/2]. Map to UV [0,1].
	vec2 uv = (VERTEX.xz / page_world_size) + vec2(0.5);
	UV = uv;
	float h = sample_h(uv);
	v_height = h;
	VERTEX.y = h;

	// Finite-difference normal from neighboring texels.
	float du = cell_spacing / page_world_size;
	float hx = sample_h(uv + vec2(du, 0.0)) - sample_h(uv - vec2(du, 0.0));
	float hz = sample_h(uv + vec2(0.0, du)) - sample_h(uv - vec2(0.0, du));
	vec3 n = normalize(vec3(-hx, 2.0 * cell_spacing, -hz));
	NORMAL = n;
}

uniform float height_lo = 60.0;   // approx low end of the page's height range
uniform float height_hi = 360.0;  // approx high end (for tint contrast only)
// Per-page debug tint multiplier (1.0 = none). A faint checkerboard across
// pages makes the page layout visible so seams are verifiable: if the SURFACE
// is continuous across a tint change, there's no crack. Set to 1.0 for clean.
uniform float page_tint = 1.0;

// Map normalized temperature [0,1] to a perceptual cold->hot ramp
// (blue -> cyan -> green -> yellow -> red). Cold=0, hot=1.
vec3 temp_color(float t) {
	t = clamp(t, 0.0, 1.0);
	vec3 cold = vec3(0.15, 0.25, 0.75);   // deep cold blue
	vec3 cool = vec3(0.20, 0.65, 0.75);   // cyan
	vec3 mild = vec3(0.30, 0.70, 0.30);   // temperate green
	vec3 warm = vec3(0.85, 0.75, 0.25);   // warm yellow
	vec3 hot  = vec3(0.80, 0.20, 0.15);   // hot red
	if (t < 0.25) return mix(cold, cool, t / 0.25);
	if (t < 0.50) return mix(cool, mild, (t - 0.25) / 0.25);
	if (t < 0.75) return mix(mild, warm, (t - 0.50) / 0.25);
	return mix(warm, hot, (t - 0.75) / 0.25);
}

// Map normalized moisture [0,1] to dry tan -> wet blue.
vec3 moist_color(float m) {
	m = clamp(m, 0.0, 1.0);
	vec3 dry = vec3(0.78, 0.70, 0.45);    // arid tan
	vec3 mid = vec3(0.45, 0.62, 0.40);    // grassy
	vec3 wet = vec3(0.15, 0.40, 0.65);    // wet blue
	if (m < 0.5) return mix(dry, mid, m / 0.5);
	return mix(mid, wet, (m - 0.5) / 0.5);
}

void fragment() {
	if (view_mode == 1) {
		// Temperature view: tint by the field's temperature channel.
		float tv = texture(temp_tex, clamp(UV, vec2(0.0), vec2(1.0))).r;
		ALBEDO = temp_color(tv) * page_tint;
		ROUGHNESS = 0.95;
	} else if (view_mode == 2) {
		// Moisture view: tint by the field's moisture channel.
		float mv = texture(moist_tex, clamp(UV, vec2(0.0), vec2(1.0))).r;
		ALBEDO = moist_color(mv) * page_tint;
		ROUGHNESS = 0.95;
	} else {
		// Normal: flat untextured look, low ground green -> high ground tan, so
		// shape reads without textures (those are M3). Tint only; not gameplay.
		float t = clamp((v_height - height_lo) / max(height_hi - height_lo, 1.0), 0.0, 1.0);
		ALBEDO = mix(vec3(0.26, 0.40, 0.20), vec3(0.55, 0.50, 0.40), t) * page_tint;
		ROUGHNESS = 0.95;
	}
}
