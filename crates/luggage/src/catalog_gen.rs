//! Generate new `versions/<v>.json` entries in a vendored luggage catalog
//! by cloning a tool's most recent existing version file.
//!
//! This is the write-side counterpart to [`crate::catalog`]'s read path. It
//! exists so the version-bump pipeline can keep the vendored catalog snapshot
//! (`crates/luggage/testdata/catalog`, COPY'd into the image at build time) in
//! lockstep with a Dockerfile pin: when the auto-patch bumps a luggage-managed
//! tool, it calls `luggage catalog add-version <tool>@<version>` so the build's
//! `luggage install` can resolve the new pin instead of failing with
//! "no version of `<tool>` matches spec `<version>`".
//!
//! Approach mirrors the containers-db scanner (`scanner/src/generate.rs`):
//! deep-clone the latest existing version file, swap the top-level
//! `version` / `released` / `metadata` fields, then walk the rest of the JSON
//! and replace any remaining whole-string occurrence of the old version (this
//! catches `install_methods[].invoke.args[N]`, where rust hard-codes the
//! toolchain version in the rustup invocation). The change is deliberately
//! **additive**: `default_version` and `activity` in `index.json` are left
//! untouched so existing default-resolution behaviour (and its golden tests)
//! is unaffected.

use std::fs;
use std::path::{Path, PathBuf};

use containers_common::version::{Version, VersionStyle};
use serde_json::{Value, json};

use crate::error::{LuggageError, Result};

/// Outcome of [`add_version`].
#[derive(Debug, PartialEq, Eq)]
pub enum AddOutcome {
    /// The version was already in the catalog (version file exists or the id
    /// is already listed in `available[]`); nothing was written. Idempotent
    /// re-runs land here.
    AlreadyPresent,
    /// A new version file was written and `index.json` updated.
    Added {
        /// Version whose file was used as the render template.
        template_version: String,
        /// Path of the version file written.
        version_path: PathBuf,
        /// Path of the index that was updated.
        index_path: PathBuf,
    },
}

/// Add `version` for `tool` to the catalog rooted at `catalog`, cloning the
/// latest existing version entry as a template.
///
/// `released` is the upstream release date (`YYYY-MM-DD`); when `None` it
/// defaults to the date portion of `now_rfc3339`. `now_rfc3339` stamps
/// `metadata.{added_at,updated_at}` — passed in (rather than read from the
/// clock) so the generation is deterministic and unit-testable.
///
/// # Errors
///
/// Returns [`LuggageError::Catalog`] when the tool directory has no existing
/// version file to template from, and [`LuggageError::Io`] /
/// [`LuggageError::Parse`] on filesystem or JSON failures.
pub fn add_version(
    catalog: &Path,
    tool: &str,
    version: &str,
    released: Option<&str>,
    now_rfc3339: &str,
) -> Result<AddOutcome> {
    let tool_dir = catalog.join("tools").join(tool);
    let versions_dir = tool_dir.join("versions");
    let index_path = tool_dir.join("index.json");
    let version_path = versions_dir.join(format!("{version}.json"));

    let mut index = read_json(&index_path)?;

    // Idempotent: a re-run for a version we already carry is a no-op. Guard on
    // both the on-disk file and the index listing so a partial prior run still
    // converges.
    if version_path.exists() || index_listed(&index, version) {
        return Ok(AddOutcome::AlreadyPresent);
    }

    let template_version = latest_existing_version(&versions_dir)?.ok_or_else(|| {
        LuggageError::Catalog(format!(
            "tool `{tool}` has no existing version file under {} to use as a template",
            versions_dir.display()
        ))
    })?;
    let template = read_json(&versions_dir.join(format!("{template_version}.json")))?;

    let released = released.unwrap_or_else(|| date_part(now_rfc3339));
    let new_version =
        render_new_version(&template, &template_version, version, released, now_rfc3339);

    write_json(&version_path, &new_version)?;
    add_version_to_index(&mut index, version);
    write_json(&index_path, &index)?;

    Ok(AddOutcome::Added { template_version, version_path, index_path })
}

/// Build a new version-file [`Value`] from `template` (the latest existing
/// version file for the same tool) and the version being added.
#[must_use]
pub fn render_new_version(
    template: &Value,
    old_version: &str,
    new_version: &str,
    released: &str,
    now_rfc3339: &str,
) -> Value {
    let mut out = template.clone();

    if let Some(obj) = out.as_object_mut() {
        obj.insert("version".into(), Value::String(new_version.to_owned()));
        obj.insert("released".into(), Value::String(released.to_owned()));
        let metadata = obj.entry("metadata").or_insert_with(|| json!({}));
        if let Some(m) = metadata.as_object_mut() {
            m.insert("added_at".into(), Value::String(now_rfc3339.to_owned()));
            m.insert("updated_at".into(), Value::String(now_rfc3339.to_owned()));
            m.entry("schema_version").or_insert_with(|| json!(1));
        }
    }

    // Catch literal version strings buried elsewhere (e.g. the rustup
    // `--default-toolchain <v>` arg). Whole-string match only, so version-shaped
    // substrings inside URL templates or prose are left alone.
    rewrite_string_matches(&mut out, old_version, new_version);
    out
}

/// Append `{ "version": new_version }` to the index `available[]` array when
/// absent. Leaves `default_version` and `activity` untouched (additive only).
pub fn add_version_to_index(index: &mut Value, new_version: &str) {
    let Some(obj) = index.as_object_mut() else {
        return;
    };
    let available = obj.entry("available").or_insert_with(|| json!([])).as_array_mut();
    let Some(available) = available else {
        return;
    };
    if !available.iter().any(|e| e.get("version").and_then(Value::as_str) == Some(new_version)) {
        available.push(json!({ "version": new_version }));
    }
}

/// Highest semver among the `<v>.json` basenames in `versions_dir`, returned
/// as the original basename string. Non-semver filenames are skipped.
///
/// # Errors
///
/// Returns [`LuggageError::Io`] if the directory cannot be read.
pub fn latest_existing_version(versions_dir: &Path) -> Result<Option<String>> {
    let entries = fs::read_dir(versions_dir)
        .map_err(|source| LuggageError::Io { path: versions_dir.to_path_buf(), source })?;

    let mut best: Option<(Version, String)> = None;
    for entry in entries {
        let entry = entry
            .map_err(|source| LuggageError::Io { path: versions_dir.to_path_buf(), source })?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let Some(stem) = name.strip_suffix(".json") else { continue };
        let Ok(parsed) = Version::parse(stem, VersionStyle::Semver) else { continue };
        if best.as_ref().is_none_or(|(b, _)| parsed > *b) {
            best = Some((parsed, stem.to_owned()));
        }
    }
    Ok(best.map(|(_, s)| s))
}

/// True when `version` already appears in the index `available[]` array.
fn index_listed(index: &Value, version: &str) -> bool {
    index.get("available").and_then(Value::as_array).is_some_and(|arr| {
        arr.iter().any(|e| e.get("version").and_then(Value::as_str) == Some(version))
    })
}

/// Date portion (`YYYY-MM-DD`) of an RFC3339 timestamp, or the whole string if
/// there is no `T` separator.
fn date_part(rfc3339: &str) -> &str {
    rfc3339.split_once('T').map_or(rfc3339, |(d, _)| d)
}

/// Walk every string in `value`, replacing whole-string matches of `from`
/// with `to`. Substring matches are ignored on purpose.
fn rewrite_string_matches(value: &mut Value, from: &str, to: &str) {
    match value {
        Value::String(s) if s == from => to.clone_into(s),
        Value::Array(arr) => {
            for v in arr.iter_mut() {
                rewrite_string_matches(v, from, to);
            }
        }
        Value::Object(map) => {
            for v in map.values_mut() {
                rewrite_string_matches(v, from, to);
            }
        }
        _ => {}
    }
}

fn read_json(path: &Path) -> Result<Value> {
    let bytes =
        fs::read(path).map_err(|source| LuggageError::Io { path: path.to_path_buf(), source })?;
    serde_json::from_slice(&bytes)
        .map_err(|source| LuggageError::Parse { path: path.to_path_buf(), source })
}

/// Write `value` as pretty JSON with a trailing newline. Formatting is
/// normalized downstream by the auto-patch dprint step; here we only need
/// valid, stable JSON.
fn write_json(path: &Path, value: &Value) -> Result<()> {
    let mut out = serde_json::to_string_pretty(value)
        .map_err(|source| LuggageError::Parse { path: path.to_path_buf(), source })?;
    out.push('\n');
    fs::write(path, out).map_err(|source| LuggageError::Io { path: path.to_path_buf(), source })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn template() -> Value {
        json!({
            "schemaVersion": 1,
            "tool": "rust",
            "version": "1.95.0",
            "released": "2026-04-16",
            "channel": "stable",
            "install_methods": [
                {
                    "name": "rustup-init",
                    "invoke": {
                        "args": ["-y", "--default-toolchain", "1.95.0", "--profile", "default"]
                    }
                }
            ],
            "metadata": {
                "added_at": "2026-04-29T00:00:00Z",
                "schema_version": 1
            }
        })
    }

    #[test]
    fn render_swaps_version_released_metadata_and_invoke_args() {
        let out = render_new_version(
            &template(),
            "1.95.0",
            "1.96.0",
            "2026-05-28",
            "2026-05-31T00:00:00Z",
        );
        assert_eq!(out["version"], "1.96.0");
        assert_eq!(out["released"], "2026-05-28");
        assert_eq!(
            out["install_methods"][0]["invoke"]["args"][2], "1.96.0",
            "the rustup --default-toolchain literal must be rewritten"
        );
        assert_eq!(out["metadata"]["added_at"], "2026-05-31T00:00:00Z");
        assert_eq!(out["metadata"]["updated_at"], "2026-05-31T00:00:00Z");
        assert_eq!(out["metadata"]["schema_version"], 1);
    }

    #[test]
    fn render_preserves_static_fields() {
        let out = render_new_version(
            &template(),
            "1.95.0",
            "1.96.0",
            "2026-05-28",
            "2026-05-31T00:00:00Z",
        );
        assert_eq!(out["schemaVersion"], 1);
        assert_eq!(out["tool"], "rust");
        assert_eq!(out["channel"], "stable");
        assert_eq!(out["install_methods"][0]["name"], "rustup-init");
    }

    #[test]
    fn rewrite_only_replaces_whole_strings() {
        let mut v = json!({
            "exact": "1.95.0",
            "substr": "rust 1.95.0 build",
            "nested": ["1.95.0", "keep"]
        });
        rewrite_string_matches(&mut v, "1.95.0", "1.96.0");
        assert_eq!(v["exact"], "1.96.0");
        assert_eq!(v["substr"], "rust 1.95.0 build", "substrings must not be rewritten");
        assert_eq!(v["nested"][0], "1.96.0");
        assert_eq!(v["nested"][1], "keep");
    }

    #[test]
    fn add_to_index_appends_and_dedups_without_touching_default() {
        let mut index = json!({
            "default_version": "1.95.0",
            "available": [{ "version": "1.84.0" }, { "version": "1.95.0" }]
        });
        add_version_to_index(&mut index, "1.96.0");
        add_version_to_index(&mut index, "1.96.0"); // dedup
        let versions: Vec<&str> = index["available"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["version"].as_str().unwrap())
            .collect();
        assert_eq!(versions, vec!["1.84.0", "1.95.0", "1.96.0"]);
        assert_eq!(index["default_version"], "1.95.0", "default_version must be left alone");
    }

    #[test]
    fn date_part_extracts_calendar_date() {
        assert_eq!(date_part("2026-05-31T12:34:56Z"), "2026-05-31");
        assert_eq!(date_part("2026-05-31"), "2026-05-31");
    }

    #[test]
    fn add_version_writes_file_updates_index_and_is_idempotent() {
        let tmp = tempfile::tempdir().unwrap();
        let versions = tmp.path().join("tools/rust/versions");
        fs::create_dir_all(&versions).unwrap();
        write_json(&versions.join("1.95.0.json"), &template()).unwrap();
        write_json(
            &tmp.path().join("tools/rust/index.json"),
            &json!({ "default_version": "1.95.0", "available": [{ "version": "1.95.0" }] }),
        )
        .unwrap();

        let outcome =
            add_version(tmp.path(), "rust", "1.96.0", Some("2026-05-28"), "2026-05-31T00:00:00Z")
                .unwrap();
        assert!(matches!(outcome, AddOutcome::Added { .. }));

        let written = read_json(&versions.join("1.96.0.json")).unwrap();
        assert_eq!(written["version"], "1.96.0");
        assert_eq!(written["released"], "2026-05-28");
        assert_eq!(written["install_methods"][0]["invoke"]["args"][2], "1.96.0");

        let index = read_json(&tmp.path().join("tools/rust/index.json")).unwrap();
        let listed =
            index["available"].as_array().unwrap().iter().any(|v| v["version"] == "1.96.0");
        assert!(listed, "new version must be listed in available[]");
        assert_eq!(index["default_version"], "1.95.0");

        // Second call is a no-op.
        let again =
            add_version(tmp.path(), "rust", "1.96.0", Some("2026-05-28"), "2026-05-31T00:00:00Z")
                .unwrap();
        assert_eq!(again, AddOutcome::AlreadyPresent);
    }

    #[test]
    fn latest_existing_version_picks_highest_semver() {
        let tmp = tempfile::tempdir().unwrap();
        for v in ["1.84.0", "1.84.1", "1.95.0", "not-a-version"] {
            let name = if v == "not-a-version" {
                "not-a-version.txt".to_owned()
            } else {
                format!("{v}.json")
            };
            fs::write(tmp.path().join(name), "{}").unwrap();
        }
        assert_eq!(latest_existing_version(tmp.path()).unwrap().as_deref(), Some("1.95.0"));
    }
}
