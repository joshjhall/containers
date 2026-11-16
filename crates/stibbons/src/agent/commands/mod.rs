//! The seven `stibbons agent` subcommands.
//!
//! Each `run_*` function ports the matching Go `runAgent*` from
//! `cmd/igor/internal/cmd/agent_*.go`. They take an already-resolved
//! [`AgentContext`](super::context::AgentContext), an injected `&dyn DockerRunner`, and a `&mut dyn Write`
//! sink so tests can drive them with a `MockDocker` and a captured buffer — no
//! real Docker or stdout needed.
//!
//! One submodule per subcommand (issue #844, split by subcommand from #832):
//!
//! - [`build`] — `agent build`.
//! - [`lifecycle`] — `agent start` / `stop` / `restart`, plus the embedded
//!   agent scripts `start` mounts into the container.
//! - [`status`] — `agent status`.
//! - [`logs`] — `agent logs`.
//! - [`connect`] — `agent connect`.
//!
//! The `run_*` entry points and their option structs are re-exported here, so
//! callers keep addressing them as `commands::run_*`.

mod build;
mod connect;
mod lifecycle;
mod logs;
mod status;

pub use build::run_build;
pub use connect::{ConnectOptions, run_connect};
pub use lifecycle::{StartOptions, run_restart, run_start, run_stop};
pub use logs::{LogsOptions, run_logs};
pub use status::run_status;

/// Boxed error alias matching the stibbons CLI convention (`main.rs`).
type CmdResult = Result<(), Box<dyn std::error::Error>>;

// --- helpers ---

/// Borrows a `Vec<String>` as `Vec<&str>` for the
/// [`DockerRunner`](super::docker::DockerRunner) argv API.
fn to_refs(args: &[String]) -> Vec<&str> {
    args.iter().map(String::as_str).collect()
}

/// Fixtures shared by the per-subcommand test modules.
#[cfg(test)]
mod test_helpers {
    use containers_common::config::{IgorConfig, ProjectConfig};

    use super::CmdResult;

    /// A base config for a `myproject` with the given features.
    pub(super) fn cfg(features: &[&str]) -> IgorConfig {
        IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig { name: "myproject".into(), ..ProjectConfig::default() },
            features: features.iter().map(ToString::to_string).collect(),
            ..IgorConfig::default()
        }
    }

    /// Runs a closure with the captured output decoded as UTF-8.
    pub(super) fn capture(f: impl FnOnce(&mut Vec<u8>) -> CmdResult) -> (String, CmdResult) {
        let mut buf = Vec::new();
        let res = f(&mut buf);
        (String::from_utf8(buf).unwrap(), res)
    }
}
