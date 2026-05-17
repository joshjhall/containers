//! Post-install validation.
//!
//! After running an install method + post-install steps, validate the
//! end-state by invoking `<bin_root>/<tool> --version` and confirming the
//! output contains the target version. Mirrors the bash feature scripts'
//! `<tool> --version | grep -q $VERSION` smoke check.
//!
//! Same scope/limitation as the idempotency check (issue #404 will
//! generalise this via catalog `validation_tiers`).

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

use crate::error::{LuggageError, Result};
use crate::installer::idempotency::primary_binary;

/// Confirm that `tool` reports `version` from `<bin_root>/<binary> --version`,
/// where `binary` is [`primary_binary`] of `tool`.
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
    version: &str,
    bin_root: &Path,
    env: &BTreeMap<String, String>,
) -> Result<String> {
    let binary = bin_root.join(primary_binary(tool));
    if !binary.exists() {
        return Err(LuggageError::ValidationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            message: format!("binary not found at {}", binary.display()),
        });
    }
    let output = Command::new(&binary).arg("--version").envs(env).output().map_err(|e| {
        LuggageError::ValidationFailed {
            tool: tool.to_owned(),
            version: version.to_owned(),
            message: format!("failed to launch `{} --version`: {e}", binary.display()),
        }
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
        let err = check("rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        assert!(matches!(err, LuggageError::ValidationFailed { .. }));
    }

    #[cfg(unix)]
    #[test]
    fn matching_output_passes() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.95.0 (abcdef0)");
        let captured = check("rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap();
        assert_eq!(captured, "rustc 1.95.0 (abcdef0)");
    }

    #[cfg(unix)]
    #[test]
    fn mismatched_output_returns_validation_failed() {
        let dir = tempdir().unwrap();
        write_shim(dir.path(), "rustc", "rustc 1.84.0");
        let err = check("rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
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
    fn propagates_env_to_subprocess() {
        let dir = tempdir().unwrap();
        let shim = dir.path().join("rustc");
        fs::write(&shim, "#!/bin/sh\necho \"rustc $LUGGAGE_TEST_VERSION\"\n").unwrap();
        let mut perms = fs::metadata(&shim).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&shim, perms).unwrap();

        let mut env = BTreeMap::new();
        env.insert("LUGGAGE_TEST_VERSION".to_owned(), "1.95.0".to_owned());

        check("rustc", "1.95.0", dir.path(), &env).unwrap();

        // Negative case: without the env entry, the shim emits `rustc ` and
        // the contains-version assertion must fail.
        let err = check("rustc", "1.95.0", dir.path(), &BTreeMap::new()).unwrap_err();
        assert!(matches!(err, LuggageError::ValidationFailed { .. }));
    }
}
