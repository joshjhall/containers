//! Idempotency pre-check: skip install when the tool is already at the
//! target version.
//!
//! For the rust pilot the convention is "`<bin_root>/<tool> --version`
//! contains `<version>`" — exactly what bash's `lib/features/rust.sh` does
//! with `command -v rustc && rustc --version | grep -q "$RUST_VERSION"`.
//!
//! When the catalog tool id and its primary binary name differ (e.g.
//! `rust` → `rustc`), [`primary_binary`] keeps a small in-code mapping.
//! This is a stopgap; a future catalog field (issue #404) will declare a
//! per-tool version-check command so each tool can decide what "already
//! installed" means.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::{Command, Output};
use std::thread;
use std::time::Duration;

/// `errno` for `ETXTBSY` ("text file busy"), returned by `exec` when another
/// thread in this process briefly holds a writable fd to the binary across a
/// concurrent `fork`/`exec`. Transient, not "binary absent". See issue #518.
const ETXTBSY: i32 = 26;

/// Bounded retry budget for the `--version` exec when it hits `ETXTBSY`, and
/// the backoff between attempts.
const ETXTBSY_RETRIES: u32 = 3;
const ETXTBSY_BACKOFF: Duration = Duration::from_millis(50);

/// Run `<binary> --version` with `env` layered on the inherited environment,
/// retrying on a transient `ETXTBSY`.
///
/// Writing an executable and immediately `exec`ing it races with any
/// concurrent `fork` in the same process: the child momentarily inherits a
/// writable fd to the file, so the `exec` fails with `ETXTBSY` until that fd
/// closes. Collapsing that transient into "not installed"/failure is the root
/// cause of the flaky `install_rust` tests (issue #518) and could equally
/// misfire in real igor flows that write a binary then version-check it. We
/// retry a bounded number of times with a short backoff; every other I/O
/// error (and every success) is returned to the caller on the first
/// occurrence.
pub(crate) fn run_version_check(
    binary: &Path,
    env: &BTreeMap<String, String>,
) -> std::io::Result<Output> {
    let mut attempt = 0;
    loop {
        match Command::new(binary).arg("--version").envs(env).output() {
            Err(e) if e.raw_os_error() == Some(ETXTBSY) && attempt < ETXTBSY_RETRIES => {
                attempt += 1;
                thread::sleep(ETXTBSY_BACKOFF);
            }
            other => return other,
        }
    }
}

/// Map a catalog tool id to the primary binary name luggage should
/// `--version`-check. Defaults to the tool id itself when no mapping
/// exists. Stopgap until catalog `validation_tiers` lands (issue #404).
#[must_use]
pub fn primary_binary(tool: &str) -> &str {
    match tool {
        "rust" => "rustc",
        _ => tool,
    }
}

/// Check whether `tool` at `version` is already on disk under `bin_root`.
///
/// Returns `false` for any reason it can't confirm — missing binary,
/// non-zero exit, output without the version literal, I/O error. The
/// caller must treat `false` as "go install"; only `true` should skip.
#[must_use]
pub fn already_installed(tool: &str, version: &str, bin_root: &Path) -> bool {
    let binary = bin_root.join(primary_binary(tool));
    if !binary.exists() {
        return false;
    }
    // Retries a transient ETXTBSY; any other launch error still means "can't
    // confirm → go install" per the contract above.
    let Ok(output) = run_version_check(&binary, &BTreeMap::new()) else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    stdout.contains(version) || stderr.contains(version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

    #[cfg(unix)]
    fn write_shim(dir: &Path, name: &str, version_line: &str) {
        write_shim_to(dir, name, version_line, false);
    }

    /// Write an executable shim printing `version_line` to stdout (or stderr
    /// when `to_stderr`). The line is single-quote-escaped so version strings
    /// containing an apostrophe can't break the surrounding shell quoting.
    #[cfg(unix)]
    fn write_shim_to(dir: &Path, name: &str, version_line: &str, to_stderr: bool) {
        let path = dir.join(name);
        let escaped = version_line.replace('\'', "'\\''");
        let redirect = if to_stderr { " >&2" } else { "" };
        fs::write(&path, format!("#!/bin/sh\necho '{escaped}'{redirect}\n")).unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
    }

    #[test]
    fn missing_binary_returns_false() {
        let dir = tempdir().unwrap();
        assert!(!already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn matching_version_returns_true() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        assert!(already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn stderr_version_returns_true() {
        // Some tools print `--version` to stderr; `already_installed` must
        // match the version there too, not only on stdout.
        let dir = tempdir().unwrap();
        write_shim_to(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)", true);
        assert!(already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn version_with_apostrophe_does_not_break_shim() {
        // Guards the shim helper's quote-escaping: a version literal with an
        // apostrophe must still be emitted verbatim and matched.
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 o'brien");
        assert!(already_installed("rustc", "o'brien", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn nonzero_exit_returns_false() {
        // A binary that runs and even prints the matching version but exits
        // non-zero can't confirm an install — the contract says return false.
        let dir = tempdir().unwrap();
        let path = dir.path().join("rustc");
        fs::write(&path, "#!/bin/sh\necho 'rustc 1.95.0'\nexit 1\n").unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
        assert!(
            !already_installed("rustc", "1.95.0", dir.path()),
            "non-zero exit must return false even if the version appears in output",
        );
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn exec_error_returns_false() {
        // The binary exists (passes the `.exists()` guard) but can't be
        // exec'd — a launch error must resolve to "can't confirm → false".
        let dir = tempdir().unwrap();
        let path = dir.path().join("rustc");
        fs::write(&path, b"not executable").unwrap();
        // Mode 000: present on disk but not executable.
        fs::set_permissions(&path, fs::Permissions::from_mode(0o000)).unwrap();
        assert!(!already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn nonmatching_version_returns_false() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.84.0 (abcdef0)");
        assert!(!already_installed("rustc", "1.95.0", dir.path()));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn rust_tool_id_resolves_to_rustc_binary() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        assert!(
            already_installed("rust", "1.95.0", dir.path()),
            "catalog tool id `rust` should map to `rustc` binary",
        );
    }

    #[test]
    fn primary_binary_defaults_to_tool_id() {
        assert_eq!(primary_binary("node"), "node");
        assert_eq!(primary_binary("rust"), "rustc");
    }

    /// Exhaustion counterpart to the `install_rust` regression test, which only
    /// covers success-after-retry. Holding an open write fd to the binary makes
    /// every `exec` fail with `ETXTBSY`, so `run_version_check` burns the whole
    /// `ETXTBSY_RETRIES` budget and then propagates the error via `other =>
    /// return other` instead of dropping it — the path that was previously
    /// untested. The held fd guarantees the failure deterministically (no
    /// cross-thread fork race needed), and the `>= ETXTBSY_RETRIES` sleep floor
    /// proves the retry loop actually ran to exhaustion rather than returning
    /// early.
    ///
    /// Linux-only: the "open-for-write ⇒ `exec` fails with `ETXTBSY`" guarantee
    /// is a Linux kernel behavior. macOS/Darwin does *not* return `ETXTBSY`
    /// while a writable fd is held, so this deterministic-induction technique
    /// can't run there — the production retry logic it guards is itself
    /// exercised end-to-end by the parallel regression tests in `install_rust`,
    /// which do run on every unix.
    #[cfg(target_os = "linux")]
    #[test]
    #[serial_test::serial]
    fn run_version_check_propagates_etxtbsy_after_exhausting_retries() {
        use std::fs::OpenOptions;
        use std::time::Instant;

        let dir = tempdir().unwrap();
        let binary = dir.path().join("rustc");
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (never runs)");

        // A writable fd open across the exec keeps the kernel returning ETXTBSY
        // for the lifetime of `_writer`; drop only happens at end of scope.
        let _writer = OpenOptions::new().write(true).open(&binary).unwrap();

        let start = Instant::now();
        let result = run_version_check(&binary, &BTreeMap::new());
        let elapsed = start.elapsed();

        let err = result.expect_err("held write fd must force ETXTBSY exhaustion");
        assert_eq!(
            err.raw_os_error(),
            Some(ETXTBSY),
            "exhaustion must propagate the ETXTBSY error, not remap it",
        );
        assert!(
            elapsed >= ETXTBSY_BACKOFF * ETXTBSY_RETRIES,
            "should back off once per retry before giving up (elapsed {elapsed:?})",
        );
    }

    /// The public `already_installed` wrapper must fold that same exhaustion
    /// into its "can't confirm → false" contract rather than surfacing the
    /// error, so the caller still treats the tool as "go install".
    ///
    /// Linux-only for the same reason as the exhaustion test above: the held
    /// write fd only forces `ETXTBSY` on Linux.
    #[cfg(target_os = "linux")]
    #[test]
    #[serial_test::serial]
    fn already_installed_returns_false_when_etxtbsy_never_clears() {
        use std::fs::OpenOptions;

        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (never runs)");
        let _writer = OpenOptions::new().write(true).open(dir.path().join("rustc")).unwrap();

        assert!(
            !already_installed("rust", "1.95.0", dir.path()),
            "persistent ETXTBSY must resolve to false, not a spurious true",
        );
    }
}
