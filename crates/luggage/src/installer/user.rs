//! Resolve the target install user and build `su -c` invocations.
//!
//! Container builds run as root but rust toolchains live under
//! `$USERNAME` so cargo's per-user state ends up in the right place.
//! `lib/features/rust.sh` uses `su - "${USERNAME}" -c "..."`. This module
//! reproduces that pattern in Rust.
//!
//! The username is read from `$USERNAME` (set by the Dockerfile) with a
//! `vscode` fallback that matches the default user across the build matrix.
//! When the resolved user doesn't actually exist on the system — e.g. a
//! hardened base image whose `$USERNAME` is unset and that ships no `vscode`
//! user (see issue #492) — [`resolve_install_user`] falls back to `root`, the
//! uid the install already runs as. The caller treats a `root` install user
//! as the signal to skip the cache-dir `chown` (root already owns the
//! freshly-created paths).

use std::collections::BTreeMap;
use std::env;
use std::fmt::Write as _;
use std::path::Path;

use shell_words::quote;

/// Default install user when `$USERNAME` is unset. Matches the Dockerfile
/// default and the user `lib/features/rust.sh` falls back to.
pub const DEFAULT_USERNAME: &str = "vscode";

/// The root user — used as the last-resort install user when the resolved
/// user doesn't exist, and as the sentinel the install method checks to skip
/// the ownership `chown`.
pub const ROOT_USER: &str = "root";

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

/// Resolve the install user, falling back to [`ROOT_USER`] when the user
/// [`resolve_user`] picks doesn't exist on the system.
///
/// Layered on top of [`resolve_user`]: that function answers "what name did
/// the override / `$USERNAME` / default ask for"; this one answers "what user
/// can we actually `chown`/`su` to". On a hardened base image where neither a
/// `--user` override nor `$USERNAME` names a real user (issue #492), the bare
/// name resolution returns `vscode`, which doesn't exist and would fail the
/// `chown`/`su` mid-pipeline. Falling back to `root` — the uid the install
/// already runs as — keeps the install correct without per-image plumbing.
#[must_use]
pub fn resolve_install_user(override_value: Option<&str>) -> String {
    let user = resolve_user(override_value);
    if user_exists(&user) { user } else { ROOT_USER.to_owned() }
}

/// Check whether `user` exists on the system by scanning `/etc/passwd`.
///
/// [`ROOT_USER`] short-circuits to `true` (uid 0 always exists). A failure to
/// read `/etc/passwd` returns `false`, which steers callers to the safe
/// `root` fallback rather than attempting a `chown`/`su` that would fail.
#[must_use]
pub fn user_exists(user: &str) -> bool {
    if user == ROOT_USER {
        return true;
    }
    std::fs::read_to_string("/etc/passwd").is_ok_and(|passwd| passwd_has_user(&passwd, user))
}

/// True iff `passwd` (the contents of an `/etc/passwd`-format file) has a line
/// whose first colon-delimited field equals `user`.
///
/// Split out from [`user_exists`] so the line-matching logic is unit-testable
/// without touching the host's real `/etc/passwd`.
fn passwd_has_user(passwd: &str, user: &str) -> bool {
    passwd.lines().any(|line| line.split(':').next() == Some(user))
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

/// Build a `chown -R <user>:<user> <path>` argv.
///
/// Used after `create_dir_all` in the root process to transfer ownership
/// of freshly-created directory trees to the install user, so the
/// subsequent `su - <user> -c "..."` child can write into them without
/// hitting permission-denied on the first write. The colon form sets
/// group ownership too; the production user-creation step gives the
/// install user a matching login group.
#[must_use]
pub fn chown_command(user: &str, path: &Path) -> Vec<String> {
    vec!["chown".into(), "-R".into(), format!("{user}:{user}"), path.display().to_string()]
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

    #[test]
    fn chown_command_builds_recursive_user_group_argv() {
        let argv = chown_command("vscode", Path::new("/cache/cargo"));
        assert_eq!(argv, vec!["chown", "-R", "vscode:vscode", "/cache/cargo"]);
    }

    const PASSWD_SAMPLE: &str = "root:x:0:0:root:/root:/bin/bash\n\
                                 vscode:x:1000:1000::/home/vscode:/bin/bash\n";

    #[test]
    fn passwd_has_user_matches_exact_first_field() {
        assert!(passwd_has_user(PASSWD_SAMPLE, "root"));
        assert!(passwd_has_user(PASSWD_SAMPLE, "vscode"));
    }

    #[test]
    fn passwd_has_user_rejects_missing_and_partial_names() {
        assert!(!passwd_has_user(PASSWD_SAMPLE, "runner"));
        // A prefix of a real user must not match the colon-delimited field.
        assert!(!passwd_has_user(PASSWD_SAMPLE, "vsc"));
        // A substring of a later field (uid/home) must not match either.
        assert!(!passwd_has_user(PASSWD_SAMPLE, "1000"));
    }

    #[test]
    fn user_exists_short_circuits_root() {
        // root must report present even if /etc/passwd can't be read.
        assert!(user_exists(ROOT_USER));
    }

    #[test]
    fn resolve_install_user_falls_back_to_root_for_unknown_user() {
        // This name cannot exist on any host, so the result is deterministic.
        assert_eq!(resolve_install_user(Some("zzz-nonexistent-user-492")), ROOT_USER);
    }

    #[test]
    fn resolve_install_user_keeps_root_override() {
        assert_eq!(resolve_install_user(Some("root")), ROOT_USER);
    }
}
