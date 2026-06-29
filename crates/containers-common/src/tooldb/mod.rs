//! Catalog data types — pure deserialization shapes for the
//! [containers-db](https://github.com/joshjhall/containers-db) catalog.
//!
//! This module is the Rust mirror of the JSON Schemas in containers-db
//! (`schema/tool.schema.json`, `schema/version.schema.json`). The types
//! here perform no I/O and know nothing about the on-disk layout — see
//! the `luggage` crate for a loader and resolver that consume them.
//!
//! # Compatibility
//!
//! Pinned to **containers-db** commit `aa14378` (tagged 2026-05-14).
//! `schemaVersion` remains `1` — the 2026-05-14 update added optional
//! evidence fields to [`TestEntry`] (`image_ref`, `image_digest`,
//! `duration_seconds`, `version_output`, `error_class`) but kept the
//! shape backward-compatible. Bump the pin when `schemaVersion` itself
//! changes upstream.
//!
//! # Forward compatibility
//!
//! Most structs use `#[serde(deny_unknown_fields)]` to mirror the schema's
//! `additionalProperties: false`. A few enums (`Kind`, `PostInstall`) use
//! `#[serde(other)]` fallback variants so that adding a new value upstream
//! does not break older luggage builds.

mod dependency;
mod install_method;
mod tool;
mod version;

pub use dependency::{Dependency, DependencyPurpose};
pub use install_method::{
    InstallMethod, Invoke, PlatformPredicate, PostInstall, StringOrVec, Verification,
};
pub use tool::{
    Activity, ActivityScore, ActivitySignals, Alternative, AlternativeRelationship, AvailableEntry,
    Channel, Kind, Ordering, SystemPackage, SystemPackagePlatform, TierSummary, Tool,
    ValidationTiers,
};
pub use version::{
    ErrorClass, InstalledDependency, SupportEntry, SupportStatus, TestEntry, TestResult,
    ToolVersion, Uninstall, VersionMetadata,
};
