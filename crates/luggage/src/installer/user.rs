//! Resolve the target install user and build `su -c` invocations.
//!
//! Container builds run as root but rust toolchains live under
//! `$USERNAME` so cargo's per-user state ends up in the right place.
//! `lib/features/rust.sh` uses `su - "${USERNAME}" -c "..."`. This module
//! reproduces that pattern in Rust.
//!
//! The username is read from `$USERNAME` (set by the Dockerfile) with a
//! `vscode` fallback that matches the default user across the build matrix.

use std::collections::BTreeMap;
use std::env;
use std::fmt::Write as _;

use shell_words::quote;

/// Default install user when `$USERNAME` is unset. Matches the Dockerfile
/// default and the user `lib/features/rust.sh` falls back to.
pub const DEFAULT_USERNAME: &str = "vscode";

/// Pick the install user from an explicit override or `$USERNAME`.
///
/// `override_value` (typically a `--user` CLI flag) wins when set. With no
/// override, we read the live `$USERNAME` and fall back to
/// [`DEFAULT_USERNAME`] when unset or empty. Threaded through the
/// installer rather than read inside it so test fixtures can pin a value
/// without mutating process env (which would conflict with the workspace's
/// `unsafe_code = "forbid"`).
#[must_use]
pub fn resolve_user(override_value: Option<&str>) -> String {
    if let Some(s) = override_value
        && !s.is_empty()
    {
        return s.to_owned();
    }
    env::var("USERNAME")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_USERNAME.to_owned())
}

/// Build a `su - <user> -c "<payload>"` argv.
///
/// `env` entries are emitted as `export KEY=<quoted-value>` lines before
/// the body so the spawned shell sees them. `body` is inserted verbatim;
/// callers must already have shell-quoted arguments inside it.
#[must_use]
pub fn su_command(user: &str, env: &BTreeMap<String, String>, body: &str) -> Vec<String> {
    let mut payload = String::new();
    for (k, v) in env {
        let _ = write!(payload, "export {k}={}; ", quote(v));
    }
    payload.push_str(body);
    vec!["su".into(), "-".into(), user.into(), "-c".into(), payload]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn override_wins_when_set() {
        assert_eq!(resolve_user(Some("alice")), "alice");
    }

    #[test]
    fn empty_override_falls_back_to_env_or_default() {
        // We can't mutate $USERNAME here (workspace forbids unsafe), so
        // both outcomes — env-set or default — are accepted. The contract
        // is "non-empty result"; the value depends on whether the test
        // harness inherited a USERNAME from the parent shell.
        let r = resolve_user(Some(""));
        assert!(!r.is_empty());
    }

    #[test]
    fn no_override_returns_non_empty_string() {
        let r = resolve_user(None);
        assert!(!r.is_empty());
    }

    #[test]
    fn su_command_emits_user_and_payload() {
        let argv = su_command("vscode", &BTreeMap::new(), "echo hi");
        assert_eq!(argv, vec!["su", "-", "vscode", "-c", "echo hi"]);
    }

    #[test]
    fn su_command_exports_env_in_sorted_order() {
        let mut env = BTreeMap::new();
        env.insert("CARGO_HOME".to_owned(), "/cache/cargo".to_owned());
        env.insert("RUSTUP_HOME".to_owned(), "/cache/rustup".to_owned());
        let argv = su_command("vscode", &env, "rustup-init -y");
        let payload = &argv[4];
        // BTreeMap iterates in sorted order — CARGO_HOME comes before RUSTUP_HOME.
        let cargo_idx = payload.find("CARGO_HOME").unwrap();
        let rustup_idx = payload.find("RUSTUP_HOME").unwrap();
        assert!(cargo_idx < rustup_idx);
        assert!(payload.contains("export CARGO_HOME=/cache/cargo"));
        assert!(payload.contains("export RUSTUP_HOME=/cache/rustup"));
        assert!(payload.contains("rustup-init -y"));
    }

    #[test]
    fn su_command_quotes_env_values_with_spaces() {
        let mut env = BTreeMap::new();
        env.insert("WEIRD".to_owned(), "value with spaces".to_owned());
        let argv = su_command("vscode", &env, "true");
        assert!(argv[4].contains("'value with spaces'"));
    }
}
