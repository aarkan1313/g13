shader_type spatial;
// WG13 ring_displace (M1.3) — PRESENTS a height page; never generates terrain
// (00_ARCHITECTURE §4). Samples an R32F height texture and displaces a flat
// subdivided plane into terrain. Untextured: flat shading from computed normals.

render_mode cull_back, diffuse_burley;

// The height page as an R32F texture (one height per texel).
uniform sampler2D height_tex : filter_linear, repeat_disable;
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

void fragment() {
	// Flat untextured look: low ground green -> high ground tan, so shape reads
	// in screenshots without textures (those are M3). Tint only; not gameplay.
	float t = clamp((v_height - height_lo) / max(height_hi - height_lo, 1.0), 0.0, 1.0);
	ALBEDO = mix(vec3(0.26, 0.40, 0.20), vec3(0.55, 0.50, 0.40), t);
	ROUGHNESS = 0.95;
}
