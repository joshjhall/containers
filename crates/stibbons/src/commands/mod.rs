//! Subcommand bodies for the `stibbons` CLI.
//!
//! Each module here is the implementation of one command (or one closely
//! related pair); `main` holds only the `clap` dispatch that routes into them,
//! and [`crate::cli`] holds the argument types they receive. Issue #846 moved
//! the mutating commands in beside the read-only ones that already lived here,
//! so this module is now the single home for every command body.
//!
//! The read-only introspection commands are the Rust ports of the retired Go
//! `igor` commands of the same names (issue #306). They write to a
//! caller-supplied [`std::io::Write`] sink so the output can be captured in
//! tests (the Rust analogue of Go's `cmd.OutOrStdout()`), while `main` passes
//! `std::io::stdout()`. The mutating commands print directly and report
//! failure through `Result`.
//!
//! Mutating:
//!
//! - [`init`] — scaffold a new project from the wizard or an existing
//!   `.igor.yml`.
//! - [`add_remove`] — change the feature selection and re-render.
//! - [`update`] — re-render the existing selection after a version bump.
//! - [`setup`] — repository configuration (today: issue-tracker label sync).
//!
//! Read-only:
//!
//! - [`version`] — print the stibbons version and, when detectable, the
//!   containers submodule version.
//! - [`features`] — list all registry features as an aligned table or markdown.
//! - [`status`] — load `.igor.yml`, show resolved features, and detect drift in
//!   the generated files via SHA-256 comparison.
//!
//! [`shared`] holds the plumbing used by more than one of the above.

pub mod add_remove;
pub mod features;
pub mod init;
pub mod setup;
pub mod shared;
pub mod status;
pub mod update;
pub mod version;
