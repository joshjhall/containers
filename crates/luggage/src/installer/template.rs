//! URL template substitution.
//!
//! Catalog `source_url_template` and `verification.checksum_url_template`
//! values carry placeholders like `{rustup_target}` and `{version}`. This
//! module fills them in from a [`Substitutions`] table.
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
}

impl<'a> Substitutions<'a> {
    /// Build a substitution table with both fields set.
    #[must_use]
    pub const fn new(version: &'a str, rustup_target: &'a str) -> Self {
        Self { version: Some(version), rustup_target: Some(rustup_target) }
    }

    /// Look up the value for a placeholder name.
    fn get(&self, key: &str) -> Option<&'a str> {
        match key {
            "version" => self.version,
            "rustup_target" => self.rustup_target,
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
        let subs = Substitutions { rustup_target: Some("x86_64-unknown-linux-gnu"), version: None };
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
}
