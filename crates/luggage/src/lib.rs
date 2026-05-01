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
pub mod error;
pub mod installer;
pub mod platform;
pub mod policy;
pub mod resolver;

pub use catalog::{Catalog, CatalogSource};
pub use error::{LuggageError, Result};
pub use installer::{InstallPlan, InstallReport, Installer, InstallerOptions};
pub use platform::Platform;
pub use policy::{PolicyPreset, ResolutionPolicy};
pub use resolver::{ResolutionWarning, ResolvedInstall, VersionSpec};
