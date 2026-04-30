//! Catalog data structure and loader.
//!
//! The library entry point is [`Catalog::load`]. It eagerly parses every
//! `tools/<id>/index.json` and each `tools/<id>/versions/*.json` file
//! under the supplied root, building a [`HashMap`] keyed by tool id and a
//! per-tool [`BTreeMap`] keyed by parsed [`Version`].
//!
//! Eager loading is fine for the catalog's expected size (low hundreds of
//! versions across all tools). If the catalog grows large enough that this
//! becomes a problem, swap [`Catalog::load`] for a lazy loader.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use containers_common::tooldb::{ActivityScore, Kind, Tool, ToolVersion};
use containers_common::version::{Version, VersionStyle};

use crate::error::{LuggageError, Result};
use crate::platform::Platform;
use crate::policy::ResolutionPolicy;
use crate::resolver::{self, ResolvedInstall, VersionSpec};

/// Where to load the catalog from.
///
/// Only [`Self::LocalPath`] is implemented in v0.1.0. The other variants
/// exist so the API surface is stable for callers; passing them currently
/// returns [`LuggageError::NotImplemented`].
#[derive(Debug, Clone)]
pub enum CatalogSource {
    /// A local checkout of containers-db (or its on-disk layout).
    LocalPath(PathBuf),
    /// A pre-built snapshot served at this URL. Not yet implemented.
    SnapshotUrl(String),
    /// A specific commit of a remote containers-db repo. Not yet implemented.
    PinnedRef {
        /// Repository URL (e.g. `https://github.com/joshjhall/containers-db`).
        repo: String,
        /// Commit SHA to pin to.
        sha: String,
    },
}

/// One tool's catalog data: index plus parsed versions, keyed by parsed [`Version`].
#[derive(Debug, Clone)]
pub struct ToolEntry {
    /// The tool's index document.
    pub index: Tool,
    /// Per-version documents keyed by parsed version literal.
    ///
    /// Stored as a [`BTreeMap`] so callers iterate in version order without
    /// re-sorting; the resolver depends on this.
    pub versions: BTreeMap<Version, ToolVersion>,
}

/// In-memory representation of a containers-db catalog.
#[derive(Debug, Clone, Default)]
pub struct Catalog {
    tools: HashMap<String, ToolEntry>,
}

impl Catalog {
    /// Load the catalog from the given source.
    ///
    /// # Errors
    ///
    /// Returns [`LuggageError::Io`] for filesystem failures,
    /// [`LuggageError::Parse`] for malformed JSON, [`LuggageError::Catalog`]
    /// for cross-file inconsistencies (mismatched `tool` field, duplicate
    /// versions), [`LuggageError::VersionParse`] for unparsable version
    /// literals, and [`LuggageError::NotImplemented`] for non-`LocalPath`
    /// sources.
    pub fn load(source: CatalogSource) -> Result<Self> {
        match source {
            CatalogSource::LocalPath(root) => Self::load_local(&root),
            CatalogSource::SnapshotUrl(_) => {
                Err(LuggageError::NotImplemented("CatalogSource::SnapshotUrl"))
            }
            CatalogSource::PinnedRef { .. } => {
                Err(LuggageError::NotImplemented("CatalogSource::PinnedRef"))
            }
        }
    }

    /// Look up the index document for a tool.
    #[must_use]
    pub fn tool(&self, id: &str) -> Option<&Tool> {
        self.tools.get(id).map(|e| &e.index)
    }

    /// Look up a tool's full entry (index + versions).
    #[must_use]
    pub fn tool_entry(&self, id: &str) -> Option<&ToolEntry> {
        self.tools.get(id)
    }

    /// Resolve `(tool, spec, platform)` into a concrete install plan using
    /// the default [`ResolutionPolicy`] (stibbons-strict).
    ///
    /// # Errors
    ///
    /// See [`resolver::resolve_with_policy`] for the full set of possible errors.
    pub fn resolve(
        &self,
        tool: &str,
        spec: &VersionSpec,
        platform: &Platform,
    ) -> Result<ResolvedInstall> {
        let entry = self.tools.get(tool).ok_or_else(|| LuggageError::ToolNotFound(tool.into()))?;
        resolver::resolve(entry, spec, platform)
    }

    /// Resolve `(tool, spec, platform)` into a concrete install plan, gated
    /// by a caller-supplied [`ResolutionPolicy`].
    ///
    /// # Errors
    ///
    /// See [`resolver::resolve_with_policy`] for the full set of possible errors.
    pub fn resolve_with_policy(
        &self,
        tool: &str,
        spec: &VersionSpec,
        platform: &Platform,
        policy: &ResolutionPolicy,
    ) -> Result<ResolvedInstall> {
        let entry = self.tools.get(tool).ok_or_else(|| LuggageError::ToolNotFound(tool.into()))?;
        resolver::resolve_with_policy(entry, spec, platform, policy)
    }

    /// Tools of the given [`Kind`] whose activity tier is at least
    /// `Maintained`, sorted by `display_name` for deterministic output.
    ///
    /// Use this from the stibbons wizard to populate the recommended-tool
    /// list — the tier filter prevents abandoned tools from leaking into
    /// the picker.
    #[must_use]
    pub fn recommended(&self, kind: Kind) -> Vec<&Tool> {
        let mut out: Vec<&Tool> = self
            .tools
            .values()
            .filter(|e| {
                e.index.kind == kind
                    && e.index.activity.score.is_at_least(ActivityScore::Maintained)
            })
            .map(|e| &e.index)
            .collect();
        out.sort_by(|a, b| a.display_name.cmp(&b.display_name));
        out
    }

    fn load_local(root: &Path) -> Result<Self> {
        let tools_dir = root.join("tools");
        if !tools_dir.is_dir() {
            return Err(LuggageError::Catalog(format!(
                "expected `tools/` directory under {}",
                root.display()
            )));
        }

        let mut tools = HashMap::new();
        for entry in read_dir(&tools_dir)? {
            let entry =
                entry.map_err(|source| LuggageError::Io { path: tools_dir.clone(), source })?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let dir_name = path
                .file_name()
                .and_then(|n| n.to_str())
                .ok_or_else(|| {
                    LuggageError::Catalog(format!(
                        "non-utf8 directory name under tools/: {}",
                        path.display()
                    ))
                })?
                .to_owned();

            let index_path = path.join("index.json");
            let index: Tool = read_json(&index_path)?;
            if index.id != dir_name {
                return Err(LuggageError::Catalog(format!(
                    "tool id `{}` in {} does not match directory `{dir_name}`",
                    index.id,
                    index_path.display(),
                )));
            }

            let style = index.version_style.unwrap_or(VersionStyle::Semver);
            let versions = load_versions(&path, &dir_name, style)?;
            tools.insert(dir_name, ToolEntry { index, versions });
        }

        Ok(Self { tools })
    }

    /// Number of tools in the catalog.
    #[must_use]
    pub fn len(&self) -> usize {
        self.tools.len()
    }

    /// True when the catalog has no tools.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }
}

fn load_versions(
    tool_dir: &Path,
    tool_id: &str,
    style: VersionStyle,
) -> Result<BTreeMap<Version, ToolVersion>> {
    let versions_dir = tool_dir.join("versions");
    if !versions_dir.is_dir() {
        // system_package tracking records have no versions/ directory.
        return Ok(BTreeMap::new());
    }

    let mut out = BTreeMap::new();
    for entry in read_dir(&versions_dir)? {
        let entry =
            entry.map_err(|source| LuggageError::Io { path: versions_dir.clone(), source })?;
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let doc: ToolVersion = read_json(&path)?;
        if doc.tool != tool_id {
            return Err(LuggageError::Catalog(format!(
                "version file {} declares tool `{}` but lives under tools/{tool_id}/",
                path.display(),
                doc.tool,
            )));
        }
        let parsed = Version::parse(&doc.version, style)?;
        if out.insert(parsed.clone(), doc).is_some() {
            return Err(LuggageError::Catalog(format!(
                "duplicate version `{parsed}` for tool `{tool_id}`",
            )));
        }
    }
    Ok(out)
}

fn read_dir(path: &Path) -> Result<std::fs::ReadDir> {
    fs::read_dir(path).map_err(|source| LuggageError::Io { path: path.to_owned(), source })
}

fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let bytes =
        fs::read(path).map_err(|source| LuggageError::Io { path: path.to_owned(), source })?;
    serde_json::from_slice(&bytes)
        .map_err(|source| LuggageError::Parse { path: path.to_owned(), source })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn write_minimal_catalog(root: &Path) {
        let rust_dir = root.join("tools/rust/versions");
        fs::create_dir_all(&rust_dir).unwrap();
        fs::write(
            root.join("tools/rust/index.json"),
            r#"{
                "schemaVersion": 1,
                "id": "rust",
                "display_name": "Rust",
                "kind": "language",
                "activity": { "score": "very-active", "scanned_at": "2026-01-01T00:00:00Z" },
                "version_style": "semver",
                "default_version": "1.95.0",
                "channels": { "stable": { "description": "stable", "default": true } },
                "available": [{"version": "1.84.0"}, {"version": "1.95.0"}]
            }"#,
        )
        .unwrap();
        fs::write(
            rust_dir.join("1.84.0.json"),
            r#"{
                "schemaVersion": 1,
                "tool": "rust",
                "version": "1.84.0",
                "channel": "stable",
                "support_matrix": [],
                "install_methods": [
                    {
                        "name": "stub",
                        "verification": { "tier": 4, "tofu": true }
                    }
                ],
                "metadata": {
                    "added_at": "2026-01-01T00:00:00Z",
                    "schema_version": 1
                }
            }"#,
        )
        .unwrap();
        fs::write(
            rust_dir.join("1.95.0.json"),
            r#"{
                "schemaVersion": 1,
                "tool": "rust",
                "version": "1.95.0",
                "channel": "stable",
                "support_matrix": [],
                "install_methods": [
                    {
                        "name": "stub",
                        "verification": { "tier": 4, "tofu": true }
                    }
                ],
                "metadata": {
                    "added_at": "2026-01-01T00:00:00Z",
                    "schema_version": 1
                }
            }"#,
        )
        .unwrap();
    }

    #[test]
    fn loads_minimal_catalog() {
        let tmp = tempfile::tempdir().unwrap();
        write_minimal_catalog(tmp.path());

        let cat = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap();
        assert_eq!(cat.len(), 1);
        let tool = cat.tool("rust").expect("tool present");
        assert_eq!(tool.id, "rust");
        let entry = cat.tool_entry("rust").unwrap();
        assert_eq!(entry.versions.len(), 2);
    }

    #[test]
    fn rejects_missing_tools_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let err = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap_err();
        assert!(matches!(err, LuggageError::Catalog(_)));
    }

    #[test]
    fn snapshot_url_is_not_implemented() {
        let err =
            Catalog::load(CatalogSource::SnapshotUrl("https://example.test".into())).unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn pinned_ref_is_not_implemented() {
        let err = Catalog::load(CatalogSource::PinnedRef {
            repo: "https://example.test/x".into(),
            sha: "abc".into(),
        })
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn rejects_mismatched_tool_field() {
        let tmp = tempfile::tempdir().unwrap();
        write_minimal_catalog(tmp.path());
        // Tamper with the version file to declare the wrong tool.
        fs::write(
            tmp.path().join("tools/rust/versions/1.84.0.json"),
            r#"{
                "schemaVersion": 1,
                "tool": "wrong",
                "version": "1.84.0",
                "channel": "stable",
                "support_matrix": [],
                "install_methods": [
                    {
                        "name": "stub",
                        "verification": { "tier": 4, "tofu": true }
                    }
                ],
                "metadata": {
                    "added_at": "2026-01-01T00:00:00Z",
                    "schema_version": 1
                }
            }"#,
        )
        .unwrap();
        let err = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap_err();
        match err {
            LuggageError::Catalog(msg) => assert!(msg.contains("declares tool `wrong`")),
            other => panic!("expected Catalog error, got {other:?}"),
        }
    }

    #[test]
    fn missing_tool_returns_none() {
        let tmp = tempfile::tempdir().unwrap();
        write_minimal_catalog(tmp.path());
        let cat = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap();
        assert!(cat.tool("ghost").is_none());
    }

    #[test]
    fn skips_dir_entries_in_versions_that_are_not_json() {
        let tmp = tempfile::tempdir().unwrap();
        write_minimal_catalog(tmp.path());
        fs::write(tmp.path().join("tools/rust/versions/notes.txt"), "ignored").unwrap();
        let cat = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap();
        assert_eq!(cat.tool_entry("rust").unwrap().versions.len(), 2);
    }

    fn write_tool(root: &Path, id: &str, kind: &str, score: &str, display_name: &str) {
        let dir = root.join(format!("tools/{id}"));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("index.json"),
            format!(
                r#"{{
                    "schemaVersion": 1,
                    "id": "{id}",
                    "display_name": "{display_name}",
                    "kind": "{kind}",
                    "activity": {{ "score": "{score}", "scanned_at": "2026-01-01T00:00:00Z" }}
                }}"#,
            ),
        )
        .unwrap();
    }

    #[test]
    fn recommended_filters_by_kind_and_activity() {
        let tmp = tempfile::tempdir().unwrap();
        // Build a mixed catalog: two CLI tools above the cutoff, one CLI
        // below, one Library above (different kind).
        write_tool(tmp.path(), "tool_a", "cli", "very-active", "Aardvark");
        write_tool(tmp.path(), "tool_c", "cli", "maintained", "Camel");
        write_tool(tmp.path(), "tool_d", "cli", "stale", "Dingo");
        write_tool(tmp.path(), "tool_b", "library", "very-active", "Bobcat");

        let cat = Catalog::load(CatalogSource::LocalPath(tmp.path().to_owned())).unwrap();
        let recommended = cat.recommended(Kind::Cli);
        let names: Vec<&str> = recommended.iter().map(|t| t.display_name.as_str()).collect();
        assert_eq!(names, ["Aardvark", "Camel"], "expected sorted CLI tools above cutoff");

        let libraries = cat.recommended(Kind::Library);
        assert_eq!(libraries.len(), 1);
        assert_eq!(libraries[0].id, "tool_b");

        // Service kind is empty in this fixture.
        assert!(cat.recommended(Kind::Service).is_empty());
    }
}
