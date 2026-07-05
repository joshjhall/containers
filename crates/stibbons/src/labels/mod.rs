//! `stibbons labels sync` — reconcile skill-defined labels onto the repo's
//! issue tracker.
//!
//! Pipeline: detect platform (or honor `--platform`) → aggregate label
//! definitions from skill `metadata.yml` files → fetch the tracker's current
//! labels → diff → print a plan → apply (create/update, never delete) unless
//! `--dry-run`.
//!
//! The layers are deliberately split for testability: [`metadata`] (parse),
//! [`platform`] (detect), [`plan`] (diff) are pure; [`backend`] wraps the
//! `gh`/`glab` CLIs behind a trait. This module wires them together.

mod backend;
mod exec;
mod metadata;
mod plan;
mod platform;

use std::path::PathBuf;

use backend::{GithubCli, GitlabCli, LabelBackend};
use plan::{LabelChange, count};

pub use platform::Platform;

/// Options for a `labels sync` (also used by `setup`).
#[derive(Debug, Default)]
pub struct SyncOptions {
    /// Preview changes without applying them.
    pub dry_run: bool,
    /// Force a specific platform instead of auto-detecting.
    pub platform: Option<Platform>,
    /// Skill roots to scan; empty means "use the defaults".
    pub skills_dirs: Vec<PathBuf>,
}

/// Parse a `--platform` flag string into a [`Platform`], erroring clearly on a
/// bad value.
///
/// # Errors
///
/// Returns an error when `s` is neither `github` nor `gitlab`.
pub fn parse_platform_flag(s: &str) -> Result<Platform, Box<dyn std::error::Error>> {
    Platform::from_flag(s)
        .ok_or_else(|| format!("unknown platform `{s}` (expected `github` or `gitlab`)").into())
}

/// Default skill roots, in priority order (first-encountered wins on conflict):
///
/// 1. In-repo template skills, if present (`lib/features/templates/claude/skills`).
/// 2. Librarian plugins, if present (`/opt/librarian/plugins`).
///
/// Only roots that actually exist are returned, so a host without librarian
/// installed simply scans fewer places.
fn default_skill_roots() -> Vec<PathBuf> {
    let candidates = [
        PathBuf::from("lib/features/templates/claude/skills"),
        PathBuf::from("/opt/librarian/plugins"),
    ];
    candidates.into_iter().filter(|p| p.exists()).collect()
}

/// Resolve the skill roots to scan: the caller's `--skills-dir` values when any
/// were given, otherwise `defaults`. Errors when the result is empty (nothing
/// to read labels from).
///
/// Split out (with `defaults` injected rather than calling
/// [`default_skill_roots`] directly) so the empty-roots error branch is
/// unit-testable without depending on whether the host has
/// `/opt/librarian/plugins` installed.
///
/// # Errors
///
/// Returns an error when both `skills_dirs` and `defaults` are empty.
fn resolve_skill_roots(
    skills_dirs: &[PathBuf],
    defaults: Vec<PathBuf>,
) -> Result<Vec<PathBuf>, Box<dyn std::error::Error>> {
    let roots = if skills_dirs.is_empty() { defaults } else { skills_dirs.to_vec() };
    if roots.is_empty() {
        return Err("no skill directories found to read labels from; \
                    pass --skills-dir <DIR>"
            .into());
    }
    Ok(roots)
}

/// Run the label sync.
///
/// # Errors
///
/// Returns an error on: undetectable platform, no readable skill roots, a
/// malformed `metadata.yml`, or any backend (list/create/update) failure.
pub fn run_sync(opts: &SyncOptions) -> Result<(), Box<dyn std::error::Error>> {
    // 1. Resolve the platform.
    let platform = if let Some(p) = opts.platform {
        p
    } else {
        let url = platform::origin_remote_url()?;
        platform::classify_remote(&url).ok_or_else(|| {
            format!(
                "could not determine platform from remote `{url}`; \
                 pass --platform github|gitlab"
            )
        })?
    };

    // 2. Resolve skill roots and aggregate labels.
    let roots = resolve_skill_roots(&opts.skills_dirs, default_skill_roots())?;
    let agg = metadata::load_labels(&roots)?;
    for warning in &agg.warnings {
        eprintln!("warning: {warning}");
    }
    if agg.labels.is_empty() {
        println!("No label definitions found in {} skill dir(s). Nothing to sync.", roots.len());
        return Ok(());
    }

    // 3. Pick a backend and reconcile through the backend-agnostic core.
    let backend: Box<dyn LabelBackend> = match platform {
        Platform::GitHub => Box::new(GithubCli),
        Platform::GitLab => Box::new(GitlabCli),
    };
    reconcile(backend.as_ref(), &agg.labels, platform, agg.source_files, opts.dry_run)
}

/// Backend-agnostic reconcile: fetch remote labels, diff against `desired`,
/// print the plan, and (unless `dry_run`) apply creates/updates. Split out so a
/// fake [`LabelBackend`] can drive the full list → diff → apply pipeline in a
/// unit test without a live `gh`/`glab`.
///
/// # Errors
///
/// Returns an error if the backend's `list`, `create`, or `update` fails. The
/// apply loop stops at the first failed label (so a persistent auth error is
/// surfaced immediately rather than repeated for every label).
fn reconcile(
    backend: &dyn LabelBackend,
    desired: &[metadata::LabelDef],
    platform: Platform,
    source_files: usize,
    dry_run: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let remote = backend.list()?;

    let changes = plan::compute_plan(desired, &remote);
    print_header(platform, source_files, desired.len());
    for change in &changes {
        print_change(change);
    }
    let counts = count(&changes);

    if dry_run {
        println!(
            "\nDry run complete. {} to create, {} to update, {} unchanged.",
            counts.create, counts.update, counts.ok
        );
        println!("Run without --dry-run to apply changes.");
        return Ok(());
    }

    for change in &changes {
        match change {
            LabelChange::Create(label) => backend.create(label)?,
            LabelChange::Update { desired, .. } => backend.update(desired)?,
            LabelChange::Ok(_) => {}
        }
    }
    println!(
        "\nApplied. {} created, {} updated, {} unchanged.",
        counts.create, counts.update, counts.ok
    );
    Ok(())
}

/// Print the `Platform:` / `Source:` header block.
fn print_header(platform: Platform, source_files: usize, label_count: usize) {
    println!("Platform: {platform}");
    println!("Source: {source_files} skill metadata file(s), {label_count} labels total\n");
}

/// Print one plan row in the issue's `CREATE/UPDATE/OK` table style.
fn print_change(change: &LabelChange) {
    match change {
        LabelChange::Create(l) => {
            println!("  CREATE  {:<24} (#{}) \"{}\"", l.name, l.color, l.description);
        }
        LabelChange::Update { desired, color_changed, desc_changed } => {
            let mut what = Vec::new();
            if *color_changed {
                what.push("color");
            }
            if *desc_changed {
                what.push("description");
            }
            println!("  UPDATE  {:<24} ({} changed)", desired.name, what.join(" + "));
        }
        LabelChange::Ok(l) => {
            println!("  OK      {:<24} (no changes)", l.name);
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::collections::BTreeMap;

    use super::metadata::LabelDef;
    use super::*;

    #[test]
    fn parse_platform_flag_accepts_known() {
        assert_eq!(parse_platform_flag("github").unwrap(), Platform::GitHub);
        assert_eq!(parse_platform_flag("gitlab").unwrap(), Platform::GitLab);
    }

    #[test]
    fn parse_platform_flag_rejects_unknown() {
        let err = parse_platform_flag("bitbucket").unwrap_err();
        assert!(err.to_string().contains("unknown platform"));
    }

    #[test]
    fn resolve_skill_roots_prefers_explicit_dirs() {
        let explicit = vec![PathBuf::from("/tmp/a"), PathBuf::from("/tmp/b")];
        // Explicit dirs are used verbatim and defaults are ignored.
        let roots = resolve_skill_roots(&explicit, vec![PathBuf::from("/default")]).unwrap();
        assert_eq!(roots, explicit);
    }

    #[test]
    fn resolve_skill_roots_falls_back_to_defaults() {
        let defaults = vec![PathBuf::from("/opt/librarian/plugins")];
        let roots = resolve_skill_roots(&[], defaults.clone()).unwrap();
        assert_eq!(roots, defaults);
    }

    #[test]
    fn resolve_skill_roots_empty_is_error() {
        // No explicit dirs and no defaults (e.g. a host without librarian) is
        // the "no skill directories found" branch.
        let err = resolve_skill_roots(&[], vec![]).unwrap_err();
        assert!(err.to_string().contains("no skill directories found"), "got: {err}");
    }

    #[test]
    fn default_skill_roots_returns_only_existing_paths() {
        // Whatever it returns, every entry must actually exist on disk.
        for root in default_skill_roots() {
            assert!(root.exists(), "default_skill_roots returned a nonexistent path: {root:?}");
        }
    }

    fn label(name: &str, color: &str, desc: &str) -> LabelDef {
        LabelDef { name: name.into(), color: color.into(), description: desc.into() }
    }

    /// In-memory backend that records create/update calls and can be told to
    /// fail on a particular label name.
    struct FakeBackend {
        remote: BTreeMap<String, (String, String)>,
        created: RefCell<Vec<String>>,
        updated: RefCell<Vec<String>>,
        fail_on: Option<String>,
    }

    impl FakeBackend {
        fn new(remote: BTreeMap<String, (String, String)>) -> Self {
            Self {
                remote,
                created: RefCell::new(Vec::new()),
                updated: RefCell::new(Vec::new()),
                fail_on: None,
            }
        }
    }

    impl LabelBackend for FakeBackend {
        fn list(&self) -> Result<BTreeMap<String, (String, String)>, Box<dyn std::error::Error>> {
            Ok(self.remote.clone())
        }

        fn create(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
            if self.fail_on.as_deref() == Some(label.name.as_str()) {
                return Err(format!("boom creating {}", label.name).into());
            }
            self.created.borrow_mut().push(label.name.clone());
            Ok(())
        }

        fn update(&self, label: &LabelDef) -> Result<(), Box<dyn std::error::Error>> {
            if self.fail_on.as_deref() == Some(label.name.as_str()) {
                return Err(format!("boom updating {}", label.name).into());
            }
            self.updated.borrow_mut().push(label.name.clone());
            Ok(())
        }
    }

    #[test]
    fn reconcile_applies_creates_and_updates_skipping_ok() {
        // Remote: one matching label (ok), one drifted (update). Desired also
        // introduces a brand-new label (create).
        let mut remote = BTreeMap::new();
        remote.insert("type/feature".to_string(), ("1D76DB".into(), "New feature".into()));
        remote.insert("severity/high".to_string(), ("000000".into(), "High".into()));
        let backend = FakeBackend::new(remote);

        let desired = vec![
            label("severity/high", "D93F0B", "High"), // drift -> update
            label("status/on-hold", "D4C5F9", "Deferred"), // missing -> create
            label("type/feature", "1D76DB", "New feature"), // match -> ok
        ];

        reconcile(&backend, &desired, Platform::GitHub, 1, false).unwrap();

        assert_eq!(*backend.created.borrow(), vec!["status/on-hold"]);
        assert_eq!(*backend.updated.borrow(), vec!["severity/high"]);
    }

    #[test]
    fn reconcile_dry_run_applies_nothing() {
        let backend = FakeBackend::new(BTreeMap::new());
        let desired = vec![label("status/on-hold", "D4C5F9", "Deferred")];
        reconcile(&backend, &desired, Platform::GitHub, 1, true).unwrap();
        assert!(backend.created.borrow().is_empty());
        assert!(backend.updated.borrow().is_empty());
    }

    #[test]
    fn reconcile_stops_at_first_failing_label() {
        let mut backend = FakeBackend::new(BTreeMap::new());
        backend.fail_on = Some("effort/small".to_string()); // second of three
        // All three are creates (empty remote); sorted order is effort/small,
        // status/on-hold, type/bug — so the failure is on the first attempted.
        // Use names that make the fail land in the middle: creates run in the
        // `desired` order given here.
        let desired = vec![
            label("aaa/first", "111111", "first"),
            label("effort/small", "0E8A16", "Small"),
            label("zzz/last", "222222", "last"),
        ];
        let err = reconcile(&backend, &desired, Platform::GitHub, 1, false).unwrap_err();
        assert!(err.to_string().contains("boom creating effort/small"));
        // The first label was applied; the one after the failure never was.
        assert_eq!(*backend.created.borrow(), vec!["aaa/first"]);
    }
}
