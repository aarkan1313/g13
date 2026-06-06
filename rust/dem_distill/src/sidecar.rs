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

#[derive(Deserialize)]
pub struct Sidecar {
    pub bounds: Bounds,
    pub width: u32,
    pub height: u32,
}

impl Sidecar {
    pub fn from_str(s: &str) -> Result<Self, String> {
        serde_json::from_str(s).map_err(|e| format!("sidecar parse: {e}"))
    }
    /// Centre latitude (degrees) — for the cos(lat) longitude correction.
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

    #[test]
    fn parses_sample() {
        let s = Sidecar::from_str(SAMPLE).unwrap();
        assert_eq!(s.width, 2880);
        assert_eq!(s.height, 2520);
        assert!((s.center_lat() - (-41.15)).abs() < 1e-9);
        assert!((s.bounds.east - (-71.6)).abs() < 1e-9);
    }
}
