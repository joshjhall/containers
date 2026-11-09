//! Plumbing shared by more than one command body.
//!
//! These helpers were factored out of `main.rs` when the command bodies moved
//! into this module tree (issue #846). Each is used by at least two of
//! [`super::init`], [`super::add_remove`], and [`super::update`]; anything used
//! by exactly one command lives with that command instead.

use std::collections::HashSet;
use std::io::Write;
use std::path::Path;

use containers_common::config::IgorConfig;
use containers_common::feature::Selection;
use containers_common::generate::FileAction;

use crate::render;

/// Loads the project's `.igor.yml`, erroring if the project has not been
/// initialized yet.
pub fn load_project_config() -> Result<IgorConfig, Box<dyn std::error::Error>> {
    if !Path::new(".igor.yml").exists() {
        return Err("no .igor.yml found; run `stibbons init` first".into());
    }
    IgorConfig::load(".igor.yml")
}

/// Returns the sorted set of feature IDs newly present in `selection` relative
/// to the `previous` explicit set (both explicit additions and features pulled
/// in by dependency resolution).
pub fn diff_added(previous: &HashSet<String>, selection: &Selection) -> Vec<String> {
    let mut added: Vec<String> = selection.all().difference(previous).cloned().collect();
    added.sort();
    added
}

/// Joins a list for display, or `(none)` when empty.
pub fn join_or_none(items: &[String]) -> String {
    if items.is_empty() { "(none)".to_string() } else { items.join(", ") }
}

/// Prints the per-file action table for a render plan to stdout.
///
/// See [`write_render_plan`] for the format.
///
/// # Panics
///
/// Panics if writing to stdout fails, matching `println!`.
pub fn print_render_plan(plan: &render::RenderPlan) {
    write_render_plan(&mut std::io::stdout().lock(), plan)
        .expect("failed to write render plan to stdout");
}

/// Writes the per-file action table for a render plan to `out`.
///
/// The state file (`.igor.yml`) is omitted: it is always rewritten via
/// `IgorConfig::save`, so classifying it against the templated hash would show
/// a misleading `skip`/`update` line.
fn write_render_plan(out: &mut impl Write, plan: &render::RenderPlan) -> std::io::Result<()> {
    writeln!(out, "\nPlanned changes:")?;
    for (path, action) in &plan.actions {
        if path == render::STATE_FILE {
            continue;
        }
        match action {
            FileAction::Created => writeln!(out, "  create    {path}")?,
            FileAction::Updated => writeln!(out, "  update    {path}")?,
            FileAction::Unchanged => writeln!(out, "  unchanged {path}")?,
            FileAction::Forced => writeln!(out, "  overwrite {path} (forced)")?,
            FileAction::Skipped => {
                writeln!(out, "  skip      {path} (modified locally; use --force to overwrite)")?;
            }
        }
    }
    Ok(())
}

/// Detects the containers submodule directory.
pub fn detect_containers_dir() -> String {
    for candidate in ["containers", "docker/containers", ".containers"] {
        let dockerfile = Path::new(candidate).join("Dockerfile");
        if dockerfile.is_file() {
            return candidate.to_string();
        }
    }
    "containers".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::with_cwd;
    use containers_common::feature::{self, Registry};

    fn set_of(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn diff_added_reports_everything_from_an_empty_previous() {
        let reg = Registry::new();
        let selection = feature::resolve(&set_of(&["python"]), &reg);

        let added = diff_added(&HashSet::new(), &selection);

        assert!(added.contains(&"python".to_string()), "explicit pick should be reported");
        assert_eq!(added.len(), selection.all().len(), "everything is new against an empty set");
    }

    #[test]
    fn diff_added_is_empty_when_nothing_is_new() {
        let reg = Registry::new();
        let selection = feature::resolve(&set_of(&["python"]), &reg);

        // Compare against the fully-resolved set: nothing has been added.
        let added = diff_added(&selection.all(), &selection);

        assert!(added.is_empty(), "expected no additions, got {added:?}");
    }

    /// `diff_added` reports features pulled in by dependency resolution, not
    /// just the ones named explicitly — that is what makes the `add` header
    /// report the true net change.
    #[test]
    fn diff_added_includes_dependency_only_additions() {
        let reg = Registry::new();
        let explicit = set_of(&["python_dev"]);
        let selection = feature::resolve(&explicit, &reg);

        let added = diff_added(&explicit, &selection);

        let auto: Vec<&String> = selection.auto_resolved.iter().collect();
        assert!(!auto.is_empty(), "python_dev should resolve at least one dependency");
        for id in auto {
            assert!(added.contains(id), "auto-resolved {id:?} should be reported as added");
        }
    }

    #[test]
    fn diff_added_is_sorted() {
        let reg = Registry::new();
        let selection = feature::resolve(&set_of(&["python_dev", "node", "rust"]), &reg);

        let added = diff_added(&HashSet::new(), &selection);

        let mut sorted = added.clone();
        sorted.sort();
        assert_eq!(added, sorted, "diff_added should return sorted IDs");
    }

    #[test]
    fn join_or_none_renders_empty_as_none() {
        assert_eq!(join_or_none(&[]), "(none)");
    }

    #[test]
    fn join_or_none_joins_with_comma_space() {
        assert_eq!(join_or_none(&["a".to_string()]), "a");
        assert_eq!(join_or_none(&["a".to_string(), "b".to_string()]), "a, b");
    }

    /// The wording of the uninitialized-project error is the user-facing
    /// contract: it is what tells a first-time user which command to run.
    #[test]
    fn load_project_config_errors_when_no_igor_yml_present() {
        let tmp = tempfile::tempdir().unwrap();

        let err = with_cwd(tmp.path(), load_project_config).unwrap_err();

        assert_eq!(err.to_string(), "no .igor.yml found; run `stibbons init` first");
    }

    #[test]
    fn load_project_config_parses_a_present_igor_yml() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join(".igor.yml"), "project:\n  name: demo\n").unwrap();

        let cfg = with_cwd(tmp.path(), load_project_config).unwrap();

        assert_eq!(cfg.project.name, "demo", "the file should be parsed, not merely detected");
    }

    /// A malformed file must surface `IgorConfig::load`'s parse error rather
    /// than being reported as an uninitialized project.
    #[test]
    fn load_project_config_surfaces_parse_errors() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join(".igor.yml"), "project: [unclosed\n").unwrap();

        let err = with_cwd(tmp.path(), load_project_config).unwrap_err();

        // Pin the message to the one `IgorConfig::load` produces for the same
        // bytes. A bare "not the missing-file message" check would also pass if
        // the parse error were swapped for some other generic failure.
        let direct = IgorConfig::load(tmp.path().join(".igor.yml")).unwrap_err();
        assert_eq!(
            err.to_string(),
            direct.to_string(),
            "the parse error should be propagated verbatim from IgorConfig::load"
        );
        assert_ne!(
            err.to_string(),
            "no .igor.yml found; run `stibbons init` first",
            "a present-but-invalid file is a parse failure, not a missing file"
        );
    }

    /// Creates `<root>/<dir>/Dockerfile`.
    fn seed_dockerfile(root: &Path, dir: &str) {
        let target = root.join(dir);
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("Dockerfile"), "FROM scratch\n").unwrap();
    }

    #[test]
    fn detects_each_candidate_directory() {
        for candidate in ["containers", "docker/containers", ".containers"] {
            let tmp = tempfile::tempdir().unwrap();
            seed_dockerfile(tmp.path(), candidate);

            let found = with_cwd(tmp.path(), detect_containers_dir);

            assert_eq!(found, candidate, "should detect {candidate:?} by its Dockerfile");
        }
    }

    #[test]
    fn falls_back_to_containers_when_no_dockerfile_found() {
        let tmp = tempfile::tempdir().unwrap();

        let found = with_cwd(tmp.path(), detect_containers_dir);

        assert_eq!(found, "containers", "the fallback is the conventional default");
    }

    /// The candidate list is ordered: `containers` wins over later matches.
    #[test]
    fn earlier_candidate_wins() {
        let tmp = tempfile::tempdir().unwrap();
        seed_dockerfile(tmp.path(), "containers");
        seed_dockerfile(tmp.path(), ".containers");

        let found = with_cwd(tmp.path(), detect_containers_dir);

        assert_eq!(found, "containers");
    }

    /// A *directory* named `Dockerfile` is not a Dockerfile — `is_file()` is
    /// what makes the probe correct here.
    #[test]
    fn directory_named_dockerfile_does_not_match() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(tmp.path().join("docker/containers/Dockerfile")).unwrap();

        let found = with_cwd(tmp.path(), detect_containers_dir);

        assert_eq!(found, "containers", "a directory should not satisfy the probe");
    }

    fn plan_of(actions: &[(&str, FileAction)]) -> render::RenderPlan {
        render::RenderPlan {
            actions: actions.iter().map(|(p, a)| ((*p).to_string(), *a)).collect(),
            entries_to_write: Vec::new(),
            new_hashes: std::collections::BTreeMap::new(),
        }
    }

    fn render_to_string(plan: &render::RenderPlan) -> String {
        let mut buf = Vec::new();
        write_render_plan(&mut buf, plan).unwrap();
        String::from_utf8(buf).unwrap()
    }

    #[test]
    fn write_render_plan_empty_plan_prints_only_header() {
        assert_eq!(render_to_string(&plan_of(&[])), "\nPlanned changes:\n");
    }

    /// Each variant maps to its own exact line. Whole-output equality (not
    /// `contains`) so a swapped prefix between two variants fails.
    #[test]
    fn write_render_plan_renders_each_file_action() {
        let plan = plan_of(&[
            ("a", FileAction::Created),
            ("b", FileAction::Updated),
            ("c", FileAction::Unchanged),
            ("d", FileAction::Forced),
            ("e", FileAction::Skipped),
        ]);

        assert_eq!(
            render_to_string(&plan),
            "\nPlanned changes:\n\
             \x20 create    a\n\
             \x20 update    b\n\
             \x20 unchanged c\n\
             \x20 overwrite d (forced)\n\
             \x20 skip      e (modified locally; use --force to overwrite)\n"
        );
    }

    /// `.igor.yml` is always rewritten via `IgorConfig::save`, so it must never
    /// appear in the plan — whatever its classification — while its neighbours
    /// still print in order.
    #[test]
    fn write_render_plan_omits_state_file() {
        for action in [
            FileAction::Created,
            FileAction::Updated,
            FileAction::Unchanged,
            FileAction::Forced,
            FileAction::Skipped,
        ] {
            let plan = plan_of(&[
                ("before", FileAction::Created),
                (render::STATE_FILE, action),
                ("after", FileAction::Unchanged),
            ]);

            assert_eq!(
                render_to_string(&plan),
                "\nPlanned changes:\n  create    before\n  unchanged after\n",
                "state file classified {action:?} leaked into the plan"
            );
        }
    }

    /// Accepts `budget` bytes, then fails every write.
    struct FailAfter {
        budget: usize,
    }

    impl Write for FailAfter {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            if self.budget == 0 {
                return Err(std::io::Error::other("sink closed"));
            }
            let n = buf.len().min(self.budget);
            self.budget -= n;
            Ok(n)
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    /// A write failure must propagate, not be swallowed. Fail both on the
    /// header and on a per-file row (budget exactly covers the header), so the
    /// `?` on either `writeln!` is pinned.
    #[test]
    fn write_render_plan_propagates_write_errors() {
        let plan = plan_of(&[("a", FileAction::Created)]);
        let header_len = "\nPlanned changes:\n".len();

        for budget in [0, header_len] {
            let err = write_render_plan(&mut FailAfter { budget }, &plan)
                .expect_err(&format!("budget {budget}: write error was swallowed"));
            assert_eq!(err.to_string(), "sink closed", "budget {budget}");
        }
    }
}
