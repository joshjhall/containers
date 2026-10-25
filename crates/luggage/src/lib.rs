//! Luggage — catalog loader and version/platform resolver for the
//! [containers-db](https://github.com/joshjhall/containers-db) tool catalog.
//!
//! # Overview
//!
//! Luggage consumes the JSON catalog published by containers-db and answers
//! the question *"given a tool, a version request, and a target platform,
//! what is the install plan?"*. It does not (yet) execute installs — that
//! lives in a follow-up issue. The deserialization shapes are in
//! [`containers_common::tooldb`]; the API surface here is the
//! [`Catalog`] / [`Catalog::resolve`] entry point plus the typed
//! [`LuggageError`].
//!
//! # Quick start
//!
//! ```no_run
//! use std::path::PathBuf;
//!
//! use luggage::{Catalog, CatalogSource, Platform, VersionSpec};
//!
//! let catalog = Catalog::load(CatalogSource::LocalPath(PathBuf::from("../containers-db")))?;
//! let platform = Platform { os: "debian".into(), os_version: Some("13".into()), arch: "amd64".into() };
//! let resolved = catalog.resolve("rust", &VersionSpec::Latest, &platform)?;
//! println!("{}@{} via {}", resolved.tool, resolved.version, resolved.method_name);
//! # Ok::<(), luggage::LuggageError>(())
//! ```

pub mod catalog;
pub mod catalog_gen;
pub mod error;
pub mod evidence;
pub mod installer;
pub mod platform;
pub mod policy;
pub mod reconcile;
pub mod resolver;
pub mod sysdeps;

pub use catalog::{Catalog, CatalogSource};
pub use catalog_gen::{AddOutcome, add_version};
pub use error::{ErrorClass, LuggageError, Result};
pub use evidence::{EvidenceOrigin, EvidenceSource, HttpEvidenceSource, refresh_evidence};
pub use installer::verify::VerificationWarning;
pub use installer::{InstallPlan, InstallReport, Installer, InstallerOptions};
pub use platform::Platform;
pub use policy::{PolicyPreset, ResolutionPolicy};
pub use reconcile::{
    CellReport, CellStatus, VersionReconciliation, reconcile_version, reconcile_version_with,
};
pub use resolver::{ResolutionWarning, ResolvedInstall, VersionSpec};

/// Kill in-flight version probes when this process gets SIGINT or SIGTERM,
/// then let the signal's default action terminate it (#1370).
///
/// Every probe leads its own process group so its timeout can kill the
/// whole tree, which also puts it outside the group a terminal Ctrl-C reaches.
/// A binary embedding the installer should call this once at startup, or an
/// interrupt mid-probe leaves the probe running. A library never installs
/// signal handlers by itself. Idempotent. On non-unix targets it does nothing.
///
/// # Errors
///
/// Returns the OS error if the handlers or the watcher thread cannot be set
/// up.
// Off unix the body is a bare `Ok(())`, which clippy wants `const`; on unix it
// calls a non-const fn, so the signature cannot be `const` on every target.
#[cfg_attr(not(unix), allow(clippy::missing_const_for_fn))]
pub fn install_interrupt_handler() -> std::io::Result<()> {
    #[cfg(unix)]
    return installer::interrupt::install_handler();
    #[cfg(not(unix))]
    Ok(())
}
