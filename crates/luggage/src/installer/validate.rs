//! Post-install validation.
//!
//! After running an install method + post-install steps, validate the
//! end-state by invoking `<bin_root>/<binary> --version` and confirming the
//! output contains the target version. Mirrors the bash feature scripts'
//! `<tool> --version | grep -q $VERSION` smoke check.

use std::collections::BTreeMap;
use std::path::Path;

use crate::error::{LuggageError, Result};
use crate::installer::idempotency::run_version_check;

/// Confirm that `tool` reports `version` from `<bin_root>/<binary> --version`.
///
/// `binary` is the catalog-resolved
/// [`crate::ResolvedInstall::primary_binary`]; `tool` is carried separately
/// because it names the tool in the error variants, and the two differ
/// whenever a tool's binary is not its catalog id (rust → `rustc`).
///
/// `env` is layered on top of the inherited process environment with
/// [`Command::envs`]. For rustup-proxy binaries this must include
/// `CARGO_HOME` / `RUSTUP_HOME`; otherwise the proxy falls back to
/// `$HOME/.rustup` and reports "no default toolchain configured" even when
/// the toolchain was just installed under `cache_root`.
///
/// Returns the trimmed captured output from the version invocation
/// (stdout preferred, stderr if stdout is empty), so callers can surface
/// it through evidence reports.
///
/// # Errors
///
/// - [`LuggageError::ValidationFailed`] when the binary is missing, the
///   command fails to launch, the exit status is non-zero, or the output
///   doesn't mention the target version.
pub fn check(
    tool: &str,
    binary: &str,
    version: &str,
    bin_root: &Path,
    env: &BTreeMap<String, String>,
) -> Result<String> {
    let binary = bin_root.join(binary);
    if !binary.exists() {
        return Err(LuggageError::ValidationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            message: format!("binary not found at {}", binary.display()),
        });
    }
    // Retries a transient ETXTBSY before surfacing a launch failure; see
    // [`run_version_check`] for why exec-after-write can race under
    // parallelism (issue #518).
    let output = run_version_check(&binary, env).map_err(|e| LuggageError::ValidationFailed {
        tool: tool.to_owned(),
        version: version.to_owned(),
        message: format!("failed to launch `{} --version`: {e}", binary.display()),
    })?;
    if !output.status.success() {
        return Err(LuggageError::ValidationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            message: format!(
                "`{} --version` exited {}: {}",
                binary.display(),
                output.status,
                String::from_utf8_lossy(&output.stderr).trim_end(),
            ),
        });
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if stdout.contains(version) || stderr.contains(version) {
        let trimmed = stdout.trim();
        let captured =
            if trimmed.is_empty() { stderr.trim().to_owned() } else { trimmed.to_owned() };
        Ok(captured)
    } else {
        Err(LuggageError::ValidationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            message: format!("expected version `{version}` in output, got: {}", stdout.trim_end()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt as _;

    use tempfile::tempdir;

    #[cfg(unix)]
    fn write_shim(dir: &Path, name: &str, line: &str) {
        let path = dir.join(name);
        fs::write(&path, format!("#!/bin/sh\necho '{line}'\n")).unwrap();
        let mut perms = fs::metadata(&path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).unwrap();
    }

    #[test]
    fn missing_binary_returns_validation_failed() {
        let dir = tempdir().unwrap();
        let err = check("rust", "rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        assert!(matches!(err, LuggageError::ValidationFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn matching_output_passes() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        let captured = check("rust", "rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap();
        assert_eq!(captured, "rustc 1.95.0 (abcdef0)");
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn mismatched_output_returns_validation_failed() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.84.0");
        let err = check("rust", "rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        match err {
            LuggageError::ValidationFailed { message, .. } => {
                assert!(message.contains("1.95.0"));
            }
            other => panic!("expected ValidationFailed, got {other:?}"),
        }
    }

    /// Regression test for issue #463: validate must propagate the env map
    /// to the child process so the rustup proxy can find the toolchain
    /// under `CARGO_HOME` / `RUSTUP_HOME` regardless of what the caller
    /// exported.
    ///
    /// The shim echoes `rustc $LUGGAGE_TEST_VERSION` — when the env map is
    /// propagated, the substituted value matches the version the check is
    /// looking for; without propagation the variable expands to empty and
    /// the version-contains assertion fails.
    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn propagates_env_to_subprocess() {
        let dir = tempdir().unwrap();
        let shim = dir.path().join("rustc");
        fs::write(&shim, "#!/bin/sh\necho \"rustc $LUGGAGE_TEST_VERSION\"\n").unwrap();
        let mut perms = fs::metadata(&shim).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&shim, perms).unwrap();

        let mut env = BTreeMap::new();
        env.insert("LUGGAGE_TEST_VERSION".to_owned(), "1.95.0".to_owned());

        check("rust", "rustc", "1.95.0", dir.path(), &env).unwrap();

        // Negative case: without the env entry, the shim emits `rustc ` and
        // the contains-version assertion must fail.
        let err = check("rust", "rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        assert!(matches!(err, LuggageError::ValidationFailed { .. }));
    }

    /// `tool` and `binary` are distinct arguments (#806): the probed path is
    /// built from `binary`, while the error payload names `tool`. Conflating
    /// them is exactly what the deleted `match tool` table did, so pin both
    /// halves — the message must point at `<bin_root>/python3` while the
    /// `tool` field still reads `python`.
    #[test]
    fn error_names_the_tool_but_the_path_uses_the_binary() {
        let dir = tempdir().unwrap();
        let err = check("python", "python3", "3.13.0", dir.path(), &BTreeMap::new()).unwrap_err();
        match err {
            LuggageError::ValidationFailed { tool, version, message } => {
                assert_eq!(tool, "python", "the error identifies the tool");
                assert_eq!(version, "3.13.0");
                assert!(
                    message.contains("python3"),
                    "the probed path must use the binary name, got: {message}",
                );
            }
            other => panic!("expected ValidationFailed, got {other:?}"),
        }
    }

    /// When `run_version_check` exhausts its `ETXTBSY` budget and returns an
    /// I/O error, `check` must fold it into `ValidationFailed` via the
    /// `map_err` on the launch call — the "failed to launch" branch, which is
    /// otherwise unreachable in serialized tests (they never produce a
    /// concurrent fork). Holding an open write fd forces `ETXTBSY` on every
    /// exec deterministically, so the retry budget is guaranteed to exhaust
    /// and surface the error rather than a non-zero exit or version mismatch.
    ///
    /// Linux-only: only Linux returns `ETXTBSY` while a writable fd is held
    /// (macOS/Darwin execs the binary anyway), so this deterministic
    /// induction can't run elsewhere.
    #[cfg(target_os = "linux")]
    #[test]
    #[serial_test::serial]
    fn etxtbsy_exhaustion_maps_to_validation_failed() {
        use std::fs::OpenOptions;

        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (never runs)");
        let _writer = OpenOptions::new().write(true).open(dir.path().join("rustc")).unwrap();

        let err = check("rust", "rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        match err {
            LuggageError::ValidationFailed { tool, version, message } => {
                // The error names the TOOL (`rust`), not the binary it probed
                // (`rustc`) — the two are separate arguments since #806.
                assert_eq!(tool, "rust");
                assert_eq!(version, "1.95.0");
                assert!(
                    message.contains("failed to launch"),
                    "exhaustion must surface via the launch-failure branch, got: {message}",
                );
            }
            other => panic!("expected ValidationFailed, got {other:?}"),
        }
    }
}
