# Clipmap continuous-centering + page fade-in — design

**Date:** 2026-06-07
**Branch:** dem-grounded
**Status:** design, approved by user; implement gated (one part at a time)
**Context:** The DEM-grounded prototype view (`wg-13/scripts/dem_grounded_world_view.gd`)
exposes a long-standing clipmap behavior the gentle M2.3 terrain hid: the world
feels like it does not stay centered on the camera, and pages "blink into
existence" at the loaded edge. Evidence (auto-tour, per-level page counts) proved
page PRODUCTION keeps up at every speed (all LOD levels stay full at cruise+boost)
— so this is NOT a starvation/throughput problem. It is two separate issues in how
the ring is SELECTED and how pages APPEAR.

## Problem (precise)

1. **Off-center ring (systemic).** Each level selects its ring as
   `floor(cam/span) ± ring_radius`. `span` doubles per level, so the coarsest
   level's span is ~16–32 km. `floor()` anchors the ring index to the bottom-left
   CORNER of the cell the camera is in, and the ring is symmetric around that
   corner-derived index — not around the camera. Between the rare coarse-boundary
   crossings the coarse coverage is static and the camera slides across it, ending
   up near the EDGE of coarse coverage rather than the center → "never centered,"
   and the eventual coarse swap is a large, visible jump.

2. **Pages snap in (appearance).** A page becomes fully opaque the frame it is
   added (`_make_page_instance`); there is no fade. At the loaded edge the eye
   catches the instant appearance as "pop-in," even when production was timely.

## Non-goals / what this does NOT change

- Pages stay **world-anchored**: page (gx,gz) at world `gx*span` always generates
  the same terrain (determinism). We do NOT move pages or scroll a toroidal buffer.
- The **field/GPU production** path is unchanged.
- The **never-black annulus** invariant is unchanged: level L hides only when its
  full level-(L-1) 2×2 child footprint is displayed (`2*cgx+dx`). This parent-child
  nesting is independent of where the ring centers, so it is preserved.

## The fix — two independent parts

### Part A — center the ring on `round(cam/span)`, not `floor()`

Replace `floor(cam_x/span)` with `round(cam_x/span)` (and z) everywhere the per-level
ring center is computed: the request loop, the per-level `lvl_ccx/lvl_ccz` used for
pin/evict, and the eviction call. `round()` selects the cell whose CENTER the camera
is nearest, so:
- the ring is centered on the camera to within ±½ cell (was ±1 cell) at every level;
- recentering happens at cell MIDPOINTS (camera farthest from any cell edge), where a
  coarse swap is least visible — instead of at edges, where it is most visible.

Must be applied consistently in ALL three places that derive the center, or pin/evict
will disagree with the request ring and thrash. The page world-position math
(`gx*span + span*0.5`) is unchanged — only the SELECTED index set shifts.

Cost: arithmetic only. No new pages, no field cost.

### Part B — fade new pages in over ~0.3s

Give each page a spawn timestamp; the display shader fades alpha 0→1 over a short
duration (default ~0.3s) after spawn, so a new page dissolves in instead of snapping.

- `ring_displace.gdshader`: add `uniform float spawn_alpha;` (0..1) and multiply the
  final fragment alpha by it (and set the material to a transparent/blended draw, or
  use a dither/`ALPHA` so it composites over the coarser blanket beneath — which is
  already drawn under it for never-black, so the fade reveals fine over coarse cleanly).
- `dem_grounded_world_view.gd`: record `spawn_time` per instance in `_inst_meta` (or a
  parallel dict); each frame, set `spawn_alpha = clamp((now - spawn_time)/fade_secs, 0,1)`
  on pages still fading. Recycled instances reset spawn_time on reuse.
- Keep it cheap: only update `spawn_alpha` for pages younger than `fade_secs`; once at
  1.0, stop touching them (and ideally switch back to opaque draw to avoid transparent
  overdraw cost — optional optimization, not required for correctness).

Cost: a per-young-page uniform set; transparent draw only during the brief fade.

## Build sequence (gated, one part at a time)

1. **Part A** (round-centering). Implement, launch, human fly-test: does it feel
   centered / do coarse swaps stop being a big jump? Gate = human visual. Also re-run
   the existing gates that touch streaming (m1_5c coverage/overlap, m1_4 seam) to
   confirm never-black + seams intact. Commit at green.
2. **Part B** (fade-in). Implement, launch, human fly-test: do edge pages dissolve in
   instead of blinking? Gate = human visual. Commit at green.

Each part is independently revertable. If Part A alone fixes the feel, Part B is still
worth doing for the edge blink, but they do not depend on each other.

## Acceptance (human visual, the real gate)

- Flying at normal + boost speed, the loaded world feels centered on the camera; no
  large coarse "jump" as you cross level boundaries.
- New pages at the frontier dissolve in rather than snapping.
- No regressions: no black/holes (never-black holds), no new seams, perf still smooth
  (HUD frame time not worse than before the change).
