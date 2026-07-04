//! Read-only introspection commands: `version`, `features`, and `status`.
//!
//! These are the Rust ports of the retired Go `igor` commands of the same
//! names (issue #306). Each command body lives in its own module and writes to
//! a caller-supplied [`std::io::Write`] sink so the output can be captured in
//! tests (the Rust analogue of Go's `cmd.OutOrStdout()`), while `main.rs`
//! passes `std::io::stdout()`.
//!
//! - [`version`] — print the stibbons version and, when detectable, the
//!   containers submodule version.
//! - [`features`] — list all registry features as an aligned table or markdown.
//! - [`status`] — load `.igor.yml`, show resolved features, and detect drift in
//!   the generated files via SHA-256 comparison.

pub mod features;
pub mod status;
pub mod version;
