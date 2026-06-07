# Render Forever — Range + Fog + Spread Streaming (design)

Date: 2026-06-07
Status: design approved (user: "idk i trust you" — pillar calls delegated); awaiting spec review
Builds on: M2.6 GPU-resident production (Texture2DRD render, batched level-0 collision readback,
RAII RID lifetime, coarse-mesh triangle taper). That perf foundation is the prerequisite that
makes "always loading, spread out, no hitch" feasible.

## Goal (user's words)

"Extend range out way farther, have stuff be visible forever in all directions using fogs to make
it not pop in, always loading stuff / spreading it out so we aren't loading it all at once" — while
holding the frame budget.

Target reach: **~4x** current (≈195 km), terrain reading to a distant horizon in all directions.

## Current system (grounded in code — wg-13/scripts/world_view.gd)

- Base page span ≈ **508 m** (page_res 128 × spacing 4 → 127 cells × 4 m).
- `num_levels = 6`, `ring_radius = 3`, `evict_margin = 1` (keep_radius = 4).
- **reach** = `ring_radius × base_span × 2^(num_levels-1)` = `3 × 508 × 32` ≈ **49 km**.
- `cam.far` = `reach × 1.3` ≈ **63 km**.
- Depth fog: `fog_depth_begin = reach × 0.45` ≈ **22 km**; `fog_depth_end = reach × 0.98` ≈ **48 km**.
- Production modes (world_view `_process`):
  - COARSEST level (num_levels-1): **unbounded eager** — the never-black floor.
  - MID-coarse (0 < level < coarsest): bounded eager (`max_eager_per_frame = 8`).
  - FINE (level 0): bounded (`max_new_per_frame = 4`) — the expensive detail.

### The pop-in mechanism, in the numbers (root cause of pillar 2)

`fog_depth_end` = 0.98×reach (~48 km) but `cam.far` = 1.3×reach (~63 km). Terrain in the
**0.98→1.3 band renders past fog-end** — it is fully at the haze color but geometry still appears
there (and the streaming frontier, where new pages spawn, sits right at the ring edge ≈ reach,
i.e. at fog 0.98 — the fog edge, not safely buried inside it). So a newly-produced far page can
become visible in still-rendered, not-fully-fogged space → pop-in. This is the long-deferred
"far-edge streaming pop-in" item, to be solved AT the new range.

## Design — four pillars

### Pillar 1 — Reach (far greater view distance)

`num_levels: 6 → 8`. Reach `3 × 508 × 2^7` ≈ **195 km**. The clipmap was built to scale this way
("just more levels + tuned radii" — M1.6). Coarsest page ≈ 65 km across (one VERTEX-displaced plane)
sampled by a 128² texture → ~508 m far sample spacing.

PILLAR CALL (Quality > Survivability > Modularity > Performance): **add the levels as-is; accept the
coarse far silhouette.** It is deep inside fog (pillar 2) — chasing a crisp 195-km-away silhouette
no one can see through haze is slop in the other direction. The triangle taper (already level-halved)
keeps the 2 new coarse levels cheap. AABB stays ±4000 (terrain |height| unchanged).

ONE UNKNOWN TO VERIFY (not assume): float precision at ~195 km from origin. Watch for vertex shimmer
at the visual gate. If present → its own measured, gated step (camera-relative origin, or finer far
texture) — NOT a pre-emptive rewrite now (systematic-debugging: don't fix what you haven't seen fail).

### Pillar 2 — No pop-in (fog buries the frontier)

Retune the fog/far relationship so the streaming frontier is ALWAYS inside full fog. All are tuning
constants derived from `reach` (WorldConfig-class values; no structural code):

- `fog_depth_end` ≈ **0.85 × reach** — at or inside the streaming frontier, so a page that would pop
  in is already at full haze before it can be seen.
- `cam.far` ≈ `fog_depth_end` (≈ 0.85 × reach) — no geometry is drawn past where fog is opaque; also
  reclaims far-plane depth precision (helps pillar 1's precision concern).
- `fog_depth_begin` ≈ **0.55 × reach** (≈ 107 km) — pushed out proportionally so near/mid terrain
  stays crisp at the new scale (today's 22 km begin would over-haze the much larger near field).

Relationship to hold and assert: `appearance_distance ≤ fog_depth_end ≤ cam.far`, where
`appearance_distance` is where a NEWLY-PRODUCED page can first be seen. Key distinction: the coarsest
ring's OUTER edge is at ≈ reach, but pages are produced/displayed as the camera approaches, and the
already-displayed blanket extends past where new in-fill happens (hysteresis). The number that
matters for pop-in is where in-fill becomes VISIBLE, not the static ring edge.

PILLAR CALL on the exact ratio: **start at `fog_depth_end = cam.far = 0.85 × reach`, then CONFIRM
against the measured frontier at the gate** — the P2 step logs the real appearance distance and
asserts it is ≤ fog_depth_end. If 0.85 turns out to leave the frontier visible, lower fog_depth_end
(and cam.far with it) until the assert + the visual pass both hold. The 0.85 is a grounded starting
point, not a proven bound — the gate's measurement is the source of truth (don't trust the ratio over
the measurement). If pulling fog_depth_end in far enough to bury the frontier would over-haze mid
terrain, the fallback lever is raising depth-fog `fog_density` so the outer band reads opaque without
moving begin — try begin/end first, measure, only then touch density.

### Pillar 3 — Continuous / spread-out streaming

Bound ALL levels per-frame (including the currently-unbounded coarsest), via a generous coarsest cap
so the burst is spread, not dumped. Concretely: the coarsest level switches from
`request_page_eager` (unbounded) to a bounded request with its own (high) cap — the coarsest level is
the CHEAPEST (fewest pages cover the most area), so a generous cap still spreads a recenter/teleport
burst across frames.

NEVER-BLACK SAFETY (the M1-foundational invariant — must not break):
- The on-screen coarse blanket persists across eviction via `evict_margin` hysteresis (keep_radius >
  ring_radius), so bounding in-fill does not remove what's already shown.
- With pillar 2 done, the in-fill frontier is buried in fog → a 1-frame gap dissolves into haze, not
  black.
- GUARDRAIL: `m1_9b_eager_spread_check` (never-black) must stay GREEN. If a hole ever shows, the gate
  failed → raise the coarsest cap / widen evict_margin until green. This trades the LITERAL
  never-black guarantee (coarsest fills instantly) for a fog-masked, gate-verified bet. Honest
  tradeoff on record.

### Pillar 4 — Hold the budget at the bigger range

Re-run `m2_6_burst_perf_check` (turbo + jumps, median-of-maxes) at 8 levels. Target: still
**0/720 frames over the 16.6 ms budget**. Rationale it should hold: production cost is dominated by
FINE (level-0) pages (unchanged count + the batched collision readback); the 2 new levels are coarse
(cheap, tapered triangles, GPU-resident render, no blocking sync on the main-device render dispatch).
If it strains → tune caps DOWN (more spread) before anything structural. Re-measure low-fly too.

## Gate plan (staged; each green before the next — one step at a time)

1. **P1 reach** — set num_levels 8. Test: `m2_6_burst_perf_check` + full 10-gate suite green
   (catch regressions early). Then PARK-FOR-VISUAL: launch run.ps1, fly — does terrain read to a far
   horizon in all directions? (rendered pixels → human eyes; also watch for 195km vertex shimmer.)
2. **P2 fog/far** — retune fog_depth_begin/end + cam.far to the new ratios. OUTPUT-PROVABLE part: log
   computed reach / frontier / fog_begin / fog_end / cam.far and assert `frontier ≤ fog_end ≤ far`.
   Then PARK-FOR-VISUAL: fly the frontier — does new terrain DISSOLVE in (no pop-in)? (human eyes).
3. **P3 spread** — bound the coarsest level. Test: `m1_9b_eager_spread_check` (never-black) +
   `m2_6_burst_perf_check` green. (Continuous-streaming "feel" is human, but never-black + burst are
   output-provable guardrails the agent self-certifies.)
4. **P4 budget** — final `m2_6_burst_perf_check` + all 10 gates green; PARK-FOR-VISUAL final fly
   (smooth at the new range, no pop-in, reads forever).

## Non-goals (YAGNI / deferred — stay focused)

- Camera-relative origin / finer far textures: ONLY if pillar-1 precision/silhouette is measured bad.
- Geomorph LOD seam polish (separate deferred item).
- Erosion / per-biome shape / materials (M3/M6).
- Touching the DEM-grounded track (Codex's; its inert uncommitted rust edits are kept per the
  2026-06-07 DRIFT_LOG reconciliation — they do not intersect this track's code paths).

## Modularity check (00 §6 — engine, not a game)

All pillar-1/2 changes are DATA (num_levels, fog/far ratios = WorldConfig-class @export values).
Pillar 3 is one production-mode change (bound the coarsest request) — a code path, but generic
(no game-specific content). Nothing here bakes a game into core. A different game drops in by
changing the same config values. Passes the seam test.
