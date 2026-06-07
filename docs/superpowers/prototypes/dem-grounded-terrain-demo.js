"use strict";

const SIZE = 256;

const VIEW = {
  walk: {
    label: "Walk",
    detail: 1.0,
    coarseCells: 34,
    description: "close residual detail enabled"
  },
  low: {
    label: "Low Fly",
    detail: 0.62,
    coarseCells: 20,
    description: "mid-scale drainage and residual remain visible"
  },
  high: {
    label: "High Fly",
    detail: 0.26,
    coarseCells: 10,
    description: "coarse cache visibly aliases the terrain"
  }
};

let currentView = "walk";

const ids = {
  cacheCanvas: "cacheCanvas",
  scaffoldCanvas: "scaffoldCanvas",
  structureCanvas: "structureCanvas",
  residualCanvas: "residualCanvas",
  patchCanvas: "patchCanvas",
  combinedCanvas: "combinedCanvas",
  cacheMetric: "cacheMetric",
  scaffoldMetric: "scaffoldMetric",
  structureMetric: "structureMetric",
  residualMetric: "residualMetric",
  patchMetric: "patchMetric",
  combinedMetric: "combinedMetric",
  viewLabel: "viewLabel",
  viewDescription: "viewDescription",
  seamMetric: "seamMetric",
  repeatMetric: "repeatMetric",
  lodMetric: "lodMetric",
  seedInput: "seedInput",
  rerollButton: "rerollButton"
};

function $(id) {
  return document.getElementById(id);
}

function clamp01(v) {
  return Math.max(0, Math.min(1, v));
}

function smoothstep(a, b, x) {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
}

function lerp(a, b, t) {
  return a + (b - a) * t;
}

function mixColor(a, b, t) {
  return [
    Math.round(lerp(a[0], b[0], t)),
    Math.round(lerp(a[1], b[1], t)),
    Math.round(lerp(a[2], b[2], t))
  ];
}

function hash32(a, b, c) {
  let h = 2166136261;
  h = Math.imul(h ^ (a | 0), 16777619);
  h = Math.imul(h ^ (b | 0), 16777619);
  h = Math.imul(h ^ (c | 0), 16777619);
  h ^= h >>> 15;
  h = Math.imul(h, 2246822519);
  h ^= h >>> 13;
  h = Math.imul(h, 3266489917);
  h ^= h >>> 16;
  return h >>> 0;
}

function hash01(a, b, c) {
  return hash32(a, b, c) / 4294967295;
}

function valueNoise(x, y, scale, seed) {
  const sx = x * scale;
  const sy = y * scale;
  const ix = Math.floor(sx);
  const iy = Math.floor(sy);
  const fx = sx - ix;
  const fy = sy - iy;
  const ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10);
  const uy = fy * fy * fy * (fy * (fy * 6 - 15) + 10);

  const a = hash01(ix, iy, seed);
  const b = hash01(ix + 1, iy, seed);
  const c = hash01(ix, iy + 1, seed);
  const d = hash01(ix + 1, iy + 1, seed);
  return lerp(lerp(a, b, ux), lerp(c, d, ux), uy);
}

function fbm(x, y, seed, baseScale, octaves, gain, lacunarity) {
  let total = 0;
  let amp = 0.5;
  let norm = 0;
  let scale = baseScale;
  for (let i = 0; i < octaves; i += 1) {
    total += valueNoise(x, y, scale, seed + i * 131) * amp;
    norm += amp;
    amp *= gain;
    scale *= lacunarity;
  }
  return total / norm;
}

function signedFbm(x, y, seed, baseScale, octaves, gain, lacunarity) {
  return fbm(x, y, seed, baseScale, octaves, gain, lacunarity) * 2 - 1;
}

function distanceToSegment(px, py, ax, ay, bx, by) {
  const vx = bx - ax;
  const vy = by - ay;
  const wx = px - ax;
  const wy = py - ay;
  const denom = vx * vx + vy * vy || 1;
  const t = clamp01((wx * vx + wy * vy) / denom);
  const qx = ax + vx * t;
  const qy = ay + vy * t;
  const dx = px - qx;
  const dy = py - qy;
  return { distance: Math.hypot(dx, dy), t, qx, qy };
}

function polylineDistance(px, py, points) {
  let best = { distance: 999, t: 0, qx: 0, qy: 0, segment: 0 };
  for (let i = 0; i < points.length - 1; i += 1) {
    const a = points[i];
    const b = points[i + 1];
    const d = distanceToSegment(px, py, a.x, a.y, b.x, b.y);
    if (d.distance < best.distance) {
      best = { ...d, segment: i };
    }
  }
  return best;
}

function buildFeatures(seed) {
  const ridges = [];
  const channels = [];

  for (let i = 0; i < 7; i += 1) {
    const cx = hash01(i, seed, 11) * 2.2 - 1.1;
    const cy = hash01(i, seed, 23) * 2.2 - 1.1;
    const angle = hash01(i, seed, 37) * Math.PI * 2;
    const len = lerp(0.65, 1.55, hash01(i, seed, 41));
    const dx = Math.cos(angle) * len * 0.5;
    const dy = Math.sin(angle) * len * 0.5;
    ridges.push({
      ax: cx - dx,
      ay: cy - dy,
      bx: cx + dx,
      by: cy + dy,
      width: lerp(0.035, 0.095, hash01(i, seed, 53)),
      amp: lerp(0.18, 0.48, hash01(i, seed, 67))
    });
  }

  for (let i = 0; i < 8; i += 1) {
    const startX = hash01(i, seed, 71) * 2.2 - 1.1;
    const endX = hash01(i, seed, 83) * 2.2 - 1.1;
    const startY = -1.16 + hash01(i, seed, 97) * 0.32;
    const endY = 1.16 - hash01(i, seed, 109) * 0.32;
    const bend = lerp(-0.42, 0.42, hash01(i, seed, 113));
    const phase = hash01(i, seed, 127) * Math.PI * 2;
    const points = [];
    for (let s = 0; s < 6; s += 1) {
      const t = s / 5;
      const curve = Math.sin(t * Math.PI + phase) * bend;
      points.push({
        x: lerp(startX, endX, t) + curve * Math.sin(t * Math.PI),
        y: lerp(startY, endY, t)
      });
    }
    channels.push({
      points,
      width: lerp(0.028, 0.075, hash01(i, seed, 131)),
      amp: lerp(0.14, 0.40, hash01(i, seed, 149)),
      order: 1 + Math.floor(hash01(i, seed, 151) * 4)
    });
  }

  return { ridges, channels };
}

function macroScaffold(x, y, seed, features) {
  const warpX = signedFbm(x + 17.3, y - 4.2, seed + 300, 1.2, 3, 0.5, 2.1) * 0.22;
  const warpY = signedFbm(x - 8.6, y + 9.5, seed + 460, 1.0, 3, 0.5, 2.0) * 0.22;
  const wx = x + warpX;
  const wy = y + warpY;
  const broad = smoothstep(0.36, 0.82, fbm(wx, wy, seed + 3, 1.15, 4, 0.52, 2.0));

  let range = 0;
  for (const ridge of features.ridges) {
    const d = distanceToSegment(wx, wy, ridge.ax, ridge.ay, ridge.bx, ridge.by);
    range = Math.max(range, Math.exp(-Math.pow(d.distance / (ridge.width * 8.0), 2)) * ridge.amp);
  }

  const lowland = 0.18 * signedFbm(wx, wy, seed + 900, 1.8, 3, 0.48, 2.0);
  return clamp01(0.14 + broad * 0.45 + range * 0.74 + lowland);
}

function structureHeight(x, y, seed, features) {
  let ridgeHeight = 0;
  let valleyCarve = 0;
  let nearestChannel = 999;
  let nearestRidge = 999;

  for (const ridge of features.ridges) {
    const d = distanceToSegment(x, y, ridge.ax, ridge.ay, ridge.bx, ridge.by);
    nearestRidge = Math.min(nearestRidge, d.distance);
    const crest = Math.exp(-Math.pow(d.distance / ridge.width, 2));
    const shoulder = Math.exp(-Math.pow(d.distance / (ridge.width * 3.0), 2)) * 0.42;
    ridgeHeight += (crest + shoulder) * ridge.amp;
  }

  for (const channel of features.channels) {
    const d = polylineDistance(x, y, channel.points);
    nearestChannel = Math.min(nearestChannel, d.distance);
    const floor = Math.exp(-Math.pow(d.distance / channel.width, 2));
    const valley = Math.exp(-Math.pow(d.distance / (channel.width * 4.2), 2)) * 0.5;
    const orderBoost = 0.78 + channel.order * 0.13;
    valleyCarve += (floor + valley) * channel.amp * orderBoost;
  }

  return {
    height: ridgeHeight - valleyCarve,
    ridge: ridgeHeight,
    valley: valleyCarve,
    nearestChannel,
    nearestRidge
  };
}

function residualDetail(x, y, seed, scaffold, structure, viewDetail) {
  const slopeProxy = clamp01(Math.abs(structure.height) * 1.6 + scaffold * 0.45);
  const amp = lerp(0.018, 0.13, slopeProxy) * viewDetail;
  const aligned = signedFbm(x * 1.7 + y * 0.25, y * 0.8 - x * 0.2, seed + 2000, 10, 4, 0.47, 2.04);
  const gullies = Math.abs(signedFbm(x, y, seed + 2200, 19, 3, 0.52, 2.0));
  const benches = signedFbm(x + scaffold * 0.2, y - scaffold * 0.2, seed + 2400, 5.5, 3, 0.5, 2.0);
  return (aligned * 0.72 + (gullies - 0.45) * 0.32 + benches * 0.24) * amp;
}

function patchAssemblyRisk(x, y, seed) {
  const tiles = 4;
  const gx = Math.floor((x * 0.5 + 0.5) * tiles);
  const gy = Math.floor((y * 0.5 + 0.5) * tiles);
  const tx = Math.max(0, Math.min(tiles - 1, gx));
  const ty = Math.max(0, Math.min(tiles - 1, gy));
  const u = (x * 0.5 + 0.5) * tiles - tx;
  const v = (y * 0.5 + 0.5) * tiles - ty;
  const patchSeed = seed + tx * 317 + ty * 911;
  const rot = Math.floor(hash01(tx, ty, seed + 5000) * 4);
  let px = u - 0.5;
  let py = v - 0.5;
  for (let r = 0; r < rot; r += 1) {
    const oldX = px;
    px = -py;
    py = oldX;
  }
  const local = signedFbm(px, py, patchSeed, 2.2, 5, 0.55, 2.0);
  const trend = (hash01(tx, ty, seed + 5100) - 0.5) * px + (hash01(tx, ty, seed + 5200) - 0.5) * py;
  const stamp = Math.sin((px + hash01(tx, ty, seed + 5300)) * Math.PI * 3) * 0.08;
  return local * 0.42 + trend * 0.55 + stamp;
}

function sampleWorld(x, y, seed, features, view) {
  const scaffold = macroScaffold(x, y, seed, features);
  const structure = structureHeight(x, y, seed, features);
  const residual = residualDetail(x, y, seed, scaffold, structure, view.detail);
  const combined = scaffold * 1.18 + structure.height * 0.62 + residual;
  return {
    scaffold,
    structure: structure.height,
    residual,
    combined,
    nearestChannel: structure.nearestChannel,
    nearestRidge: structure.nearestRidge,
    patch: patchAssemblyRisk(x, y, seed)
  };
}

function buildMaps(seed, viewName) {
  const view = VIEW[viewName];
  const features = buildFeatures(seed);
  const maps = {
    scaffold: new Float32Array(SIZE * SIZE),
    structure: new Float32Array(SIZE * SIZE),
    residual: new Float32Array(SIZE * SIZE),
    patch: new Float32Array(SIZE * SIZE),
    combined: new Float32Array(SIZE * SIZE),
    cache: new Float32Array(SIZE * SIZE)
  };

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const wx = x / (SIZE - 1) * 2 - 1;
      const wy = y / (SIZE - 1) * 2 - 1;
      const s = sampleWorld(wx, wy, seed, features, view);
      const idx = y * SIZE + x;
      maps.scaffold[idx] = s.scaffold;
      maps.structure[idx] = s.structure;
      maps.residual[idx] = s.residual;
      maps.patch[idx] = s.patch;
      maps.combined[idx] = s.combined;
    }
  }

  fillCoarseCache(maps.combined, maps.cache, view.coarseCells);
  return { maps, features, view };
}

function sampleArrayBilinear(source, x, y) {
  const x0 = Math.max(0, Math.min(SIZE - 1, Math.floor(x)));
  const y0 = Math.max(0, Math.min(SIZE - 1, Math.floor(y)));
  const x1 = Math.max(0, Math.min(SIZE - 1, x0 + 1));
  const y1 = Math.max(0, Math.min(SIZE - 1, y0 + 1));
  const tx = x - x0;
  const ty = y - y0;
  const a = source[y0 * SIZE + x0];
  const b = source[y0 * SIZE + x1];
  const c = source[y1 * SIZE + x0];
  const d = source[y1 * SIZE + x1];
  return lerp(lerp(a, b, tx), lerp(c, d, tx), ty);
}

function fillCoarseCache(source, target, cells) {
  const grid = new Float32Array(cells * cells);
  for (let gy = 0; gy < cells; gy += 1) {
    for (let gx = 0; gx < cells; gx += 1) {
      const sx = gx / Math.max(1, cells - 1) * (SIZE - 1);
      const sy = gy / Math.max(1, cells - 1) * (SIZE - 1);
      grid[gy * cells + gx] = sampleArrayBilinear(source, sx, sy);
    }
  }

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const gx = x / Math.max(1, SIZE - 1) * (cells - 1);
      const gy = y / Math.max(1, SIZE - 1) * (cells - 1);
      const x0 = Math.floor(gx);
      const y0 = Math.floor(gy);
      const x1 = Math.min(cells - 1, x0 + 1);
      const y1 = Math.min(cells - 1, y0 + 1);
      const tx = gx - x0;
      const ty = gy - y0;
      const a = grid[y0 * cells + x0];
      const b = grid[y0 * cells + x1];
      const c = grid[y1 * cells + x0];
      const d = grid[y1 * cells + x1];
      target[y * SIZE + x] = lerp(lerp(a, b, tx), lerp(c, d, tx), ty);
    }
  }
}

function stats(data) {
  let min = Infinity;
  let max = -Infinity;
  let sumGrad = 0;
  let countGrad = 0;

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const idx = y * SIZE + x;
      const v = data[idx];
      min = Math.min(min, v);
      max = Math.max(max, v);
      if (x > 0) {
        sumGrad += Math.abs(v - data[idx - 1]);
        countGrad += 1;
      }
      if (y > 0) {
        sumGrad += Math.abs(v - data[idx - SIZE]);
        countGrad += 1;
      }
    }
  }

  return {
    min,
    max,
    relief: max - min,
    rough: countGrad ? sumGrad / countGrad : 0
  };
}

function terrainColor(t) {
  const stops = [
    [0.00, [41, 88, 92]],
    [0.20, [65, 123, 93]],
    [0.40, [111, 144, 72]],
    [0.58, [170, 151, 86]],
    [0.75, [133, 121, 112]],
    [1.00, [242, 243, 236]]
  ];
  for (let i = 0; i < stops.length - 1; i += 1) {
    const a = stops[i];
    const b = stops[i + 1];
    if (t >= a[0] && t <= b[0]) {
      return mixColor(a[1], b[1], (t - a[0]) / (b[0] - a[0]));
    }
  }
  return stops[stops.length - 1][1];
}

function residualColor(t) {
  const low = [43, 98, 122];
  const mid = [229, 230, 219];
  const high = [160, 70, 36];
  if (t < 0.5) {
    return mixColor(low, mid, t * 2);
  }
  return mixColor(mid, high, (t - 0.5) * 2);
}

function renderMap(canvas, data, mode) {
  const ctx = canvas.getContext("2d");
  const img = ctx.createImageData(SIZE, SIZE);
  const s = stats(data);
  const denom = s.relief || 1;

  for (let y = 0; y < SIZE; y += 1) {
    for (let x = 0; x < SIZE; x += 1) {
      const idx = y * SIZE + x;
      const value = data[idx];
      const t = clamp01((value - s.min) / denom);

      const xl = Math.max(0, x - 1);
      const xr = Math.min(SIZE - 1, x + 1);
      const yu = Math.max(0, y - 1);
      const yd = Math.min(SIZE - 1, y + 1);
      const dx = data[y * SIZE + xr] - data[y * SIZE + xl];
      const dy = data[yd * SIZE + x] - data[yu * SIZE + x];
      const shade = clamp01(0.68 + (dx * -1.8 + dy * -1.15) * 0.18);

      let color = mode === "residual" ? residualColor(t) : terrainColor(t);
      if (mode === "structure") {
        const signed = clamp01(0.5 + value * 0.85);
        color = residualColor(signed);
      }

      const out = idx * 4;
      img.data[out] = Math.round(color[0] * shade);
      img.data[out + 1] = Math.round(color[1] * shade);
      img.data[out + 2] = Math.round(color[2] * shade);
      img.data[out + 3] = 255;
    }
  }

  ctx.putImageData(img, 0, 0);
  return s;
}

function drawCoarseGrid(canvas, cells) {
  const ctx = canvas.getContext("2d");
  ctx.save();
  ctx.strokeStyle = "rgba(255,255,255,0.28)";
  ctx.lineWidth = 1;
  for (let i = 0; i <= cells; i += 1) {
    const p = Math.round(i / cells * SIZE) + 0.5;
    ctx.beginPath();
    ctx.moveTo(p, 0);
    ctx.lineTo(p, SIZE);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(0, p);
    ctx.lineTo(SIZE, p);
    ctx.stroke();
  }
  ctx.restore();
}

function drawFeatureOverlay(canvas, features, alpha) {
  const ctx = canvas.getContext("2d");
  ctx.save();
  ctx.lineCap = "round";
  ctx.lineJoin = "round";

  for (const ridge of features.ridges) {
    ctx.strokeStyle = `rgba(250,245,236,${alpha})`;
    ctx.lineWidth = 1.4;
    ctx.beginPath();
    ctx.moveTo((ridge.ax * 0.5 + 0.5) * SIZE, (ridge.ay * 0.5 + 0.5) * SIZE);
    ctx.lineTo((ridge.bx * 0.5 + 0.5) * SIZE, (ridge.by * 0.5 + 0.5) * SIZE);
    ctx.stroke();
  }

  for (const channel of features.channels) {
    ctx.strokeStyle = `rgba(42,91,158,${alpha})`;
    ctx.lineWidth = 1.7 + channel.order * 0.35;
    ctx.beginPath();
    channel.points.forEach((point, i) => {
      const px = (point.x * 0.5 + 0.5) * SIZE;
      const py = (point.y * 0.5 + 0.5) * SIZE;
      if (i === 0) {
        ctx.moveTo(px, py);
      } else {
        ctx.lineTo(px, py);
      }
    });
    ctx.stroke();
  }

  ctx.restore();
}

function drawPatchGrid(canvas) {
  const ctx = canvas.getContext("2d");
  ctx.save();
  ctx.strokeStyle = "rgba(255,255,255,0.42)";
  ctx.lineWidth = 2;
  for (let i = 1; i < 4; i += 1) {
    const p = i / 4 * SIZE + 0.5;
    ctx.beginPath();
    ctx.moveTo(p, 0);
    ctx.lineTo(p, SIZE);
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(0, p);
    ctx.lineTo(SIZE, p);
    ctx.stroke();
  }
  ctx.restore();
}

function edgeDelta(data) {
  let sum = 0;
  for (let y = 0; y < SIZE; y += 1) {
    sum += Math.abs(data[y * SIZE] - data[y * SIZE + SIZE - 1]);
  }
  for (let x = 0; x < SIZE; x += 1) {
    sum += Math.abs(data[x] - data[(SIZE - 1) * SIZE + x]);
  }
  return sum / (SIZE * 2);
}

function neighborPatchJump(data) {
  let sum = 0;
  let count = 0;
  for (let i = 1; i < 4; i += 1) {
    const p = Math.round(i / 4 * SIZE);
    for (let y = 0; y < SIZE; y += 1) {
      sum += Math.abs(data[y * SIZE + p] - data[y * SIZE + p - 1]);
      count += 1;
    }
    for (let x = 0; x < SIZE; x += 1) {
      sum += Math.abs(data[p * SIZE + x] - data[(p - 1) * SIZE + x]);
      count += 1;
    }
  }
  return sum / count;
}

function fmt(v) {
  return v.toFixed(3);
}

function rerender() {
  const seed = Math.max(1, Math.min(999999, Number($(ids.seedInput).value) || 1));
  $(ids.seedInput).value = String(seed);
  const { maps, features, view } = buildMaps(seed, currentView);

  const cacheStats = renderMap($(ids.cacheCanvas), maps.cache, "terrain");
  drawCoarseGrid($(ids.cacheCanvas), view.coarseCells);
  const scaffoldStats = renderMap($(ids.scaffoldCanvas), maps.scaffold, "terrain");
  const structureStats = renderMap($(ids.structureCanvas), maps.structure, "structure");
  drawFeatureOverlay($(ids.structureCanvas), features, 0.78);
  const residualStats = renderMap($(ids.residualCanvas), maps.residual, "residual");
  const patchStats = renderMap($(ids.patchCanvas), maps.patch, "residual");
  drawPatchGrid($(ids.patchCanvas));
  const combinedStats = renderMap($(ids.combinedCanvas), maps.combined, "terrain");
  drawFeatureOverlay($(ids.combinedCanvas), features, 0.42);

  $(ids.cacheMetric).textContent = `${view.coarseCells}x${view.coarseCells}`;
  $(ids.scaffoldMetric).textContent = `relief ${fmt(scaffoldStats.relief)}`;
  $(ids.structureMetric).textContent = `relief ${fmt(structureStats.relief)}`;
  $(ids.residualMetric).textContent = `rough ${fmt(residualStats.rough)}`;
  $(ids.patchMetric).textContent = `edge ${fmt(neighborPatchJump(maps.patch))}`;
  $(ids.combinedMetric).textContent = `rough ${fmt(combinedStats.rough)}`;

  $(ids.viewLabel).textContent = view.label;
  $(ids.viewDescription).textContent = view.description;
  $(ids.seamMetric).textContent = `shared eval proxy ${fmt(edgeDelta(maps.combined))}`;
  $(ids.repeatMetric).textContent = `patch boundary jump ${fmt(neighborPatchJump(maps.patch))}`;
  $(ids.lodMetric).textContent = `cache ${view.coarseCells} samples, field ${SIZE} samples`;

  document.querySelectorAll("[data-view]").forEach((button) => {
    button.classList.toggle("active", button.dataset.view === currentView);
  });
}

function bindControls() {
  $(ids.seedInput).addEventListener("change", rerender);
  $(ids.seedInput).addEventListener("input", rerender);
  $(ids.rerollButton).addEventListener("click", () => {
    const current = Number($(ids.seedInput).value) || 1;
    const next = (hash32(current, 7919, 104729) % 999999) + 1;
    $(ids.seedInput).value = String(next);
    rerender();
  });

  document.querySelectorAll("[data-view]").forEach((button) => {
    button.addEventListener("click", () => {
      currentView = button.dataset.view;
      rerender();
    });
  });
}

bindControls();
rerender();
