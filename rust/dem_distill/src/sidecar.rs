//! Parse a DEM .tif.json sidecar (03_DEM_CATALOG schema). Only the fields the
//! distiller needs; serde ignores the rest.

use serde::Deserialize;

#[derive(Deserialize, Clone, Copy)]
pub struct Bounds {
    pub south: f64,
    pub north: f64,
    pub west: f64,
    pub east: f64,
}

/// Sidecar fields the distiller needs. Only `bounds` is required (for the
/// cos(lat) spacing); width/height are OPTIONAL because some tiles (e.g. the
/// temperate/tundra set) ship an abbreviated sidecar without them — the real
/// grid dimensions come from the .tif itself anyway (dec.dimensions()).
#[derive(Deserialize)]
pub struct Sidecar {
    pub bounds: Bounds,
    #[serde(default)]
    pub width: Option<u32>,
    #[serde(default)]
    pub height: Option<u32>,
}

impl Sidecar {
    pub fn from_str(s: &str) -> Result<Self, String> {
        serde_json::from_str(s).map_err(|e| format!("sidecar parse: {e}"))
    }
    /// Centre latitude (degrees) — for the cos(lat) longitude correction.
    /// (cell_spacing_m computes this inline; kept as a tested accessor.)
    #[allow(dead_code)]
    pub fn center_lat(&self) -> f64 {
        (self.bounds.south + self.bounds.north) * 0.5
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const SAMPLE: &str = r#"{
        "demtype":"COP30",
        "bounds":{"south":-41.5,"north":-40.8,"west":-72.4,"east":-71.6},
        "crs":"EPSG:4326","width":2880,"height":2520,
        "dtypes":["float32"],"nodata":null }"#;

    const SAMPLE_NO_DIMS: &str = r#"{
        "demtype":"COP30",
        "bounds":{"south":48.0,"north":48.5,"west":8.0,"east":8.5} }"#;

    #[test]
    fn parses_sample() {
        let s = Sidecar::from_str(SAMPLE).unwrap();
        assert_eq!(s.width, Some(2880));
        assert_eq!(s.height, Some(2520));
        assert!((s.center_lat() - (-41.15)).abs() < 1e-9);
        assert!((s.bounds.east - (-71.6)).abs() < 1e-9);
    }

    #[test]
    fn parses_abbreviated_sidecar_without_dims() {
        // temperate/tundra tiles ship bounds only — must still parse (dims come
        // from the .tif). Regression: these were wrongly skipped before.
        let s = Sidecar::from_str(SAMPLE_NO_DIMS).unwrap();
        assert!(s.width.is_none() && s.height.is_none());
        assert!((s.bounds.north - 48.5).abs() < 1e-9);
    }
}
