# DEM Catalog — reference terrain library for M2

**Status:** reference data inventory. Created 2026-06-06 during the WG13 setup pass.
**Why this exists:** `MILESTONE_2_biomes.md` §3 uses DEM *statistics* (slope/roughness, feature spacing) to make procedural biomes read as real. This doc records exactly which DEMs we have and how they map to biomes, so M2.5/M2.6 start from an inventory instead of a scavenger hunt.

**Hard rule (from `00_ARCHITECTURE.md §6` and M2 §3):** DEMs live OUTSIDE the runtime. The offline stats tool reads these `.tif` files and emits small distilled params into `WorldConfig`. The runtime never opens a `.tif`. If you ever load one of these at runtime, STOP and log it — that is an architecture violation.

---

## Where the data is

All under `archive/from_workflows_worldgen9/dems/` (gitignored — not in the repo, on disk only).

| Set | Path | Count | Notes |
|---|---|---|---|
| **Labeled reference library** | `dems/opentopo/` | 135 `.tif` + 135 `.json` sidecars (~15.6 GB) | **Primary set for M2.** Semantically named by terrain type + place. Use these. |
| Raw bulk tiles | `dems/*.tif` (top level) | 657 `.tif` (~63 GB) | Source-named by lat/lon bbox (COP30/USGS/LINZ/AW3D30/GEBCO/ArcticDEM/REMA/SRTM15Plus). Secondary — pull from here only if a category needs more samples. |

### Sidecar JSON schema (each `opentopo/*.tif.json`)
```json
{
  "source": "OpenTopography Global DEM API",
  "demtype": "COP30",
  "bounds": { "south": -5.25, "north": -4.75, "west": -63.75, "east": -63.25 },
  "crs": "EPSG:4326",
  "width": 1800, "height": 1800,
  "dtypes": ["float32"],
  "nodata": null
}
```
The stats tool keys off `demtype`, `bounds`, `width/height`, and `dtypes`. `crs` is geographic (EPSG:4326), so the tool must convert degree spacing → metres (≈111 320 m per degree latitude; longitude scaled by cos(lat)) before computing slope distributions, or slopes will be wrong by the cos(lat) factor.

---

## Labeled library by terrain archetype (the M2 palette)

135 tiles across ~12 well-populated archetypes. Singleton categories fold into a parent (noted). This maps almost 1:1 onto the Whittaker biome table M2.2 builds.

| Archetype | Tiles | Folds in | Example regions |
|---|---:|---|---|
| **mountain** | 10 (+1 andes) | andes→mountain | Alps/Mont Blanc, Caucasus/Svaneti, Pamir, Rockies/Banff, Sierra Nevada, Tian Shan, Taiwan Central, Drakensberg, Ethiopian Highlands, New Guinea, Andes/Patagonia |
| **badlands** | 12 | — | Grand Canyon, Utah Canyonlands, Bardenas Reales, Cappadocia, Colca Canyon, Death Valley, Fish River, Flinders, Painted Desert, Tibetan Gorge, Wadi Mujib, Zhangye Danxia |
| **volcanic** | 12 | — | Etna, Azores/Pico, Fuji, Kamchatka, Merapi, Pinatubo, Réunion, Taupo, Tenerife, Virunga, Hawaii/Kilauea, Iceland Highlands |
| **glacial** | 10 | — | Alaska Glacier Bay, Baffin, Chile Fjords, Greenland East, Iceland/Vatnajökull, Kerguelen, Norway/Lyngen, NZ Southern Alps, Patagonia Icefield, South Georgia |
| **desert** | 10 (+4 sahara) | sahara→desert | Atacama, Danakil, Gobi/Altai, Lut Yardangs, Namib/Sossusvlei, Simpson Dunes, Sonoran, Taklamakan, Thar, Wadi Rum, Erg Chebbi, Great Sand Sea, Rub al Khali, Ténéré |
| **karst** | 11 | — | Appalachian Valley, Bohol Chocolate Hills, Dinaric Balkans, Ha Long, Madagascar Tsingy, Mulu/Borneo, Phong Nha, Puerto Rico Mogotes, Slovenia, Yucatán, Guilin/Guangxi |
| **grassland** | 11 | — | Cerrado, Deccan, Highveld, Kazakh Steppe, Mongolia Steppe, Nebraska Sandhills, Pampas, Patagonia Steppe, Sahel/Chad, Serengeti, Flint Hills |
| **wetland** | 11 | delta→wetland | Danube/Everglades/Niger/Lena/Mekong/Okavango/Orinoco/Pantanal/Salween/Sundarbans deltas, Mississippi |
| **coast** | 11 (+fjord, sandy, cliff) | fjord/sandy/cliff→coast | Amalfi, Dalmatian, Maine, Musandam, Nova Scotia, Oregon, Peru Desert, Sanriku, Tasmania W, Wild Coast, Milford Sound (fjord), Outer Banks (sandy), Big Sur (cliff), Iceland South |
| **rainforest** | 10 (+4 amazon) | amazon→rainforest | Borneo (Kalimantan/Sabah), Brazil Atlantic, Congo (Ituri/Lualaba), Daintree, Guiana Shield, Madagascar E, Papua/Sepik, Sumatra/Barisan, Amazon (interior/Manaus/Solimões/Trombetas) |
| **temperate** | 7 | — | Appalachian Blue Ridge, Black Forest, Cantabria, Carpathians, NZ Southern Alps foot, Tasmania Highlands, Vermont Greens |
| **tundra** | 7 | — | Alaska Brooks/North Slope, Canadian Arctic/Baffin, Greenland Fringe, Iceland Interior, Siberia/Taymyr, Svalbard |

---

## How M2 uses this (priority, matching M2 §3)

1. **M2.5 — slope/roughness stats (do this first, low risk).** Offline tool walks `opentopo/`, groups by archetype, computes per-archetype slope distribution + feature-spacing (frequency analysis). Emits a small params file (one row per archetype) into `WorldConfig`. **Start with `mountain` and `grassland`/`temperate`** — the clearest contrast for a first believability check.
2. **M2.6 — wire mountain/hill biomes to use those params.** Visual gate: DEM-informed terrain vs pure-noise, side by side.
3. **Later (not M2):** DEM tiles as noise kernels (#2), feature templates (#3). Deferred per M2 §3.

## Note on the raw bulk set
The 657 top-level tiles are named `SOURCE_<west>_<...>_<bounds>.tif` (no semantic label). Only reach for them if an archetype proves under-sampled for stable statistics. For M2 the 135 labeled tiles are plenty.
