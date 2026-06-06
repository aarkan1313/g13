//! Map a DEM tile filename to its terrain archetype (03_DEM_CATALOG). Pure.

/// The 12 canonical archetypes (after folds). Order is stable.
pub const ARCHETYPES: [&str; 12] = [
    "mountain", "badlands", "volcanic", "glacial", "desert", "karst",
    "grassland", "wetland", "coast", "rainforest", "temperate", "tundra",
];

/// Extract the archetype from a tile file stem (no extension). Returns None if
/// the stem doesn't match a known archetype (caller logs + skips).
pub fn archetype_of(stem: &str) -> Option<&'static str> {
    // Strip a leading "COP30_" and an optional "bulk<digits>_" prefix.
    let mut s = stem.strip_prefix("COP30_").unwrap_or(stem);
    if let Some(rest) = s.strip_prefix("bulk") {
        // rest begins with digits then '_'; drop through the first '_'.
        if let Some(us) = rest.find('_') {
            s = &rest[us + 1..];
        }
    }
    // Folds: a leading token that maps to a canonical archetype.
    const FOLDS: &[(&str, &str)] = &[
        ("sahara", "desert"),
        ("andes", "mountain"),
        ("amazon", "rainforest"),
        ("cliff_coast", "coast"),
        ("fjord_coast", "coast"),
        ("delta_coast", "coast"),
        ("sandy_coast", "coast"),
    ];
    for (pat, arche) in FOLDS {
        if s.starts_with(pat) {
            return Some(arche);
        }
    }
    for a in ARCHETYPES {
        if s.starts_with(a) {
            return Some(a);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_filenames() {
        assert_eq!(archetype_of("bulk20260524_mountain_alps_mont_blanc"), Some("mountain"));
        assert_eq!(archetype_of("bulk20260524_grassland_kazakh_steppe"), Some("grassland"));
        assert_eq!(archetype_of("COP30_andes_patagonia_-72_0_-41_15"), Some("mountain")); // fold
        assert_eq!(archetype_of("COP30_amazon_manaus_-60_0_-3_2"), Some("rainforest"));   // fold
        assert_eq!(archetype_of("sahara_erg_chebbi"), Some("desert"));                    // fold
        assert_eq!(archetype_of("cliff_coast_big_sur"), Some("coast"));                   // fold
        assert_eq!(archetype_of("fjord_coast_milford_sound"), Some("coast"));             // fold
        assert_eq!(archetype_of("temperate_black_forest"), Some("temperate"));
        assert_eq!(archetype_of("volcanic_hawaii_kilauea"), Some("volcanic"));
        assert_eq!(archetype_of("nonsense_place"), None);
    }
}
