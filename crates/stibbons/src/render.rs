//! Shared file-generation orchestration for the `init`, `add`, and `remove`
//! commands.
//!
//! All three commands render the same set of generated files from templates and
//! must agree on the file list, the template mapping, and how user-modified
//! files are detected. This module owns that shared logic so the commands
//! cannot drift:
//!
//! - [`GENERATED_FILES`] is the single source of truth for which files are
//!   generated and from which template.
//! - [`plan_render`] renders every file and classifies it against the recorded
//!   hashes ([`generate::classify_file`]) **without writing anything**, so a
//!   caller can preview changes (`--dry-run`) or gate on `--force`.
//! - [`commit_render`] performs the actual writes for a previously-computed
//!   plan.

use std::collections::BTreeMap;
use std::path::Path;

use containers_common::generate::{self, FileAction, FileEntry};
use containers_common::template::{RenderContext, Renderer};

/// The generated files and the template each is rendered from, in write order.
///
/// `.igor.yml` ([`STATE_FILE`]) is rendered here for hash-tracking parity with
/// the Go predecessor, but it is the project *state file*: the authoritative
/// on-disk copy is written by the caller via `IgorConfig::save` *after* the
/// other files. It is therefore not a user-editable generated file in the
/// drift-detection sense — commands exclude it from the per-file "skip if
/// locally modified" plan and always record its freshly-rendered hash. See the
/// orchestration in `main.rs`.
pub const GENERATED_FILES: &[(&str, &str)] = &[
    (".devcontainer/docker-compose.yml", "docker-compose.yml.tmpl"),
    (".devcontainer/devcontainer.json", "devcontainer.json.tmpl"),
    (".devcontainer/.env", "env.tmpl"),
    (".env.example", "env-example.tmpl"),
    (STATE_FILE, "igor.yml.tmpl"),
];

/// The project state file — a member of [`GENERATED_FILES`] that is always
/// (re)written authoritatively via `IgorConfig::save`, so it is exempt from
/// user-modification drift detection.
pub const STATE_FILE: &str = ".igor.yml";

/// The result of a dry-run-safe render pass over [`GENERATED_FILES`].
pub struct RenderPlan {
    /// `(path, action)` for every generated file, in [`GENERATED_FILES`] order.
    pub actions: Vec<(String, FileAction)>,
    /// The subset of files that should actually be written (per
    /// [`FileAction::should_write`]).
    pub entries_to_write: Vec<FileEntry>,
    /// The freshly-rendered SHA-256 hash of every generated file, keyed by path.
    ///
    /// Note: for a `Skipped` file the caller must retain the *previous* recorded
    /// hash rather than this one, so a user's local edits are not re-detected as
    /// stale on the next run.
    pub new_hashes: BTreeMap<String, String>,
}

/// Renders every [`GENERATED_FILES`] entry and classifies it against
/// `old_hashes`, without writing anything to disk.
///
/// `force` overrides the "preserve user-modified files" behavior: a file that
/// would otherwise be [`FileAction::Skipped`] becomes [`FileAction::Forced`]
/// and is queued for writing.
///
/// # Errors
///
/// Returns an error if template rendering or reading a file for classification
/// fails.
pub fn plan_render(
    ctx: &RenderContext,
    old_hashes: &BTreeMap<String, String>,
    force: bool,
) -> Result<RenderPlan, Box<dyn std::error::Error>> {
    let renderer = Renderer::new()?;

    let mut actions = Vec::with_capacity(GENERATED_FILES.len());
    let mut entries_to_write = Vec::new();
    let mut new_hashes = BTreeMap::new();

    for (path, template) in GENERATED_FILES {
        let content = renderer.render(template, ctx)?;
        // Iterate the relative path exactly as recorded in `old_hashes`; do NOT
        // canonicalize, or the hash lookup misses and every file is classified
        // `Skipped`.
        let action = generate::classify_file(Path::new(path), &content, old_hashes, force)?;

        new_hashes.insert((*path).to_string(), generate::hash_content(&content));

        if action.should_write() {
            entries_to_write.push(FileEntry { path: Path::new(path).to_path_buf(), content });
        }
        actions.push(((*path).to_string(), action));
    }

    Ok(RenderPlan { actions, entries_to_write, new_hashes })
}

/// Writes the files queued in `plan`, returning a `path → SHA-256 hash` map for
/// the files actually written.
///
/// # Errors
///
/// Returns the first I/O error encountered while writing.
pub fn commit_render(plan: &RenderPlan) -> std::io::Result<BTreeMap<String, String>> {
    generate::write_files(&plan.entries_to_write)
}

#[cfg(test)]
mod tests {
    use super::*;
    use containers_common::config::{AgentConfig, ProjectConfig};
    use containers_common::feature::{self, Registry};
    use std::sync::Mutex;

    /// Serializes tests that mutate the process-global current directory, since
    /// `plan_render` classifies files by relative path against the CWD and
    /// cargo runs tests in a binary concurrently.
    static CWD_LOCK: Mutex<()> = Mutex::new(());

    /// Restores the process CWD to its captured value when dropped.
    struct RestoreCwd(std::path::PathBuf);
    impl Drop for RestoreCwd {
        fn drop(&mut self) {
            let _ = std::env::set_current_dir(&self.0);
        }
    }

    /// Runs `f` with the process CWD set to `dir`, restoring the previous CWD
    /// (and releasing the lock) even if `f` panics.
    fn with_cwd<T>(dir: &Path, f: impl FnOnce() -> T) -> T {
        let _guard = CWD_LOCK.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let _restore = RestoreCwd(std::env::current_dir().unwrap());
        std::env::set_current_dir(dir).unwrap();
        f()
    }

    /// Build a minimal render context (python selected) for exercising
    /// `plan_render` against a temp dir.
    fn ctx_with_python(reg: &Registry) -> RenderContext {
        let mut explicit = std::collections::HashSet::new();
        explicit.insert("python".to_string());
        let selection = feature::resolve(&explicit, reg);
        RenderContext::new(
            ProjectConfig::default(),
            "containers",
            &selection,
            reg,
            BTreeMap::new(),
            AgentConfig::default(),
        )
    }

    #[test]
    fn plan_render_marks_missing_files_created() {
        let reg = Registry::new();
        let ctx = ctx_with_python(&reg);
        let tmp = tempfile::tempdir().unwrap();

        let plan = with_cwd(tmp.path(), || plan_render(&ctx, &BTreeMap::new(), false).unwrap());

        // Nothing on disk yet → every file is Created and queued for writing.
        assert_eq!(plan.actions.len(), GENERATED_FILES.len());
        assert!(plan.actions.iter().all(|(_, a)| matches!(a, FileAction::Created)));
        assert_eq!(plan.entries_to_write.len(), GENERATED_FILES.len());
        assert_eq!(plan.new_hashes.len(), GENERATED_FILES.len());
    }

    #[test]
    fn plan_render_skips_user_modified_without_force() {
        let reg = Registry::new();
        let ctx = ctx_with_python(&reg);
        let tmp = tempfile::tempdir().unwrap();

        let (plan, forced) = with_cwd(tmp.path(), || {
            // Seed the compose file with content the recorded hash won't match,
            // simulating a user edit whose provenance hash is stale.
            std::fs::create_dir_all(".devcontainer").unwrap();
            std::fs::write(".devcontainer/docker-compose.yml", "user edited\n").unwrap();
            let mut old = BTreeMap::new();
            old.insert(".devcontainer/docker-compose.yml".to_string(), "deadbeef".to_string());

            let plan = plan_render(&ctx, &old, false).unwrap();
            let forced = plan_render(&ctx, &old, true).unwrap();
            (plan, forced)
        });

        let compose_action = |p: &RenderPlan| {
            p.actions
                .iter()
                .find(|(path, _)| path == ".devcontainer/docker-compose.yml")
                .map(|(_, a)| *a)
                .unwrap()
        };

        assert!(matches!(compose_action(&plan), FileAction::Skipped));
        assert!(matches!(compose_action(&forced), FileAction::Forced));
        // Without force the skipped file is not queued; with force it is.
        assert!(!plan.entries_to_write.iter().any(|e| e.path.ends_with("docker-compose.yml")));
        assert!(forced.entries_to_write.iter().any(|e| e.path.ends_with("docker-compose.yml")));
    }
}
