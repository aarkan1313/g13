//! WG13 GDExtension entry point.
//!
//! M1.1 scope: prove that Rust code loads and runs inside Godot 4.6.2 and that
//! hot reload works (edit -> cargo build -> see change without restarting the
//! editor). No terrain, no GPU, no field yet — just the Rust <-> Godot bridge.
//!
//! Architecture (00_ARCHITECTURE.md §4): this crate will grow to own the runtime
//! around the GPU field (scheduling, residency, terrain view, facts, readback
//! tests). It must never re-implement the world math on the CPU — that lives in
//! wg-13/shaders/ GLSL, the single source of truth.

use godot::classes::INode;
use godot::prelude::*;

mod field_compute;

/// The extension library marker. Godot calls the generated `gdext_rust_init`
/// entry symbol (see wg13.gdextension) to register everything below.
struct Wg13Extension;

#[gdextension]
unsafe impl ExtensionLibrary for Wg13Extension {}

/// Root node for the WG13 world. For M1.1 it only announces itself on `_ready`,
/// which is the visible signal the bridge + hot reload are working.
#[derive(GodotClass)]
#[class(base = Node)]
struct WorldRoot {
    base: Base<Node>,
}

#[godot_api]
impl INode for WorldRoot {
    fn init(base: Base<Node>) -> Self {
        Self { base }
    }

    fn ready(&mut self) {
        // M1.1 visual gate: this string appears in the Godot console on run.
        // Change it, `cargo build`, and confirm the new string shows WITHOUT
        // restarting the editor to prove hot reload.
        godot_print!("WG13 WorldRoot ready — Rust bridge live (M1.1).");
    }
}
