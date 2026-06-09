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
// Optional next-coarser parent page. Fine pages blend from this parent surface
// near the outer ring, so a page handoff adds detail gradually instead of swapping
// one mountain silhouette for another.
uniform sampler2D parent_height_tex : filter_linear, repeat_disable;
// M2.1 climate page (RG32F): R = temperature, G = moisture. One texture for both
// channels, bound per page alongside height_tex.
uniform sampler2D climate_tex : filter_linear, repeat_disable;
uniform sampler2D parent_climate_tex : filter_linear, repeat_disable;
// M2.2 biome-id page (R32F, float-encoded int). NEAREST filter: biome id is a
// category, not a value — linear filtering between two ids would invent a wrong
// in-between id at borders. (Hard borders here are expected; M2.4 blends them.)
uniform sampler2D biome_tex : filter_nearest, repeat_disable;
uniform sampler2D parent_biome_tex : filter_nearest, repeat_disable;
// M2.4 analytic normal page (RG32F): R = normal_x = -(hr-hl), G = normal_z = -(hu-hd),
// the surface gradient computed in the field compute from the CONTINUOUS height
// function at world neighbors. Reading this (instead of finite-differencing the
// clamped height texture) gives a normal that AGREES across page edges -> no
// per-chunk shading seam. linear filter for smooth per-pixel shading.
uniform sampler2D normal_tex : filter_linear, repeat_disable;
uniform sampler2D parent_normal_tex : filter_linear, repeat_disable;
// View mode: 0 = normal height shading, 1 = temperature, 2 = moisture, 3 = biome.
uniform int view_mode = 0;
// World extent the page covers (page_res * spacing), so UVs map to the plane.
uniform float page_world_size = 256.0;
// Vertical scale already baked into the heights; this just lets us tune visually.
uniform float height_scale = 1.0;
// Spacing between cells in world units (for finite-difference normals).
uniform float cell_spacing = 4.0;
uniform float parent_cell_spacing = 8.0;
// Parent morph controls. lod_morph_near/far are camera-to-vertex distances in
// world metres: <= near is full page detail, >= far matches the parent surface.
uniform int has_parent = 0;
uniform vec2 parent_uv_offset = vec2(0.0);
uniform float lod_morph_near = 0.0;
uniform float lod_morph_far = 0.0;

varying float v_height;
varying vec2 v_parent_uv;
varying float v_lod_fine_alpha;

// Sample height at a UV (clamped to [0,1]).
float sample_h(vec2 uv) {
	return texture(height_tex, clamp(uv, vec2(0.0), vec2(1.0))).r * height_scale;
}

vec3 normal_from_grad(vec2 grad, float spacing_m) {
	return normalize(vec3(grad.x, 2.0 * spacing_m, grad.y));
}

void vertex() {
	// PlaneMesh lies in XZ with VERTEX.xz in [-size/2, size/2]. Map to UV [0,1].
	vec2 uv = (VERTEX.xz / page_world_size) + vec2(0.5);
	UV = uv;
	v_parent_uv = clamp(parent_uv_offset + uv * 0.5, vec2(0.0), vec2(1.0));

	float fine_alpha = 1.0;
	if (has_parent != 0 && lod_morph_far > lod_morph_near) {
		vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float dist_xz = distance(world_pos.xz, CAMERA_POSITION_WORLD.xz);
		fine_alpha = 1.0 - smoothstep(lod_morph_near, lod_morph_far, dist_xz);
	}
	v_lod_fine_alpha = fine_alpha;

	float h;
	if (has_parent != 0 && fine_alpha <= 0.001) {
		h = texture(parent_height_tex, v_parent_uv).r * height_scale;
	} else {
		float h_full = sample_h(uv);
		h = h_full;
		if (has_parent != 0 && fine_alpha < 0.999) {
			float h_parent = texture(parent_height_tex, v_parent_uv).r * height_scale;
			h = mix(h_parent, h_full, fine_alpha);
		}
	}
	v_height = h;
	VERTEX.y = h;

	// M2.4: read the analytic surface normal from normal_tex instead of finite-
	// differencing the (UV-clamped) height texture. The stored gradient is
	// nx = -(hr-hl), nz = -(hu-hd) over 2*spacing, so the normal is
	// normalize(vec3(nx, 2*cell_spacing, nz)) — identical convention to the old
	// finite difference, but the values AGREE across page edges (computed from the
	// continuous field at true world neighbors), so there's no per-chunk seam.
	vec3 n;
	if (has_parent != 0 && fine_alpha <= 0.001) {
		n = normal_from_grad(texture(parent_normal_tex, v_parent_uv).rg, parent_cell_spacing);
	} else {
		vec2 grad_full = texture(normal_tex, clamp(uv, vec2(0.0), vec2(1.0))).rg;
		n = normal_from_grad(grad_full, cell_spacing);
		if (has_parent != 0 && fine_alpha < 0.999) {
			vec2 grad_parent = texture(parent_normal_tex, v_parent_uv).rg;
			vec3 n_parent = normal_from_grad(grad_parent, parent_cell_spacing);
			n = normalize(mix(n_parent, n, fine_alpha));
		}
	}
	NORMAL = n;
}

uniform float height_lo = 60.0;   // approx low end of the page's height range
uniform float height_hi = 360.0;  // approx high end (for tint contrast only)
uniform int terrain_palette = 0;  // 0 = default WG13 green/tan, 1 = DEM review earth/rock
// Per-page debug tint multiplier (1.0 = none). A faint checkerboard across
// pages makes the page layout visible so seams are verifiable: if the SURFACE
// is continuous across a tint change, there's no crack. Set to 1.0 for clean.
uniform float page_tint = 1.0;

// Map normalized temperature [0,1] to a THERMAL ramp: cold blue -> hot red,
// through purple/magenta (NOT green/yellow — those are reserved for moisture so
// the two view modes read as distinct color languages). Cold=0, hot=1.
vec3 temp_color(float t) {
	t = clamp(t, 0.0, 1.0);
	vec3 cold = vec3(0.10, 0.20, 0.85);   // deep cold blue
	vec3 cool = vec3(0.45, 0.30, 0.85);   // blue-violet
	vec3 mild = vec3(0.75, 0.30, 0.70);   // magenta
	vec3 warm = vec3(0.92, 0.35, 0.30);   // warm coral
	vec3 hot  = vec3(0.85, 0.12, 0.10);   // hot red
	if (t < 0.25) return mix(cold, cool, t / 0.25);
	if (t < 0.50) return mix(cool, mild, (t - 0.25) / 0.25);
	if (t < 0.75) return mix(mild, warm, (t - 0.50) / 0.25);
	return mix(warm, hot, (t - 0.75) / 0.25);
}

// Map normalized moisture to dry -> wet. The field's moisture mostly lives in
// ~[0.1, 0.6] (rarely hits the extremes), so we REMAP that band across the full
// ramp and use a high-contrast, well-separated palette (arid orange -> deep
// blue) so a gently-varying field still reads as a clear gradient, not a wash.
uniform float moist_lo = 0.12;   // map this moisture -> driest color
uniform float moist_hi = 0.55;   // map this moisture -> wettest color
vec3 moist_color(float m) {
	float t = clamp((m - moist_lo) / max(moist_hi - moist_lo, 0.001), 0.0, 1.0);
	// EARTH/WATER ramp: dry brown -> tan -> grass green -> cyan -> wet blue.
	// No red/magenta (those are temperature), so the two modes never look alike.
	vec3 arid = vec3(0.50, 0.34, 0.16);   // dry brown earth
	vec3 dry  = vec3(0.80, 0.72, 0.42);   // dusty tan
	vec3 mid  = vec3(0.42, 0.68, 0.30);   // grass green
	vec3 damp = vec3(0.20, 0.72, 0.72);   // damp cyan
	vec3 wet  = vec3(0.10, 0.40, 0.80);   // wet blue
	if (t < 0.25) return mix(arid, dry, t / 0.25);
	if (t < 0.50) return mix(dry, mid, (t - 0.25) / 0.25);
	if (t < 0.75) return mix(mid, damp, (t - 0.50) / 0.25);
	return mix(damp, wet, (t - 0.75) / 0.25);
}

// M2.2 biome debug colors — matches the Rust BIOME_CENTROIDS roster by index
// (the field outputs the id; the display shader owns the color table, M2_DESIGN).
// Adding a biome = a centroid row in Rust + a color here. id is the R32F value.
const vec3 BIOME_COLORS[10] = vec3[10](
	vec3(0.95, 0.96, 0.98),  // 0 snow / ice cap
	vec3(0.62, 0.60, 0.52),  // 1 tundra
	vec3(0.20, 0.42, 0.34),  // 2 taiga / boreal
	vec3(0.55, 0.52, 0.50),  // 3 bare mountain rock
	vec3(0.70, 0.72, 0.40),  // 4 grassland / steppe
	vec3(0.30, 0.55, 0.28),  // 5 temperate forest
	vec3(0.16, 0.45, 0.30),  // 6 temperate rainforest
	vec3(0.85, 0.74, 0.45),  // 7 desert
	vec3(0.78, 0.70, 0.32),  // 8 savanna
	vec3(0.18, 0.60, 0.25)   // 9 tropical rainforest
);

vec3 biome_color(float id_f) {
	int id = int(id_f + 0.5);              // round the float-encoded int
	if (id < 0) id = 0;
	if (id > 9) id = 9;
	return BIOME_COLORS[id];
}

void fragment() {
	// Use the field's analytic normal per pixel. Vertex displacement still needs
	// mesh geometry, but lighting should not expose coarse clipmap triangles.
	vec2 uv = clamp(UV, vec2(0.0), vec2(1.0));
	vec3 n;
	if (has_parent != 0 && v_lod_fine_alpha <= 0.001) {
		n = normal_from_grad(texture(parent_normal_tex, v_parent_uv).rg, parent_cell_spacing);
	} else {
		vec2 grad_full = texture(normal_tex, uv).rg;
		n = normal_from_grad(grad_full, cell_spacing);
		if (has_parent != 0 && v_lod_fine_alpha < 0.999) {
			vec2 grad_parent = texture(parent_normal_tex, v_parent_uv).rg;
			vec3 n_parent = normal_from_grad(grad_parent, parent_cell_spacing);
			n = normalize(mix(n_parent, n, v_lod_fine_alpha));
		}
	}
	NORMAL = n;

	if (view_mode == 1) {
		// Temperature view: tint by the climate texture's R channel.
		float tv;
		if (has_parent != 0 && v_lod_fine_alpha <= 0.001) {
			tv = texture(parent_climate_tex, v_parent_uv).r;
		} else {
			float tv_full = texture(climate_tex, uv).r;
			tv = tv_full;
			if (has_parent != 0 && v_lod_fine_alpha < 0.999) {
				float tv_parent = texture(parent_climate_tex, v_parent_uv).r;
				tv = mix(tv_parent, tv_full, v_lod_fine_alpha);
			}
		}
		ALBEDO = temp_color(tv) * page_tint;
		ROUGHNESS = 0.95;
	} else if (view_mode == 3) {
		// Biome view: blend colors, not ids, across LODs. The biome texture is
		// categorical, so interpolating ids would invent fake categories.
		vec3 biome;
		if (has_parent != 0 && v_lod_fine_alpha <= 0.001) {
			biome = biome_color(texture(parent_biome_tex, v_parent_uv).r);
		} else {
			vec3 biome_full = biome_color(texture(biome_tex, uv).r);
			biome = biome_full;
			if (has_parent != 0 && v_lod_fine_alpha < 0.999) {
				vec3 biome_parent = biome_color(texture(parent_biome_tex, v_parent_uv).r);
				biome = mix(biome_parent, biome_full, v_lod_fine_alpha);
			}
		}
		ALBEDO = biome * page_tint;
		ROUGHNESS = 0.95;
	} else if (view_mode == 2) {
		// Moisture view: tint by the climate texture's G channel.
		float mv;
		if (has_parent != 0 && v_lod_fine_alpha <= 0.001) {
			mv = texture(parent_climate_tex, v_parent_uv).g;
		} else {
			float mv_full = texture(climate_tex, uv).g;
			mv = mv_full;
			if (has_parent != 0 && v_lod_fine_alpha < 0.999) {
				float mv_parent = texture(parent_climate_tex, v_parent_uv).g;
				mv = mix(mv_parent, mv_full, v_lod_fine_alpha);
			}
		}
		ALBEDO = moist_color(mv) * page_tint;
		ROUGHNESS = 0.95;
	} else {
		// Normal: flat untextured look, low ground green -> high ground tan, so
		// shape reads without textures (those are M3). Tint only; not gameplay.
		float t = clamp((v_height - height_lo) / max(height_hi - height_lo, 1.0), 0.0, 1.0);
		if (terrain_palette == 1) {
			vec3 low = vec3(0.34, 0.30, 0.23);
			vec3 mid = vec3(0.55, 0.47, 0.34);
			vec3 high = vec3(0.70, 0.64, 0.52);
			ALBEDO = mix(mix(low, mid, smoothstep(0.0, 0.58, t)), high, smoothstep(0.55, 1.0, t)) * page_tint;
		} else {
			ALBEDO = mix(vec3(0.26, 0.40, 0.20), vec3(0.55, 0.50, 0.40), t) * page_tint;
		}
		ROUGHNESS = 0.95;
	}
}
