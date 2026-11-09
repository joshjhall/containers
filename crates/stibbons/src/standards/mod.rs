//! `stibbons setup standards` — apply and check the repo baseline.
//!
//! The baseline (hooks, linter configs, justfile, test runner, tool installer,
//! GitHub/GitLab CI) is librarian's `repo-baseline` scaffold. Its templates are
//! vendored into `crates/stibbons/assets/repo-baseline/` by
//! `bin/sync-repo-baseline.sh` and embedded at build time, so this works on a
//! host with no librarian checkout; `--templates-dir` points at another copy.
//!
//! - [`init`] renders the manifest for the selected slices/CI and writes it,
//!   never clobbering a user-edited file without `--force`.
//! - [`check`] re-renders and reports drift: a missing file, a locally modified
//!   one, or an unedited one the current templates would change (stale).
//! - [`accept()`] records a reviewed local edit (the templates' `# per-repo:`
//!   lines exist to be edited) so `check` stops flagging it.
//!
//! State lives in [`state::STATE_FILE`], independent of `.igor.yml`.

mod accept;
pub mod detect;
mod fsutil;
pub mod manifest;
pub mod state;
mod templates;
mod write;

use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};

use containers_common::generate::hash_bytes;

pub use accept::accept;
use accept::classify_all;
use fsutil::{ensure_no_symlink, read_if_exists};
use manifest::{Ci, Manifest, RenderedFile};
use state::{STATE_FILE, StandardsState};
pub use templates::Templates;
pub use write::error_chain;
use write::{StateSaveAfterWrite, report_targets, write_targets};

/// Inputs to [`init`].
#[derive(Debug, Clone)]
pub struct InitOptions {
    /// Repository root.
    pub root: PathBuf,
    /// Explicit language slices (`--lang`); `None` = stored, then detected.
    pub langs: Option<Vec<String>>,
    /// Explicit CI platforms (`--ci`); `None` = stored, then `origin_ci`.
    pub ci: Option<Vec<String>>,
    /// CI platform inferred from the `origin` remote, used when neither `--ci`
    /// nor a stored selection exists. GitHub when `None`.
    pub origin_ci: Option<Ci>,
    /// Overwrite locally modified (or accepted) files.
    pub force: bool,
    /// Report the plan without writing anything.
    pub dry_run: bool,
    /// Template source.
    pub templates: Templates,
}

/// What `init` does (or would do) to one target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitAction {
    /// Absent on disk; written.
    Created,
    /// Unedited since stibbons wrote it; rewritten with new template bytes.
    Updated,
    /// Already identical to the rendered bytes.
    Unchanged,
    /// Locally modified (or pre-existing with no record); left alone.
    Skipped,
    /// A user edit recorded by `accept`; left alone.
    Accepted,
    /// Would have been skipped/accepted, but `--force` overwrote it.
    Forced,
}

impl InitAction {
    const fn writes(self) -> bool {
        matches!(self, Self::Created | Self::Updated | Self::Forced)
    }

    const fn verb(self) -> &'static str {
        match self {
            Self::Created => "created",
            Self::Updated => "updated",
            Self::Unchanged => "unchanged",
            Self::Skipped => "skipped (locally modified; --force to overwrite)",
            Self::Accepted => "kept (accepted local edit; --force to overwrite)",
            Self::Forced => "overwritten (--force)",
        }
    }
}

/// Drift state of one target, as reported by [`check`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    /// Matches the rendered templates.
    Ok,
    /// Matches a user edit recorded by `accept`.
    Accepted,
    /// Absent on disk.
    Missing,
    /// Differs from what stibbons wrote, and was not accepted.
    Modified,
    /// Unedited, but the current templates render different bytes.
    Stale,
}

impl FileState {
    /// Whether this state counts as drift (non-zero exit).
    #[must_use]
    pub const fn is_drift(self) -> bool {
        matches!(self, Self::Missing | Self::Modified | Self::Stale)
    }
}

/// Outcome of [`check`].
#[derive(Debug, Clone)]
pub struct CheckReport {
    /// Per-target state, in manifest order.
    pub files: Vec<(String, FileState)>,
}

impl CheckReport {
    /// Whether any target drifted.
    #[must_use]
    pub fn drift(&self) -> bool {
        self.files.iter().any(|(_, s)| s.is_drift())
    }
}

/// Apply the baseline: render, classify each target against disk and the
/// recorded state, write what is safe to write, and save the state.
///
/// # Errors
///
/// Returns an error on an invalid manifest, an unknown `--lang`/`--ci`, an
/// unreadable state file, a target reached through a symlink, or a write
/// failure. Validation happens before any file is written. A write or chmod
/// failure still saves the state, recording the targets written so far, so a
/// re-run after fixing the cause does not mistake them for user edits. A file
/// left truncated by a failed write is not recorded and reads as modified;
/// `--force` resolves that. The per-target report on `out` is printed after
/// the writes, so on failure it marks the failed target and every later one it
/// never reached instead of claiming them created/updated; the returned
/// [`write::InitWriteError`] keeps the underlying [`std::io::Error`] as its `source()`.
/// A state save that fails after every target was written returns a
/// [`write::StateSaveAfterWrite`] saying so, chained to the save error.
pub fn init(opts: &InitOptions, out: &mut impl Write) -> Result<(), Box<dyn std::error::Error>> {
    let state_path = opts.root.join(STATE_FILE);
    let old = StandardsState::load(&state_path)?;
    let manifest = opts.templates.manifest()?;

    let slices = resolve_slices(opts, old.as_ref(), &manifest)?;
    let ci = resolve_ci(opts.ci.as_deref(), old.as_ref(), opts.origin_ci)?;
    let rendered = manifest.render(&slices, &ci, &opts.templates)?;

    let empty = StandardsState::new();
    let prev = old.as_ref().unwrap_or(&empty);
    let mut actions = Vec::with_capacity(rendered.len());
    for file in &rendered {
        actions.push(classify_init(&opts.root, file, prev, opts.force)?);
    }

    // Refuse before touching anything if any write or chmod — or the state
    // file save — would go through a symlink.
    for (file, action) in rendered.iter().zip(&actions) {
        if touches(file, *action) {
            ensure_no_symlink(&opts.root, &file.target)?;
        }
    }
    // `save` re-checks, but refusing here keeps a linked state file from
    // costing a partial write of the baseline first.
    if !opts.dry_run {
        ensure_no_symlink(&opts.root, STATE_FILE)?;
    }

    writeln!(
        out,
        "Repo baseline ({}): slices [{}], ci [{}]{}",
        opts.templates.label(),
        join(slices.iter().map(String::as_str)),
        join(ci.iter().map(|c| c.as_str())),
        if opts.dry_run { " — dry run, nothing written" } else { "" }
    )?;

    if opts.dry_run {
        return report_targets(out, &rendered, &actions, prev, None);
    }

    let mut new = StandardsState::new();
    new.source = opts.templates.label();
    new.slices = slices.into_iter().collect();
    new.ci = ci.iter().map(|c| c.as_str().to_string()).collect();
    seed_state(&mut new, prev, &rendered, &actions);

    // Save on failure too: the state then records exactly what is on disk, so
    // a re-run (after fixing the cause) recognizes the files this run already
    // wrote instead of reporting them as user edits.
    if let Err((stopped_at, mut e)) = write_targets(&opts.root, &rendered, &actions, &mut new) {
        e.save = new.save(&opts.root).err();
        // Best effort: the write error is the one to surface, not a broken pipe.
        let _ = report_targets(out, &rendered, &actions, prev, Some(stopped_at));
        return Err(Box::new(e));
    }
    // Every target is on disk now, so report them even if the save fails.
    let saved = new.save(&opts.root);
    report_targets(out, &rendered, &actions, prev, None)?;
    saved.map_err(StateSaveAfterWrite)?;

    let skipped = actions.iter().filter(|a| matches!(a, InitAction::Skipped)).count();
    writeln!(out, "\nWrote {STATE_FILE}.")?;
    if skipped > 0 {
        writeln!(
            out,
            "{skipped} file(s) differ from the baseline and were left alone: review them, then \
             `stibbons setup standards accept` or re-run with --force."
        )?;
    }
    writeln!(
        out,
        "Next: edit every `# per-repo:` line, record those edits with \
         `stibbons setup standards accept`, then `lefthook install`."
    )?;
    Ok(())
}

/// Re-render with the recorded selection and classify every target.
///
/// # Errors
///
/// Returns an error when there is no state file (run `init` first), it cannot
/// be parsed, or the templates fail to render.
pub fn check(
    root: &Path,
    templates: &Templates,
    out: &mut impl Write,
) -> Result<CheckReport, Box<dyn std::error::Error>> {
    let (state, rendered) = load_and_render(root, templates)?;
    let report = classify_all(root, &state, &rendered)?;

    if state.source != templates.label() {
        writeln!(
            out,
            "note: init used templates from `{}`; checking against `{}`",
            state.source,
            templates.label()
        )?;
    }
    writeln!(
        out,
        "Repo baseline: slices [{}], ci [{}]",
        state.slices.join(", "),
        state.ci.join(", ")
    )?;
    for (target, s) in &report.files {
        let line = match s {
            FileState::Ok => format!("  ✓ {target}"),
            FileState::Accepted => format!("  ✓ {target} (accepted local edit)"),
            FileState::Missing => format!("  ✗ {target} (missing)"),
            FileState::Modified => format!("  ! {target} (modified)"),
            FileState::Stale => format!("  ~ {target} (stale: templates changed; re-run init)"),
        };
        writeln!(out, "{line}")?;
    }
    if report.drift() {
        writeln!(
            out,
            "\nDrift detected. `stibbons setup standards init` restores missing/stale files; \
             `stibbons setup standards accept` records reviewed local edits."
        )?;
    } else {
        writeln!(out, "\nRepo baseline is up to date.")?;
    }
    Ok(report)
}

/// Seed the new state with what is true on disk *before* any write: an
/// unchanged target already holds the rendered bytes; every other target keeps
/// its previous provenance/accepted hash, so a write that never happens leaves
/// the old record intact. [`write_targets`] upgrades each entry it writes.
fn seed_state(
    new: &mut StandardsState,
    prev: &StandardsState,
    rendered: &[RenderedFile],
    actions: &[InitAction],
) {
    for (file, action) in rendered.iter().zip(actions) {
        let t = &file.target;
        if *action == InitAction::Unchanged {
            new.files.insert(t.clone(), hash_bytes(&file.content));
            continue;
        }
        // Skipped/Accepted are never overwritten: keeping the hashes lets a
        // later run still recognize the user's edit as theirs, and keeps an
        // accepted edit accepted.
        if let Some(h) = prev.files.get(t) {
            new.files.insert(t.clone(), h.clone());
        }
        if let Some(h) = prev.accepted.get(t) {
            new.accepted.insert(t.clone(), h.clone());
        }
    }
}

/// Load the required state file and render its recorded selection.
fn load_and_render(
    root: &Path,
    templates: &Templates,
) -> Result<(StandardsState, Vec<RenderedFile>), Box<dyn std::error::Error>> {
    let state = StandardsState::load(&root.join(STATE_FILE))?.ok_or_else(|| {
        format!("no {STATE_FILE} found; run `stibbons setup standards init` first")
    })?;
    let manifest = templates.manifest()?;
    let slices: BTreeSet<String> = state.slices.iter().cloned().collect();
    let ci = parse_ci(&state.ci)?;
    let rendered = manifest.render(&slices, &ci, templates)?;
    Ok((state, rendered))
}

/// Classify one target for `init`. Same semantics as
/// [`containers_common::generate::classify_file`] (missing → create, unedited
/// → update, otherwise skip unless forced), on raw bytes, plus the accepted-edit
/// case.
fn classify_init(
    root: &Path,
    file: &RenderedFile,
    prev: &StandardsState,
    force: bool,
) -> Result<InitAction, Box<dyn std::error::Error>> {
    let Some(disk) = read_if_exists(&root.join(&file.target))? else {
        return Ok(InitAction::Created);
    };
    let disk_hash = hash_bytes(&disk);
    if disk_hash == hash_bytes(&file.content) {
        return Ok(InitAction::Unchanged);
    }
    if prev.accepted.get(&file.target) == Some(&disk_hash) {
        return Ok(if force { InitAction::Forced } else { InitAction::Accepted });
    }
    if prev.files.get(&file.target) == Some(&disk_hash) {
        return Ok(InitAction::Updated);
    }
    Ok(if force { InitAction::Forced } else { InitAction::Skipped })
}

fn resolve_slices(
    opts: &InitOptions,
    old: Option<&StandardsState>,
    manifest: &Manifest,
) -> Result<BTreeSet<String>, Box<dyn std::error::Error>> {
    let known = manifest.language_slices();
    let chosen: BTreeSet<String> = match (&opts.langs, old) {
        (Some(langs), _) => {
            langs.iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
        }
        (None, Some(s)) => s.slices.iter().cloned().collect(),
        (None, None) => detect::detect_slices(&opts.root, &known),
    };
    if let Some(bad) = chosen.iter().find(|s| !known.contains(*s)) {
        return Err(format!(
            "unknown language '{bad}' (known: {})",
            join(known.iter().map(String::as_str))
        )
        .into());
    }
    Ok(chosen)
}

fn resolve_ci(
    flag: Option<&[String]>,
    old: Option<&StandardsState>,
    origin: Option<Ci>,
) -> Result<BTreeSet<Ci>, Box<dyn std::error::Error>> {
    if let Some(values) = flag {
        let ci = parse_ci(values)?;
        if ci.is_empty() {
            return Err("--ci needs at least one of: github gitlab".into());
        }
        return Ok(ci);
    }
    if let Some(s) = old
        && !s.ci.is_empty()
    {
        return parse_ci(&s.ci);
    }
    Ok(BTreeSet::from([origin.unwrap_or(Ci::GitHub)]))
}

fn parse_ci(values: &[String]) -> Result<BTreeSet<Ci>, Box<dyn std::error::Error>> {
    values
        .iter()
        .map(|v| v.trim())
        .filter(|v| !v.is_empty())
        .map(|v| {
            Ci::parse(v)
                .ok_or_else(|| format!("unknown CI platform '{v}' (known: github gitlab)").into())
        })
        .collect()
}

/// Whether `init` will modify `file` on disk: write its bytes, or (for an
/// unchanged script) re-apply the executable bit a checkout can drop. The
/// symlink guard and the chmod both key on this, so they cannot diverge.
fn touches(file: &RenderedFile, action: InitAction) -> bool {
    action.writes() || (file.executable && action == InitAction::Unchanged)
}

fn join<'a>(items: impl Iterator<Item = &'a str>) -> String {
    let v: Vec<&str> = items.collect();
    if v.is_empty() { "none".to_string() } else { v.join(", ") }
}
