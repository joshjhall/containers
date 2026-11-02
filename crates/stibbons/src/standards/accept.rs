//! `stibbons setup standards accept` — record reviewed local edits so `check`
//! stops flagging them, plus the per-target classification `check` shares.

use std::collections::BTreeSet;
use std::io::Write;
use std::path::Path;

use containers_common::generate::hash_bytes;

use super::fsutil::read_if_exists;
use super::manifest::RenderedFile;
use super::state::StandardsState;
use super::{CheckReport, FileState, Templates, load_and_render};

/// Record the current on-disk bytes of `paths` (default: every modified
/// target) as accepted local edits. A named target that already matches the
/// baseline is skipped with a note; a stale one is accepted with a warning,
/// since that pins it against template updates.
///
/// # Errors
///
/// Returns an error when there is no state file, a path is not a baseline
/// target, or a named file does not exist.
pub fn accept(
    root: &Path,
    templates: &Templates,
    paths: &[String],
    out: &mut impl Write,
) -> Result<(), Box<dyn std::error::Error>> {
    let (mut state, rendered) = load_and_render(root, templates)?;
    // Buffer the report and print it only once the state is saved: a later
    // path that errors must not leave "accepted"/"cleared" lines behind for a
    // change that never reached disk.
    let mut log = Vec::new();
    accept_into(root, &mut state, &rendered, paths, &mut log)?;
    out.write_all(&log)?;
    Ok(())
}

/// The body of [`accept`], reporting into `out` and saving `state` on success.
fn accept_into(
    root: &Path,
    state: &mut StandardsState,
    rendered: &[RenderedFile],
    paths: &[String],
    out: &mut impl Write,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut cleared = false;
    let mut targets: Vec<String> = Vec::new();
    if paths.is_empty() {
        for (t, s) in classify_all(root, state, rendered)?.files {
            match s {
                FileState::Modified => targets.push(t),
                // Each of these means disk no longer holds the accepted bytes
                // (Ok/Stale: reverted; Missing: deleted), so any acceptance is
                // of an edit that is gone.
                FileState::Ok | FileState::Stale | FileState::Missing => {
                    cleared |= clear_reverted_acceptance(state, &t, out)?;
                }
                // An acceptance still matching disk is live, even when the render
                // has caught up to it: `init` then sees the file as unchanged and
                // drops the acceptance itself (see `seed_state`).
                FileState::Accepted => {}
            }
        }
    } else {
        let mut seen = BTreeSet::new();
        for p in paths {
            let t = p.strip_prefix("./").unwrap_or(p);
            let Some(file) = rendered.iter().find(|f| f.target == t) else {
                return Err(format!("`{p}` is not a repo-baseline file").into());
            };
            // `x` and `./x` name one target: classify and report it once.
            if !seen.insert(t) {
                continue;
            }
            match classify_check(root, file, state)? {
                FileState::Ok => {
                    writeln!(
                        out,
                        "  skipped {t} (already matches the baseline; nothing to accept)"
                    )?;
                    cleared |= clear_reverted_acceptance(state, t, out)?;
                }
                FileState::Stale => {
                    writeln!(
                        out,
                        "  warning: {t} is stale (unedited, but the templates changed); accepting \
                         pins it against template updates — `stibbons setup standards init` \
                         would update it instead"
                    )?;
                    targets.push(t.to_string());
                }
                FileState::Accepted | FileState::Missing | FileState::Modified => {
                    targets.push(t.to_string());
                }
            }
        }
    }

    if targets.is_empty() {
        if cleared {
            state.save(root)?;
        } else {
            writeln!(out, "No modified baseline files to accept.")?;
        }
        return Ok(());
    }
    for t in &targets {
        let path = root.join(t);
        let bytes = std::fs::read(&path).map_err(|e| format!("cannot accept {t}: {e}"))?;
        state.accepted.insert(t.clone(), hash_bytes(&bytes));
        writeln!(out, "  accepted {t}")?;
    }
    state.save(root)?;
    Ok(())
}

/// Drop the accepted hash of a target whose accepted edit is no longer on disk
/// (reverted or deleted). Left in place, it would silently re-approve that edit
/// if it ever returned.
/// Only an acceptance of bytes no longer on disk is stale; one that still
/// matches disk stays until `init` finds the render has caught up to it.
/// Returns whether anything was cleared.
fn clear_reverted_acceptance(
    state: &mut StandardsState,
    target: &str,
    out: &mut impl Write,
) -> Result<bool, Box<dyn std::error::Error>> {
    if state.accepted.remove(target).is_none() {
        return Ok(false);
    }
    writeln!(
        out,
        "  cleared the earlier accepted edit of {target} (that edit is no longer on disk)"
    )?;
    Ok(true)
}

pub(super) fn classify_all(
    root: &Path,
    state: &StandardsState,
    rendered: &[RenderedFile],
) -> Result<CheckReport, Box<dyn std::error::Error>> {
    let mut files = Vec::with_capacity(rendered.len());
    for f in rendered {
        files.push((f.target.clone(), classify_check(root, f, state)?));
    }
    Ok(CheckReport { files })
}

/// Classify one target for `check`.
fn classify_check(
    root: &Path,
    file: &RenderedFile,
    state: &StandardsState,
) -> Result<FileState, Box<dyn std::error::Error>> {
    let Some(disk) = read_if_exists(&root.join(&file.target))? else {
        return Ok(FileState::Missing);
    };
    let disk_hash = hash_bytes(&disk);
    if state.accepted.get(&file.target) == Some(&disk_hash) {
        return Ok(FileState::Accepted);
    }
    if disk_hash == hash_bytes(&file.content) {
        return Ok(FileState::Ok);
    }
    if state.files.get(&file.target) == Some(&disk_hash) {
        return Ok(FileState::Stale);
    }
    Ok(FileState::Modified)
}
