//! Post-install step execution.
//!
//! Wraps the catalog's [`PostInstall`] enum and turns each variant into a
//! shell invocation under the install user. Mirrors `lib/features/rust.sh`
//! which calls `rustup component add ...` after the toolchain lands.
//!
//! - [`PostInstall::ComponentAdd`] → `rustup component add <component>`
//! - [`PostInstall::Command`] → `<command> <args...>`
//! - [`PostInstall::CargoInstall`] → [`crate::LuggageError::NotImplemented`]
//!   (rust-dev follow-up will wire `cargo install --locked --version`).
//! - [`PostInstall::Unknown`] → [`crate::LuggageError::PostInstallFailed`]

use std::collections::BTreeMap;

use containers_common::tooldb::PostInstall;
use shell_words::quote;

use crate::error::{LuggageError, Result};
use crate::installer::methods::CommandRunner;
use crate::installer::user::su_command;

/// Execute every step in `steps` in order.
///
/// `env` is exported in front of every step so each `rustup` invocation
/// sees the same `CARGO_HOME` / `RUSTUP_HOME` the install method used.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] for a `CargoInstall` variant.
/// - [`LuggageError::PostInstallFailed`] for `Unknown` variants and for
///   any step whose runner returned a non-zero exit status.
pub fn run_steps(
    steps: &[PostInstall],
    user: &str,
    env: &BTreeMap<String, String>,
    runner: &dyn CommandRunner,
) -> Result<()> {
    for step in steps {
        run_one(step, user, env, runner)?;
    }
    Ok(())
}

fn run_one(
    step: &PostInstall,
    user: &str,
    env: &BTreeMap<String, String>,
    runner: &dyn CommandRunner,
) -> Result<()> {
    let (step_id, body) = match step {
        PostInstall::ComponentAdd { component } => (
            format!("component_add:{component}"),
            format!("rustup component add {}", quote(component)),
        ),
        PostInstall::Command { command, args } => {
            let mut body = quote(command).into_owned();
            if let Some(args) = args {
                for a in args {
                    body.push(' ');
                    body.push_str(&quote(a));
                }
            }
            (format!("command:{command}"), body)
        }
        PostInstall::CargoInstall { package, version: _ } => {
            return Err(LuggageError::NotImplemented(
                "PostInstall::CargoInstall (rust-dev follow-up; needs --locked + --version pin)",
            ))
            .inspect_err(|_| {
                // Carry the package name into the trace for a slightly
                // friendlier diagnostic when the rust-dev migration runs.
                tracing::warn!(package = %package, "deferring CargoInstall to follow-up issue");
            });
        }
        PostInstall::Unknown => {
            return Err(LuggageError::PostInstallFailed {
                step: "unknown".into(),
                message: "unrecognized post_install variant in catalog".into(),
            });
        }
    };

    let argv = su_command(user, env, &body);
    let outcome = runner.run(&argv[0], &argv[1..])?;
    if outcome.success() {
        Ok(())
    } else {
        Err(LuggageError::PostInstallFailed {
            step: step_id,
            message: format!(
                "exit {:?}: {}",
                outcome.status,
                String::from_utf8_lossy(&outcome.stderr).trim_end(),
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::installer::methods::{CommandOutcome, RecordingRunner};

    #[test]
    fn component_add_invokes_rustup_under_su() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        run_steps(
            &[PostInstall::ComponentAdd { component: "rust-src".into() }],
            "vscode",
            &env,
            &runner,
        )
        .unwrap();
        let calls = runner.calls();
        assert_eq!(calls.len(), 1);
        let (prog, args) = &calls[0];
        assert_eq!(prog, "su");
        assert_eq!(args[..3], ["-".to_owned(), "vscode".into(), "-c".into()]);
        assert!(args[3].contains("rustup component add rust-src"));
    }

    #[test]
    fn command_step_quotes_and_invokes() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        run_steps(
            &[PostInstall::Command { command: "echo".into(), args: Some(vec!["hi there".into()]) }],
            "vscode",
            &env,
            &runner,
        )
        .unwrap();
        let calls = runner.calls();
        let payload = &calls[0].1[3];
        assert!(payload.contains("echo"));
        assert!(payload.contains("'hi there'"));
    }

    #[test]
    fn cargo_install_returns_not_implemented() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let err = run_steps(
            &[PostInstall::CargoInstall { package: "ripgrep".into(), version: "14.0.0".into() }],
            "vscode",
            &env,
            &runner,
        )
        .unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn unknown_variant_returns_post_install_failed() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        let err = run_steps(&[PostInstall::Unknown], "vscode", &env, &runner).unwrap_err();
        assert!(matches!(err, LuggageError::PostInstallFailed { .. }));
    }

    #[test]
    fn nonzero_exit_maps_to_post_install_failed() {
        let runner = RecordingRunner::new();
        runner.set_outcome(
            "su",
            CommandOutcome { status: Some(2), stdout: vec![], stderr: b"oops".to_vec() },
        );
        let env = BTreeMap::new();
        let err = run_steps(
            &[PostInstall::ComponentAdd { component: "rust-src".into() }],
            "vscode",
            &env,
            &runner,
        )
        .unwrap_err();
        match err {
            LuggageError::PostInstallFailed { step, message } => {
                assert_eq!(step, "component_add:rust-src");
                assert!(message.contains("oops"));
            }
            other => panic!("expected PostInstallFailed, got {other:?}"),
        }
    }

    #[test]
    fn empty_steps_is_a_noop() {
        let runner = RecordingRunner::new();
        let env = BTreeMap::new();
        run_steps(&[], "vscode", &env, &runner).unwrap();
        assert!(runner.calls().is_empty());
    }
}
