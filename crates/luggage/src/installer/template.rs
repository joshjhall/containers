//! URL template substitution.
//!
//! Catalog `source_url_template` and `verification.checksum_url_template`
//! values carry placeholders like `{rustup_target}`, `{arch}`, and
//! `{version}`. This module fills them in from a [`Substitutions`] table.
//! `source-build` step args reuse the same syntax, adding `{nproc}` so a
//! catalog can write `make -j{nproc}` without luggage hardcoding parallelism.
//!
//! Unknown placeholders return [`crate::LuggageError::TemplateMissingKey`]
//! rather than silently leaving them in the output, so a misconfigured
//! catalog fails fast.

use crate::error::{LuggageError, Result};

/// Substitution table.
///
/// All fields are optional; a placeholder referenced from a template that
/// has no matching field returns [`LuggageError::TemplateMissingKey`].
#[derive(Debug, Default, Clone, Copy)]
pub struct Substitutions<'a> {
    /// Substituted for `{version}`.
    pub version: Option<&'a str>,
    /// Substituted for `{rustup_target}`.
    pub rustup_target: Option<&'a str>,
    /// Substituted for `{arch}` — the resolved platform's catalog arch
    /// (`amd64` / `arm64`), verbatim. Upstreams that name artifacts by
    /// Debian-style arch (go's `go{version}.linux-{arch}.tar.gz`) use it
    /// directly; anything needing a different spelling gets its own key.
    pub arch: Option<&'a str>,
    /// Substituted for `{nproc}` — the host's available parallelism, see
    /// [`host_nproc`]. Only `source-build` step args populate it; a URL
    /// template referencing it fails as a missing key.
    pub nproc: Option<&'a str>,
}

impl<'a> Substitutions<'a> {
    /// Build a substitution table with `version` and `rustup_target` set.
    #[must_use]
    pub const fn new(version: &'a str, rustup_target: &'a str) -> Self {
        Self { version: Some(version), rustup_target: Some(rustup_target), arch: None, nproc: None }
    }

    /// Look up the value for a placeholder name.
    fn get(&self, key: &str) -> Option<&'a str> {
        match key {
            "version" => self.version,
            "rustup_target" => self.rustup_target,
            "arch" => self.arch,
            "nproc" => self.nproc,
            _ => None,
        }
    }
}

/// Substitute every `{key}` in `template` from `subs`.
///
/// Placeholders use a single-pass curly-brace syntax. Brace literals are
/// not supported (the catalog never needs them); a stray `{` without a
/// matching `}` is treated as literal text.
///
/// # Errors
///
/// - [`LuggageError::TemplateMissingKey`] if `template` references a key
///   not present in `subs`.
pub fn substitute_url(template: &str, subs: &Substitutions<'_>) -> Result<String> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        let Some(end_rel) = after.find('}') else {
            // No closing brace — treat the rest as literal.
            out.push('{');
            out.push_str(after);
            return Ok(out);
        };
        let key = &after[..end_rel];
        match subs.get(key) {
            Some(value) => out.push_str(value),
            None => return Err(LuggageError::TemplateMissingKey(key.to_owned())),
        }
        rest = &after[end_rel + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// The host CPU count `{nproc}` expands to, as a string.
///
/// `available_parallelism` honours cgroup CPU quotas and affinity masks, so
/// a build container capped at 4 CPUs gets `4` rather than the host's full
/// count — the same answer `nproc(1)` gives inside that container. Falls
/// back to `1` when the count cannot be determined: a slow serial build is
/// a better failure mode than a refused one.
#[must_use]
pub fn host_nproc() -> String {
    std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_placeholders_returns_input_verbatim() {
        let s = substitute_url("https://example.test/static", &Substitutions::default()).unwrap();
        assert_eq!(s, "https://example.test/static");
    }

    #[test]
    fn substitutes_single_placeholder() {
        let subs = Substitutions {
            rustup_target: Some("x86_64-unknown-linux-gnu"),
            ..Substitutions::default()
        };
        let s = substitute_url(
            "https://static.rust-lang.org/rustup/dist/{rustup_target}/rustup-init",
            &subs,
        )
        .unwrap();
        assert_eq!(
            s,
            "https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu/rustup-init",
        );
    }

    #[test]
    fn substitutes_multiple_placeholders() {
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let s = substitute_url("base/{version}/{rustup_target}/x", &subs).unwrap();
        assert_eq!(s, "base/1.95.0/x86_64-unknown-linux-gnu/x");
    }

    #[test]
    fn missing_key_returns_template_missing_key() {
        let err = substitute_url("base/{rustup_target}", &Substitutions::default()).unwrap_err();
        match err {
            LuggageError::TemplateMissingKey(key) => assert_eq!(key, "rustup_target"),
            other => panic!("expected TemplateMissingKey, got {other:?}"),
        }
    }

    #[test]
    fn unknown_key_returns_template_missing_key() {
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let err = substitute_url("base/{frobnicator}", &subs).unwrap_err();
        assert!(matches!(err, LuggageError::TemplateMissingKey(_)));
    }

    /// `{arch}` is the catalog arch verbatim (#811) — go's artifact URL is
    /// the motivating case.
    #[test]
    fn substitutes_arch() {
        let subs = Substitutions {
            version: Some("1.27.2"),
            arch: Some("arm64"),
            ..Substitutions::default()
        };
        let s = substitute_url("https://dl.google.com/go/go{version}.linux-{arch}.tar.gz", &subs)
            .unwrap();
        assert_eq!(s, "https://dl.google.com/go/go1.27.2.linux-arm64.tar.gz");
    }

    /// An `{arch}` template with no arch in the table fails loudly rather
    /// than emitting a URL with a literal `{arch}` in it — `new()` leaves it
    /// unset, so a call site that forgets to populate it is caught here.
    #[test]
    fn arch_missing_returns_template_missing_key() {
        let subs = Substitutions::new("1.27.2", "x86_64-unknown-linux-gnu");
        let err = substitute_url("go{version}.linux-{arch}.tar.gz", &subs).unwrap_err();
        match err {
            LuggageError::TemplateMissingKey(key) => assert_eq!(key, "arch"),
            other => panic!("expected TemplateMissingKey, got {other:?}"),
        }
    }

    #[test]
    fn unclosed_brace_is_treated_as_literal() {
        let subs = Substitutions::default();
        let s = substitute_url("path/{unclosed", &subs).unwrap();
        assert_eq!(s, "path/{unclosed");
    }

    #[test]
    fn back_to_back_placeholders() {
        let subs = Substitutions::new("1.95.0", "x86_64-unknown-linux-gnu");
        let s = substitute_url("{version}{rustup_target}", &subs).unwrap();
        assert_eq!(s, "1.95.0x86_64-unknown-linux-gnu");
    }

    /// `make -j{nproc}` is the motivating catalog shape (#809).
    #[test]
    fn substitutes_nproc() {
        let subs = Substitutions { nproc: Some("8"), ..Substitutions::default() };
        let s = substitute_url("-j{nproc}", &subs).unwrap();
        assert_eq!(s, "-j8");
    }

    /// URL call sites never populate `nproc`, so a URL template naming it
    /// fails loudly instead of baking a host CPU count into a download.
    #[test]
    fn nproc_missing_returns_template_missing_key() {
        let subs = Substitutions::new("1.0.0", "x86_64-unknown-linux-gnu");
        let err = substitute_url("-j{nproc}", &subs).unwrap_err();
        match err {
            LuggageError::TemplateMissingKey(key) => assert_eq!(key, "nproc"),
            other => panic!("expected TemplateMissingKey, got {other:?}"),
        }
    }

    /// What `make -j{nproc}` needs: a bare positive integer. Checked as a
    /// property of the output rather than by re-deriving the value, which
    /// would only prove the function equals its own body.
    #[test]
    fn host_nproc_is_a_bare_positive_integer() {
        let n = host_nproc();
        assert!(!n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()), "{n:?}");
        assert!(n.parse::<usize>().unwrap() >= 1, "{n:?}");
    }
}
