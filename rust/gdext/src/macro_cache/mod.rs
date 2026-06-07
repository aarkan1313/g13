//! M2.4c macro-cache (step 1: pure-Rust bake + bounded cache).
mod region;
pub use region::{
    MacroBakeConfig, RegionMacro, DEFAULT_MACRO_BAKE_SPACING_M, DEFAULT_MACRO_SUPER_REGION_M,
};
mod bake;
pub use bake::MacroBake;
mod cache;
pub use cache::RegionCache;
mod kernels;
pub use kernels::{kernel_surface, KernelAtlas};
