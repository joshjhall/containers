//! The repo-baseline `manifest.tsv` contract, implemented in Rust.
//!
//! The format is owned by containers-db (`baseline/templates/README.md`): one
//! row per line, four or five tab-separated columns `target slice when source
//! [mode]`. Keep a row when its slice is `core` or selected **and** its `when`
//! is `always` or names a selected CI platform; then each distinct target, in
//! first-appearance order, is the concatenation of its kept rows' sources in
//! manifest order. A target ending in `.sh` is executable. Nothing else — no
//! substitution, no newline fix-up — so this renderer and containers-db's
//! `render.sh` produce identical bytes, which `tests/standards_templates.rs`
//! checks.
//!
//! The optional `mode` ([`Mode`]) is empty (tracked), `once` (create-only), or
//! `link` (a symlink whose text is `source`, naming another target of the same
//! render). A target's rows must agree on the mode; a link target has exactly
//! one row.
//!
//! Every row is validated before anything is rendered: a malformed manifest
//! must fail the whole run, not write half a scaffold.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

/// The slice every render includes.
pub const CORE_SLICE: &str = "core";

/// A CI platform a manifest row can be conditioned on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Ci {
    /// GitHub Actions.
    GitHub,
    /// GitLab CI.
    GitLab,
}

impl Ci {
    /// Parse a `--ci` value (`github` or `gitlab`).
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "github" => Some(Self::GitHub),
            "gitlab" => Some(Self::GitLab),
            _ => None,
        }
    }

    /// The flag/manifest spelling.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::GitHub => "github",
            Self::GitLab => "gitlab",
        }
    }
}

impl fmt::Display for Ci {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// When a manifest row applies.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum When {
    Always,
    Ci(Ci),
}

/// How a target is written and checked (the manifest's optional 5th column).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Owned by the baseline: rewritten by `init`, drift-checked by `check`.
    Tracked,
    /// Create-only: written when absent, otherwise the user's — never
    /// overwritten (even with `--force`) and never drift.
    Once,
    /// A create-only symlink; [`RenderedFile::content`] holds the link text.
    Link,
}

impl Mode {
    /// Whether the target is written only when absent.
    #[must_use]
    pub const fn create_only(self) -> bool {
        matches!(self, Self::Once | Self::Link)
    }
}

/// One validated manifest row.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Row {
    target: String,
    slice: String,
    when: When,
    source: String,
    mode: Mode,
}

/// A parsed, validated manifest.
#[derive(Debug, Clone)]
pub struct Manifest {
    rows: Vec<Row>,
}

/// One rendered output file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderedFile {
    /// Repo-relative path.
    pub target: String,
    /// Exact bytes to write.
    pub content: Vec<u8>,
    /// Whether the file should be marked executable (`*.sh`, non-link).
    pub executable: bool,
    /// How the target is written and checked.
    pub mode: Mode,
}

/// Where template sources are read from — the embedded copy or a directory.
pub trait SourceReader {
    /// Return the bytes of `source` (a manifest-relative path), or `None` when
    /// it does not exist.
    fn read(&self, source: &str) -> Option<Vec<u8>>;
}

impl Manifest {
    /// Parse `text` and validate every row, including that each `source`
    /// exists in `sources`.
    ///
    /// # Errors
    ///
    /// Returns a `manifest line N: …` error for a row without four or five
    /// columns, an absolute or `..` target, an unknown `when` or `mode`, a
    /// missing source, bad link text, a target whose rows mix modes, or a link
    /// target with more than one row; and an error when the manifest has no
    /// rows at all.
    pub fn parse(text: &str, sources: &dyn SourceReader) -> Result<Self, String> {
        let mut rows = Vec::new();
        for (idx, line) in text.lines().enumerate() {
            let n = idx + 1;
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let cols: Vec<&str> = line.split('\t').collect();
            let (target, slice, when, source, mode) = match cols[..] {
                [target, slice, when, source] => (target, slice, when, source, ""),
                [target, slice, when, source, mode] => (target, slice, when, source, mode),
                _ => {
                    return Err(format!(
                        "manifest line {n}: expected 4 or 5 tab-separated columns"
                    ));
                }
            };
            if [target, slice, when, source].iter().any(|c| c.is_empty()) {
                return Err(format!("manifest line {n}: expected 4 or 5 tab-separated columns"));
            }
            let mode = match mode {
                "" => Mode::Tracked,
                "once" => Mode::Once,
                "link" => Mode::Link,
                other => {
                    return Err(format!(
                        "manifest line {n}: unknown mode '{other}' (known: once link)"
                    ));
                }
            };
            if !is_safe_relative(target) {
                return Err(format!(
                    "manifest line {n}: target must be a relative path inside the repo: {target}"
                ));
            }
            if mode == Mode::Link {
                if !is_plain_relative(source) {
                    return Err(format!(
                        "manifest line {n}: link text must be a plain relative path \
                         (no '..', '.' or empty segments): {source}"
                    ));
                }
            } else if !is_safe_relative(source) {
                return Err(format!("manifest line {n}: source must be a relative path: {source}"));
            }
            let when = match when {
                "always" => When::Always,
                "ci=github" => When::Ci(Ci::GitHub),
                "ci=gitlab" => When::Ci(Ci::GitLab),
                other => {
                    return Err(format!(
                        "manifest line {n}: unknown when '{other}' \
                         (known: always ci=github ci=gitlab)"
                    ));
                }
            };
            if mode != Mode::Link && sources.read(source).is_none() {
                return Err(format!("manifest line {n}: source not found: {source}"));
            }
            // A target's rows must agree on its mode, selected or not.
            if let Some(prev) = rows.iter().find(|r: &&Row| r.target == target) {
                if prev.mode != mode {
                    return Err(format!(
                        "manifest line {n}: {target} mixes modes ({:?} vs {mode:?})",
                        prev.mode
                    ));
                }
                if mode == Mode::Link {
                    return Err(format!(
                        "manifest line {n}: link target {target} has more than one row"
                    ));
                }
            }
            rows.push(Row {
                target: target.to_string(),
                slice: slice.to_string(),
                when,
                source: source.to_string(),
                mode,
            });
        }
        if rows.is_empty() {
            return Err("manifest has no rows".into());
        }
        Ok(Self { rows })
    }

    /// The language slices the manifest defines (every slice except `core`),
    /// sorted.
    #[must_use]
    pub fn language_slices(&self) -> BTreeSet<String> {
        self.rows.iter().filter(|r| r.slice != CORE_SLICE).map(|r| r.slice.clone()).collect()
    }

    /// Render the targets for the selected language `slices` and CI platforms,
    /// in first-appearance order.
    ///
    /// # Errors
    ///
    /// Returns an error naming an unknown slice, a source that disappeared
    /// between [`Manifest::parse`] and rendering, or a link whose text does not
    /// name a non-link target of this render.
    pub fn render(
        &self,
        slices: &BTreeSet<String>,
        ci: &BTreeSet<Ci>,
        sources: &dyn SourceReader,
    ) -> Result<Vec<RenderedFile>, String> {
        let known = self.language_slices();
        if let Some(bad) = slices.iter().find(|s| !known.contains(*s) && *s != CORE_SLICE) {
            let known: Vec<&str> = known.iter().map(String::as_str).collect();
            return Err(format!("unknown slice '{bad}' (known: {})", known.join(" ")));
        }

        let mut order: Vec<(&str, Mode)> = Vec::new();
        let mut content: BTreeMap<&str, Vec<u8>> = BTreeMap::new();
        for row in &self.rows {
            let slice_ok = row.slice == CORE_SLICE || slices.contains(&row.slice);
            let when_ok = match row.when {
                When::Always => true,
                When::Ci(c) => ci.contains(&c),
            };
            if !(slice_ok && when_ok) {
                continue;
            }
            // A link's "content" is its text, compared as written.
            let bytes = if row.mode == Mode::Link {
                row.source.as_bytes().to_vec()
            } else {
                sources
                    .read(&row.source)
                    .ok_or_else(|| format!("source not found: {}", row.source))?
            };
            content
                .entry(row.target.as_str())
                .or_insert_with(|| {
                    order.push((row.target.as_str(), row.mode));
                    Vec::new()
                })
                .extend_from_slice(&bytes);
        }

        // A link must name a non-link file this same selection renders: read
        // relative to the link's directory, never normalized.
        for (t, mode) in &order {
            if *mode != Mode::Link {
                continue;
            }
            let text = String::from_utf8_lossy(&content[t]).into_owned();
            let dest =
                t.rsplit_once('/').map_or_else(|| text.clone(), |(dir, _)| format!("{dir}/{text}"));
            if !order.iter().any(|(o, m)| *o == dest && *m != Mode::Link) {
                return Err(format!(
                    "link {t} -> {text}: target is not a file rendered by this selection"
                ));
            }
        }

        // The contract matches `*.sh` byte-for-byte, as `render.sh`'s `case`
        // does; a case-insensitive match would diverge from librarian.
        #[expect(clippy::case_sensitive_file_extension_comparisons, reason = "manifest contract")]
        let is_script = |t: &str| t.ends_with(".sh");
        Ok(order
            .into_iter()
            .map(|(t, mode)| RenderedFile {
                target: t.to_string(),
                content: content.remove(t).unwrap_or_default(),
                executable: mode != Mode::Link && is_script(t),
                mode,
            })
            .collect())
    }
}

/// A non-empty relative path with no `..` component and no leading `/`.
fn is_safe_relative(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.starts_with('\\')
        && path.split(['/', '\\']).all(|c| c != "..")
}

/// Link text: relative, with no `..`, `.` or empty segment and no leading `/`
/// (`render.sh`'s rule — it is compared to target names as written).
fn is_plain_relative(path: &str) -> bool {
    !path.starts_with('/')
        && !path.contains('\\')
        && path.split('/').all(|c| !c.is_empty() && c != "." && c != "..")
}

#[cfg(test)]
mod tests {
    use super::*;

    struct MapSource(BTreeMap<&'static str, &'static str>);

    impl SourceReader for MapSource {
        fn read(&self, source: &str) -> Option<Vec<u8>> {
            self.0.get(source).map(|s| s.as_bytes().to_vec())
        }
    }

    fn sources() -> MapSource {
        MapSource(BTreeMap::from([
            ("core/head", "head\n"),
            ("core/tail", "tail\n"),
            ("core/gh", "gh\n"),
            ("core/gl", "gl\n"),
            ("shell/frag", "shell\n"),
            ("python/frag", "python\n"),
            ("core/run.sh", "#!/bin/sh\n"),
        ]))
    }

    const MANIFEST: &str = "# comment\n\
        lint\tcore\talways\tcore/head\n\
        lint\tshell\talways\tshell/frag\n\
        lint\tpython\talways\tpython/frag\n\
        lint\tcore\talways\tcore/tail\n\
        ci-gh\tcore\tci=github\tcore/gh\n\
        ci-gl\tcore\tci=gitlab\tcore/gl\n\
        \n\
        bin/run.sh\tcore\talways\tcore/run.sh\n";

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    fn render(slices: &[&str], ci: &[Ci]) -> Vec<RenderedFile> {
        let src = sources();
        let m = Manifest::parse(MANIFEST, &src).unwrap();
        m.render(&set(slices), &ci.iter().copied().collect(), &src).unwrap()
    }

    #[test]
    fn concatenates_selected_slices_in_manifest_order() {
        let out = render(&["python", "shell"], &[]);
        let lint = out.iter().find(|f| f.target == "lint").unwrap();
        // Manifest order, not selection order: shell precedes python.
        assert_eq!(lint.content, b"head\nshell\npython\ntail\n");
    }

    #[test]
    fn unselected_slice_rows_are_dropped() {
        let out = render(&["shell"], &[]);
        let lint = out.iter().find(|f| f.target == "lint").unwrap();
        assert_eq!(lint.content, b"head\nshell\ntail\n");
    }

    #[test]
    fn ci_rows_follow_selected_platforms() {
        let targets =
            |ci: &[Ci]| -> Vec<String> { render(&[], ci).into_iter().map(|f| f.target).collect() };
        assert_eq!(targets(&[Ci::GitHub]), ["lint", "ci-gh", "bin/run.sh"]);
        assert_eq!(targets(&[Ci::GitLab]), ["lint", "ci-gl", "bin/run.sh"]);
        assert_eq!(targets(&[Ci::GitHub, Ci::GitLab]), ["lint", "ci-gh", "ci-gl", "bin/run.sh"]);
        assert_eq!(targets(&[]), ["lint", "bin/run.sh"]);
    }

    #[test]
    fn only_sh_targets_are_executable() {
        let out = render(&[], &[]);
        let exec: Vec<&str> =
            out.iter().filter(|f| f.executable).map(|f| f.target.as_str()).collect();
        assert_eq!(exec, ["bin/run.sh"]);
    }

    #[test]
    fn language_slices_exclude_core() {
        let m = Manifest::parse(MANIFEST, &sources()).unwrap();
        assert_eq!(m.language_slices(), set(&["python", "shell"]));
    }

    #[test]
    fn unknown_slice_is_rejected() {
        let src = sources();
        let m = Manifest::parse(MANIFEST, &src).unwrap();
        let err = m.render(&set(&["rust"]), &BTreeSet::new(), &src).unwrap_err();
        assert!(err.contains("unknown slice 'rust'"), "{err}");
    }

    #[test]
    fn rejects_malformed_rows() {
        for (text, want) in [
            ("a\tcore\talways\n", "line 1: expected 4 or 5"),
            ("a\tcore\talways\tcore/head\tonce\textra\n", "line 1: expected 4 or 5"),
            ("a\tcore\talways\tcore/head\textra\n", "unknown mode 'extra'"),
            (
                "a\tcore\talways\tcore/head\tonce\na\tcore\talways\tcore/tail\n",
                "line 2: a mixes modes",
            ),
            (
                "l\tcore\talways\tx\tlink\nl\tcore\talways\ty\tlink\n",
                "line 2: link target l has more than one row",
            ),
            ("l\tcore\talways\t../x\tlink\n", "link text must be a plain relative path"),
            ("l\tcore\talways\t./x\tlink\n", "link text must be a plain relative path"),
            ("l\tcore\talways\ta//x\tlink\n", "link text must be a plain relative path"),
            ("l\tcore\talways\t/etc/x\tlink\n", "link text must be a plain relative path"),
            ("/etc/x\tcore\talways\tcore/head\n", "relative path inside the repo"),
            ("a/../../x\tcore\talways\tcore/head\n", "relative path inside the repo"),
            ("..\tcore\talways\tcore/head\n", "relative path inside the repo"),
            ("a\tcore\tci=jenkins\tcore/head\n", "unknown when 'ci=jenkins'"),
            ("a\tcore\talways\tcore/nope\n", "source not found: core/nope"),
            ("a\tcore\talways\t../outside\n", "source must be a relative path"),
            ("# only comments\n", "no rows"),
        ] {
            let err = Manifest::parse(text, &sources()).unwrap_err();
            assert!(err.contains(want), "{text:?}: expected `{want}` in `{err}`");
        }
    }

    const MODES: &str = "doc\tcore\talways\tcore/head\tonce\n\
        doc\tshell\talways\tshell/frag\tonce\n\
        alias\tcore\talways\tdoc\tlink\n\
        sub/alias\tcore\talways\tdoc\tlink\n\
        sub/doc\tcore\talways\tcore/tail\n";

    #[test]
    fn modes_render_once_concatenated_and_link_as_its_text() {
        let src = sources();
        let m = Manifest::parse(MODES, &src).unwrap();
        let out = m.render(&set(&["shell"]), &BTreeSet::new(), &src).unwrap();
        let get = |t: &str| out.iter().find(|f| f.target == t).unwrap();
        assert_eq!(get("doc").mode, Mode::Once);
        assert_eq!(get("doc").content, b"head\nshell\n");
        assert_eq!(get("alias").mode, Mode::Link);
        assert_eq!(get("alias").content, b"doc");
        // Link text is relative to the link's own directory.
        assert_eq!(get("sub/alias").content, b"doc");
        assert_eq!(get("sub/doc").mode, Mode::Tracked);
        assert!(Mode::Once.create_only() && Mode::Link.create_only());
        assert!(!Mode::Tracked.create_only());
    }

    #[test]
    fn link_must_name_a_non_link_target_of_the_same_render() {
        let src = sources();
        for (text, slices, want) in [
            // Names a target the selection does not render.
            (
                "doc\tshell\talways\tcore/head\nl\tcore\talways\tdoc\tlink\n",
                &[][..],
                "link l -> doc",
            ),
            // Names another link.
            (
                "a\tcore\talways\tb\tlink\nb\tcore\talways\tc\tlink\nc\tcore\talways\tcore/head\n",
                &[],
                "link a -> b",
            ),
            // Resolved relative to the link's directory, not the root.
            (
                "doc\tcore\talways\tcore/head\nsub/l\tcore\talways\tdoc\tlink\n",
                &[],
                "link sub/l -> doc",
            ),
        ] {
            let m = Manifest::parse(text, &src).unwrap();
            let err = m.render(&set(slices), &BTreeSet::new(), &src).unwrap_err();
            assert!(err.contains(want), "{text:?}: expected `{want}` in `{err}`");
        }
    }

    #[test]
    fn link_and_once_sh_targets() {
        let src = sources();
        let m = Manifest::parse(
            "run.sh\tcore\talways\tcore/run.sh\tonce\nl.sh\tcore\talways\trun.sh\tlink\n",
            &src,
        )
        .unwrap();
        let out = m.render(&BTreeSet::new(), &BTreeSet::new(), &src).unwrap();
        assert!(out[0].executable, "a once *.sh is still executable");
        assert!(!out[1].executable, "a link is never chmodded");
    }

    #[test]
    fn error_line_numbers_count_comments_and_blanks() {
        let text = "# c\n\na\tcore\tnever\tcore/head\n";
        let err = Manifest::parse(text, &sources()).unwrap_err();
        assert!(err.starts_with("manifest line 3:"), "{err}");
    }

    #[test]
    fn ci_parse_round_trips() {
        for ci in [Ci::GitHub, Ci::GitLab] {
            assert_eq!(Ci::parse(ci.as_str()), Some(ci));
        }
        assert_eq!(Ci::parse("jenkins"), None);
    }
}
