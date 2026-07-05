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

use super::exec::{self, DEFAULT_CLI_TIMEOUT, ExecError};
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
/// message rather than a raw `NotFound`. The call is bounded by
/// [`DEFAULT_CLI_TIMEOUT`] so a wedged interactive re-auth or a stalled network
/// call fails the run instead of hanging forever (see [`super::exec`]).
fn run(program: &str, args: &[&str]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let mut cmd = Command::new(program);
    cmd.args(args);
    let output = exec::run_with_timeout(cmd, DEFAULT_CLI_TIMEOUT).map_err(|e| match e {
        ExecError::Spawn(io) if io.kind() == std::io::ErrorKind::NotFound => {
            format!("`{program}` not found on PATH — install it or use the other platform")
        }
        ExecError::Spawn(io) => format!("failed to run `{program}`: {io}"),
        ExecError::Timeout(d) => format!(
            "`{program} {}` timed out after {}s — is it waiting on an interactive prompt or a \
             stalled network call?",
            args.join(" "),
            d.as_secs()
        ),
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
        label.validate()?;
        run_owned("gh", &github_args("create", label))?;
        Ok(())
    }

    fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        label.validate()?;
        run_owned("gh", &github_args("edit", label))?;
        Ok(())
    }
}

/// Build the `gh label {create|edit}` argv for a label.
///
/// Uses `=`-form flags for the color/description and a `--` terminator before
/// the positional name, so even if validation is bypassed a value beginning
/// with `-` can never be parsed by `gh` as an option (issue #694).
fn github_args(verb: &str, label: &LabelDef) -> Vec<String> {
    vec![
        "label".into(),
        verb.into(),
        format!("--color={}", label.color),
        format!("--description={}", label.description),
        "--".into(),
        label.name.clone(),
    ]
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
        label.validate()?;
        run_owned("glab", &gitlab_create_args(label))?;
        Ok(())
    }

    fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
        // `glab label create` is NOT an upsert — GitLab rejects a duplicate
        // name — so updates go through `glab label edit`. Its `--label-id`
        // accepts the label's name (GitLab's API identifies a label by title or
        // numeric id), so no separate id lookup is needed.
        label.validate()?;
        run_owned("glab", &gitlab_update_args(label))?;
        Ok(())
    }
}

/// Build the `glab label create` argv. `=`-form flags keep a leading-dash value
/// from being parsed as an option (issue #694); colors get a leading `#`.
fn gitlab_create_args(label: &LabelDef) -> Vec<String> {
    vec![
        "label".into(),
        "create".into(),
        format!("--name={}", label.name),
        format!("--color={}", with_hash(&label.color)),
        format!("--description={}", label.description),
    ]
}

/// Build the `glab label edit` argv, identifying the label by name via
/// `--label-id` (GitLab accepts a title or numeric id there).
fn gitlab_update_args(label: &LabelDef) -> Vec<String> {
    vec![
        "label".into(),
        "edit".into(),
        format!("--label-id={}", label.name),
        format!("--color={}", with_hash(&label.color)),
        format!("--description={}", label.description),
    ]
}

/// [`run`] for owned `String` args (the arg builders return `Vec<String>`).
fn run_owned(program: &str, args: &[String]) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let borrowed: Vec<&str> = args.iter().map(String::as_str).collect();
    run(program, &borrowed)
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

    fn label(name: &str, color: &str, desc: &str) -> LabelDef {
        LabelDef { name: name.into(), color: color.into(), description: desc.into() }
    }

    #[test]
    fn github_create_args_use_eq_flags_and_terminator() {
        let l = label("status/in-progress", "0E8A16", "An agent is working");
        assert_eq!(
            github_args("create", &l),
            vec![
                "label",
                "create",
                "--color=0E8A16",
                "--description=An agent is working",
                "--",
                "status/in-progress",
            ]
        );
    }

    #[test]
    fn github_edit_args_use_edit_verb() {
        let l = label("type/bug", "D73A4A", "Bug");
        let args = github_args("edit", &l);
        assert_eq!(args[0], "label");
        assert_eq!(args[1], "edit");
        // The `--` terminator precedes the positional name.
        assert_eq!(args[args.len() - 2], "--");
        assert_eq!(args[args.len() - 1], "type/bug");
    }

    #[test]
    fn gitlab_create_args_prefix_color_hash_and_use_name_flag() {
        let l = label("type/bug", "D73A4A", "Bug");
        assert_eq!(
            gitlab_create_args(&l),
            vec!["label", "create", "--name=type/bug", "--color=#D73A4A", "--description=Bug"]
        );
    }

    #[test]
    fn gitlab_update_args_use_label_id_by_name() {
        let l = label("type/bug", "#D73A4A", "Bug");
        // Identifies the label by name via --label-id; color already has `#`.
        assert_eq!(
            gitlab_update_args(&l),
            vec!["label", "edit", "--label-id=type/bug", "--color=#D73A4A", "--description=Bug"]
        );
    }

    #[test]
    fn eq_form_keeps_leading_dash_value_as_single_arg() {
        // Even a (hypothetical, validation-bypassing) leading-dash description
        // stays one `--description=…` token — never a separate flag.
        let l = label("n", "0E8A16", "--repo=evil");
        let args = github_args("create", &l);
        assert!(args.iter().any(|a| a == "--description=--repo=evil"));
        assert!(!args.iter().any(|a| a == "--repo=evil"));
    }
}
