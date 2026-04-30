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
//! Pinned to **containers-db v0.1.0** (commit `03c1fd5`, tagged 2026-04-26).
//! Bump when the upstream `schemaVersion` const changes.
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
    SupportEntry, SupportStatus, TestEntry, TestResult, ToolVersion, Uninstall, VersionMetadata,
};
