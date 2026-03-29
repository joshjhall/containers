//! Template rendering system — renders configuration files from feature selections.
//!
//! Ports the Go `text/template` system to Rust using minijinja. Produces
//! byte-identical output to the Go implementation.

mod context;
mod funcmap;
mod renderer;

#[cfg(test)]
mod tests;

pub use context::RenderContext;
pub use funcmap::{BuildArgEntry, BuildArgGroup, grouped_build_args};
pub use renderer::Renderer;
