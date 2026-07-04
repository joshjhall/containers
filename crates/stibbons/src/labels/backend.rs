//! Issue-tracker backends for reading and writing labels.
//!
//! A [`LabelBackend`] abstracts the three operations the sync needs — list,
//! create, update — behind a trait so the orchestration in [`super`] is
//! testable with a fake backend and the concrete CLI wiring stays isolated.
//!
//! Two production impls shell out to the tracker CLIs already present in the
//! dev container: [`GithubCli`] (`gh label …`) and [`GitlabCli`]
//! (`glab label …`). A direct REST API backend (via an HTTP client) is a
//! deliberate future option — see the issue's implementation notes — and would
//! slot in as another `impl LabelBackend` without touching callers.

use std::collections::BTreeMap;
use std::process::Command;

use super::metadata::LabelDef;

/// Read/write access to a repository's labels.
pub trait LabelBackend {
    /// Fetch all labels currently on the remote as `name → (color, description)`.
    ///
    /// # Errors
    ///
    /// Returns an error if the underlying CLI cannot be run, is unauthenticated,
    /// or returns output that cannot be parsed.
    fn list(&self) -> Result<BTreeMap<String, (String, String)>, Box<dyn std::error::Error>>;

    /// Create a new label.
    ///
    /// # Errors
    ///
    /// Returns an error if the create call fails.
    fn create(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>>;

    /// Update an existing label's color and description.
    ///
    /// # Errors
    ///
    /// Returns an error if the update call fails.
    fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>>;
}

/// Run a CLI, returning stdout on success or a descriptive error on failure.
///
/// Centralizes the spawn-failure vs non-zero-exit handling both backends need,
/// and turns a missing binary into a clear "is it installed / authenticated"
/// message rather than a raw `NotFound`.
fn run(program: &str, args: &[&str]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let output = Command::new(program).args(args).output().map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            format!("`{program}` not found on PATH — install it or use the other platform")
        } else {
            format!("failed to run `{program}`: {e}")
        }
    })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("`{program} {}` failed: {}", args.join(" "), stderr.trim()).into());
    }
    Ok(output.stdout)
}

/// GitHub backend using the `gh` CLI.
#[derive(Debug, Default)]
pub struct GithubCli;

/// One row of `gh label list --json name,color,description`.
#[derive(serde::Deserialize)]
struct GhLabel {
    name: String,
    #[serde(default)]
    color: String,
    #[serde(default)]
    description: String,
}

impl LabelBackend for GithubCli {
    fn list(&self) -> Result<BTreeMap<String, (String, String)>, Box<dyn std::error::Error>> {
        // --limit is bumped well past the ~30 labels this repo family uses so a
        // large tracker isn't silently truncated (gh defaults to 30).
        let stdout =
            run("gh", &["label", "list", "--limit", "500", "--json", "name,color,description"])?;
        let rows: Vec<GhLabel> = serde_json::from_slice(&stdout)
            .map_err(|e| format!("failed to parse gh label list output: {e}"))?;
        Ok(rows.into_iter().map(|r| (r.name, (r.color, r.description))).collect())
    }

    fn create(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        // --force makes create idempotent at the gh layer too, but we only call
        // it for genuinely-missing labels; kept off so a surprise collision is
        // surfaced rather than silently overwriting.
        run(
            "gh",
            &[
                "label",
                "create",
                &label.name,
                "--color",
                &label.color,
                "--description",
                &label.description,
            ],
        )?;
        Ok(())
    }

    fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        run(
            "gh",
            &[
                "label",
                "edit",
                &label.name,
                "--color",
                &label.color,
                "--description",
                &label.description,
            ],
        )?;
        Ok(())
    }
}

/// GitLab backend using the `glab` CLI.
#[derive(Debug, Default)]
pub struct GitlabCli;

/// One row of `glab label list --output json`.
#[derive(serde::Deserialize)]
struct GlabLabel {
    name: String,
    #[serde(default)]
    color: String,
    #[serde(default)]
    description: String,
}

impl LabelBackend for GitlabCli {
    fn list(&self) -> Result<BTreeMap<String, (String, String)>, Box<dyn std::error::Error>> {
        let stdout = run("glab", &["label", "list", "--output", "json"])?;
        let rows: Vec<GlabLabel> = serde_json::from_slice(&stdout)
            .map_err(|e| format!("failed to parse glab label list output: {e}"))?;
        Ok(rows.into_iter().map(|r| (r.name, (r.color, r.description))).collect())
    }

    fn create(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        run(
            "glab",
            &[
                "label",
                "create",
                "--name",
                &label.name,
                "--color",
                &with_hash(&label.color),
                "--description",
                &label.description,
            ],
        )?;
        Ok(())
    }

    fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        // `glab label create` is NOT an upsert — GitLab rejects a duplicate
        // name — so updates go through `glab label edit`. Its `--label-id`
        // accepts the label's name (GitLab's API identifies a label by title or
        // numeric id), so no separate id lookup is needed.
        run(
            "glab",
            &[
                "label",
                "edit",
                "--label-id",
                &label.name,
                "--color",
                &with_hash(&label.color),
                "--description",
                &label.description,
            ],
        )?;
        Ok(())
    }
}

/// GitLab wants colors with a leading `#`; metadata may omit it.
fn with_hash(color: &str) -> String {
    if color.starts_with('#') { color.to_string() } else { format!("#{color}") }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_hash_adds_missing_prefix() {
        assert_eq!(with_hash("0E8A16"), "#0E8A16");
        assert_eq!(with_hash("#0E8A16"), "#0E8A16");
    }

    #[test]
    fn gh_list_json_parses() {
        let json = br#"[{"name":"type/feature","color":"1D76DB","description":"New feature"}]"#;
        let rows: Vec<GhLabel> = serde_json::from_slice(json).unwrap();
        assert_eq!(rows[0].name, "type/feature");
        assert_eq!(rows[0].color, "1D76DB");
    }

    #[test]
    fn glab_list_json_parses_and_tolerates_missing_description() {
        let json = br##"[{"name":"bug","color":"#FF0000"}]"##;
        let rows: Vec<GlabLabel> = serde_json::from_slice(json).unwrap();
        assert_eq!(rows[0].name, "bug");
        assert_eq!(rows[0].description, "");
    }
}
