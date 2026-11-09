//! Writing `init`'s targets and reporting what happened to each.
//!
//! Split out of `standards/mod.rs` (#1578), like `accept.rs` (#1572).

use std::collections::BTreeSet;
use std::error::Error;
use std::io::Write;
use std::path::{Path, PathBuf};

use containers_common::generate::hash_bytes;

use super::fsutil::set_executable;
use super::manifest::RenderedFile;
use super::state::{STATE_FILE, StandardsState};
use super::{InitAction, touches};

/// Render `e` and its [`source`](Error::source) chain as `e: cause: cause…`.
///
/// The standards errors are *chained*: each `Display` describes only its own
/// layer and leaves the cause to `source()`, so a reporter that walks the
/// chain prints every message exactly once. A cause the rendered message
/// already ends with is skipped, which keeps errors that both inline and chain
/// their cause (common in libraries) from printing it twice. Only a trailing
/// match counts: the same text elsewhere can be a different failure (a write
/// and a state save both denied, say), whose cause must still be shown.
#[must_use]
pub fn error_chain(e: &dyn Error) -> String {
    let mut msg = e.to_string();
    let mut cur = e.source();
    while let Some(cause) = cur {
        let text = cause.to_string();
        if !msg.ends_with(&text) {
            msg.push_str(": ");
            msg.push_str(&text);
        }
        cur = cause.source();
    }
    msg
}

/// A write, directory-create, or chmod failure partway through [`init`].
///
/// Chained, not inline (#1578): `Display` names the operation and path only,
/// and the [`std::io::Error`] is reachable solely through
/// [`source`](Error::source), so a caller can tell a permission error from a
/// full disk and a chain-walking reporter ([`error_chain`]) prints it once.
/// `Display` also says whether the state file recording the targets written
/// so far was saved; a failed save is rendered inline, in parentheses with its
/// own chain, since only one error can be the `source()` — the parentheses
/// keep the write's cause, appended after them, attached to the write.
///
/// [`init`]: super::init
#[derive(Debug)]
pub struct InitWriteError {
    /// What failed: `"create"` (a parent directory), `"write"`, or `"chmod"`.
    op: &'static str,
    path: PathBuf,
    source: std::io::Error,
    /// Why saving [`STATE_FILE`] afterwards failed too, if it did.
    pub(super) save: Option<Box<dyn Error>>,
}

impl InitWriteError {
    fn new(op: &'static str, path: &Path, source: std::io::Error) -> Self {
        Self { op, path: path.to_path_buf(), source, save: None }
    }
}

impl std::fmt::Display for InitWriteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "failed to {} {}", self.op, self.path.display())?;
        match &self.save {
            None => write!(f, " (recorded the files written so far in {STATE_FILE})"),
            Some(save) => {
                write!(f, " (and saving {STATE_FILE} failed too: {})", error_chain(&**save))
            }
        }
    }
}

impl Error for InitWriteError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&self.source)
    }
}

/// Every target was written, but saving [`STATE_FILE`] failed, so none of
/// them is recorded. The save error is the [`source`](Error::source).
#[derive(Debug)]
pub struct StateSaveAfterWrite(pub(super) Box<dyn Error>);

impl std::fmt::Display for StateSaveAfterWrite {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "wrote every baseline file but could not record them in {STATE_FILE}; a re-run \
             will report them as local edits until it is saved"
        )
    }
}

impl Error for StateSaveAfterWrite {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        Some(&*self.0)
    }
}

/// Write (and chmod) every target `init` touches, recording each write in
/// `new` as soon as its bytes are on disk. On failure, returns the index of
/// the target that failed alongside the error.
pub(super) fn write_targets(
    root: &Path,
    rendered: &[RenderedFile],
    actions: &[InitAction],
    new: &mut StandardsState,
) -> Result<(), (usize, InitWriteError)> {
    for (i, (file, action)) in rendered.iter().zip(actions).enumerate() {
        let path = root.join(&file.target);
        if action.writes() {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| (i, InitWriteError::new("create", parent, e)))?;
            }
            std::fs::write(&path, &file.content)
                .map_err(|e| (i, InitWriteError::new("write", &path, e)))?;
            new.files.insert(file.target.clone(), hash_bytes(&file.content));
            new.accepted.remove(&file.target);
        }
        if file.executable && touches(file, *action) {
            set_executable(&path).map_err(|e| (i, InitWriteError::new("chmod", &path, e)))?;
        }
    }
    Ok(())
}

/// Print one line per target (plus the dropped ones). With `stopped_at`, the
/// write of that target failed: it is marked `failed`, and every later target
/// `init` would have touched is marked `not run` rather than claimed done.
pub(super) fn report_targets(
    out: &mut impl Write,
    rendered: &[RenderedFile],
    actions: &[InitAction],
    prev: &StandardsState,
    stopped_at: Option<usize>,
) -> Result<(), Box<dyn Error>> {
    for (i, (file, action)) in rendered.iter().zip(actions).enumerate() {
        let mark = match stopped_at {
            Some(s) if i == s => "failed",
            Some(s) if i > s && touches(file, *action) => "not run",
            _ => action_mark(*action),
        };
        writeln!(out, "  {mark:<10} {}", file.target)?;
        if mark == action_mark(*action)
            && !matches!(action, InitAction::Created | InitAction::Unchanged | InitAction::Updated)
        {
            writeln!(out, "             {}", action.verb())?;
        }
    }

    let rendered_targets: BTreeSet<&str> = rendered.iter().map(|f| f.target.as_str()).collect();
    for dropped in prev.files.keys().filter(|t| !rendered_targets.contains(t.as_str())) {
        writeln!(
            out,
            "  {:<10} {dropped} (no longer part of the baseline; left in place)",
            "untracked"
        )?;
    }
    Ok(())
}

const fn action_mark(a: InitAction) -> &'static str {
    match a {
        InitAction::Created => "create",
        InitAction::Updated => "update",
        InitAction::Unchanged => "ok",
        InitAction::Skipped => "skip",
        InitAction::Accepted => "keep",
        InitAction::Forced => "overwrite",
    }
}

#[cfg(test)]
mod tests {

    use super::*;

    fn file(target: &str) -> RenderedFile {
        RenderedFile { target: target.to_string(), content: b"x\n".to_vec(), executable: false }
    }

    #[test]
    fn init_write_error_chains_io_source_instead_of_inlining_it() {
        let io = std::io::Error::other("disk on fire");
        let mut e = InitWriteError::new("write", Path::new("/r/a"), io);
        let src = e.source().and_then(|s| s.downcast_ref::<std::io::Error>());
        assert_eq!(src.map(std::io::Error::kind), Some(std::io::ErrorKind::Other));
        assert_eq!(
            e.to_string(),
            format!("failed to write /r/a (recorded the files written so far in {STATE_FILE})")
        );
        // Walking the chain prints the io message exactly once.
        let chain = error_chain(&e);
        assert_eq!(chain.matches("disk on fire").count(), 1, "{chain}");
        assert!(chain.ends_with(": disk on fire"), "{chain}");

        e.save = Some("disk gone".into());
        assert_eq!(
            e.to_string(),
            format!("failed to write /r/a (and saving {STATE_FILE} failed too: disk gone)")
        );
        // A save that failed with the same OS text keeps the write's cause.
        e.save = Some(Box::new(std::io::Error::other("disk on fire")));
        let chain = error_chain(&e);
        assert_eq!(chain.matches("disk on fire").count(), 2, "{chain}");
        assert!(chain.ends_with("): disk on fire"), "{chain}");
        assert!(e.source().expect("source").is::<std::io::Error>());
    }

    #[test]
    fn error_chain_skips_a_cause_already_inlined() {
        #[derive(Debug)]
        struct Inlined(std::io::Error);
        impl std::fmt::Display for Inlined {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "outer: {}", self.0)
            }
        }
        impl Error for Inlined {
            fn source(&self) -> Option<&(dyn Error + 'static)> {
                Some(&self.0)
            }
        }
        let e = Inlined(std::io::Error::other("boom"));
        assert_eq!(error_chain(&e), "outer: boom");
    }

    #[test]
    fn state_save_after_write_says_targets_were_written_and_chains_io() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::create_dir(tmp.path().join(STATE_FILE)).unwrap();
        let save = StandardsState::new().save(tmp.path()).unwrap_err();
        let e = StateSaveAfterWrite(save);
        assert!(e.to_string().starts_with("wrote every baseline file but could not record"), "{e}");
        // StateSaveAfterWrite -> StateSaveError -> io::Error.
        let io = e.source().and_then(Error::source).expect("io source");
        assert!(io.is::<std::io::Error>(), "{io}");
        let chain = error_chain(&e);
        assert_eq!(chain.matches(&io.to_string()).count(), 1, "{chain}");
    }

    #[test]
    fn write_targets_reports_failing_index_and_io_kind() {
        let tmp = tempfile::tempdir().unwrap();
        // A regular file where a directory is needed fails for root too.
        std::fs::write(tmp.path().join("blocker"), b"").unwrap();
        let rendered = [file("a"), file("blocker/b"), file("c")];
        let actions = [InitAction::Created; 3];
        let mut new = StandardsState::new();

        let (at, e) = write_targets(tmp.path(), &rendered, &actions, &mut new).unwrap_err();
        assert_eq!(at, 1);
        assert!(e.source().expect("source").is::<std::io::Error>(), "{e}");
        assert!(e.to_string().starts_with("failed to create "), "{e}");
        assert!(new.files.contains_key("a") && !new.files.contains_key("c"));
        assert!(!tmp.path().join("c").exists());
    }

    #[cfg(unix)]
    #[test]
    fn write_targets_reports_chmod_failure_with_io_source() {
        let tmp = tempfile::tempdir().unwrap();
        // A dangling symlink: the write is skipped (Unchanged), the chmod's
        // metadata lookup then fails with NotFound — for root too.
        std::os::unix::fs::symlink(tmp.path().join("gone"), tmp.path().join("s.sh")).unwrap();
        let rendered = [RenderedFile { executable: true, ..file("s.sh") }];
        let (at, e) = write_targets(
            tmp.path(),
            &rendered,
            &[InitAction::Unchanged],
            &mut StandardsState::new(),
        )
        .unwrap_err();
        assert_eq!(at, 0);
        assert!(e.to_string().starts_with("failed to chmod "), "{e}");
        let src = e.source().and_then(|s| s.downcast_ref::<std::io::Error>());
        assert_eq!(src.map(std::io::Error::kind), Some(std::io::ErrorKind::NotFound));
    }

    #[test]
    fn report_after_failure_claims_nothing_past_the_failed_target() {
        let rendered = [file("a"), file("b"), file("c"), file("d")];
        let actions =
            [InitAction::Created, InitAction::Updated, InitAction::Created, InitAction::Skipped];
        let mut out = Vec::new();
        report_targets(&mut out, &rendered, &actions, &StandardsState::new(), Some(1)).unwrap();
        let s = String::from_utf8(out).unwrap();
        assert_eq!(
            s,
            format!(
                "  create     a\n  failed     b\n  not run    c\n  skip       d\n             {}\n",
                InitAction::Skipped.verb()
            )
        );
    }

    #[test]
    fn report_without_failure_lists_dropped_targets_as_untracked() {
        let rendered = [file("a"), file("b")];
        let actions = [InitAction::Unchanged, InitAction::Created];
        let mut prev = StandardsState::new();
        for t in ["a", "gone.yml", "old/x"] {
            prev.files.insert(t.into(), "h".into());
        }
        let mut out = Vec::new();
        report_targets(&mut out, &rendered, &actions, &prev, None).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "  ok         a\n  create     b\n  \
             untracked  gone.yml (no longer part of the baseline; left in place)\n  \
             untracked  old/x (no longer part of the baseline; left in place)\n"
        );
    }

    #[test]
    fn report_after_failure_marks_chmod_only_script_not_run() {
        let rendered = [
            file("a"),
            RenderedFile { executable: true, ..file("s.sh") },
            file("plain"),
            RenderedFile { executable: true, ..file("t.sh") },
        ];
        // `s.sh` would only be chmodded (Unchanged + executable) — still not
        // run past the failure; an Unchanged non-script touches nothing.
        let actions = [
            InitAction::Created,
            InitAction::Unchanged,
            InitAction::Unchanged,
            InitAction::Unchanged,
        ];
        let mut out = Vec::new();
        report_targets(&mut out, &rendered, &actions, &StandardsState::new(), Some(0)).unwrap();
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "  failed     a\n  not run    s.sh\n  ok         plain\n  not run    t.sh\n"
        );
    }
}
