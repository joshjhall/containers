//! Docker CLI abstraction.
//!
//! The [`DockerRunner`] trait wraps the `docker` command line so agent commands
//! can be unit-tested without a real Docker daemon (issue #310's "`DockerRunner`
//! trait for testability"). It mirrors the sibling `CommandRunner` pattern in
//! luggage (`crates/luggage/src/installer/methods/mod.rs`): a production impl
//! that shells out, and a recording test double.
//!
//! Two call shapes are needed, matching the retired Go `DockerRunner`:
//!
//! - [`DockerRunner::run`] captures combined stdout+stderr (trimmed) for
//!   commands whose output is inspected — `docker inspect`, `docker run -d`,
//!   `psql -tc …`.
//! - [`DockerRunner::passthrough`] inherits the parent stdio for streaming or
//!   interactive commands — `docker logs -f`, `docker exec -it … bash` — where
//!   capturing output would break the stream or the TTY.

use std::process::{Command, Stdio};

/// Error from invoking the `docker` binary itself (spawn failure or a non-zero
/// exit from a captured [`DockerRunner::run`] call).
#[derive(Debug, thiserror::Error)]
pub enum DockerError {
    /// The `docker` process could not be spawned (e.g. binary not on `PATH`).
    #[error("failed to run docker: {0}")]
    Spawn(#[source] std::io::Error),

    /// `docker` ran but exited non-zero. Carries the trimmed combined output so
    /// callers can surface the daemon's own message.
    #[error("docker {args} failed: {output}")]
    NonZero {
        /// The argv that failed, space-joined, for the message.
        args: String,
        /// Trimmed combined stdout+stderr from the failed invocation.
        output: String,
    },
}

/// Abstracts the `docker` CLI so agent commands are testable without a daemon.
pub trait DockerRunner {
    /// Runs `docker <args>` and returns the trimmed combined stdout+stderr.
    ///
    /// # Errors
    ///
    /// Returns [`DockerError::Spawn`] if the process cannot start, or
    /// [`DockerError::NonZero`] if `docker` exits non-zero.
    fn run(&self, args: &[&str]) -> Result<String, DockerError>;

    /// Runs `docker <args>` with the parent's stdin/stdout/stderr attached, for
    /// streaming (`logs -f`) or interactive (`exec -it … bash`) commands.
    ///
    /// # Errors
    ///
    /// Returns [`DockerError::Spawn`] if the process cannot start, or
    /// [`DockerError::NonZero`] if `docker` exits non-zero.
    fn passthrough(&self, args: &[&str]) -> Result<(), DockerError>;
}

/// Production [`DockerRunner`] backed by `std::process::Command`.
#[derive(Debug, Default, Clone, Copy)]
pub struct ProcessDockerRunner;

impl DockerRunner for ProcessDockerRunner {
    fn run(&self, args: &[&str]) -> Result<String, DockerError> {
        let output = Command::new("docker").args(args).output().map_err(DockerError::Spawn)?;

        // Combine stdout+stderr like Go's `CombinedOutput`, then trim. Ordering
        // (stdout then stderr) is not meaningful to any caller — they match on
        // substrings ("true", "1") or surface the whole blob on error.
        let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
        combined.push_str(&String::from_utf8_lossy(&output.stderr));
        let combined = combined.trim().to_string();

        if output.status.success() {
            Ok(combined)
        } else {
            Err(DockerError::NonZero { args: args.join(" "), output: combined })
        }
    }

    fn passthrough(&self, args: &[&str]) -> Result<(), DockerError> {
        let status = Command::new("docker")
            .args(args)
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit())
            .status()
            .map_err(DockerError::Spawn)?;

        if status.success() {
            Ok(())
        } else {
            Err(DockerError::NonZero { args: args.join(" "), output: String::new() })
        }
    }
}

#[cfg(test)]
pub use mock::{MockDocker, MockResult};

#[cfg(test)]
mod mock {
    use std::cell::RefCell;
    use std::collections::HashMap;

    use super::{DockerError, DockerRunner};

    /// A pre-configured response for a matched `docker` invocation.
    #[derive(Clone)]
    pub struct MockResult {
        pub output: String,
        pub ok: bool,
    }

    impl MockResult {
        pub fn ok(output: &str) -> Self {
            Self { output: output.to_string(), ok: true }
        }

        pub fn err() -> Self {
            Self { output: String::new(), ok: false }
        }
    }

    /// Records every docker call and returns configurable responses, porting Go's
    /// `mockDocker`. Response resolution order for [`run`](DockerRunner::run):
    ///
    /// 1. a `run_fn` closure override, if set (full control for stateful tests);
    /// 2. `match_results` keyed by the first two args (`"inspect -f"`) then the
    ///    first arg alone (`"logs"`);
    /// 3. a sequential `results` queue;
    /// 4. default success with empty output.
    ///
    /// Interior mutability ([`RefCell`]) lets the mock be shared as `&dyn
    /// DockerRunner` while still recording calls — the runner is single-threaded
    /// in tests.
    #[derive(Default)]
    pub struct MockDocker {
        pub calls: RefCell<Vec<Vec<String>>>,
        pub results: RefCell<Vec<MockResult>>,
        pub match_results: RefCell<HashMap<String, MockResult>>,
        #[expect(clippy::type_complexity)]
        pub run_fn: RefCell<Option<Box<dyn Fn(&[&str]) -> MockResult>>>,
    }

    impl MockDocker {
        pub fn new() -> Self {
            Self::default()
        }

        /// Pins a canned result for a docker invocation matched by key.
        pub fn on(&self, key: &str, result: MockResult) {
            self.match_results.borrow_mut().insert(key.to_string(), result);
        }

        /// Installs a stateful override for full control over `run`.
        pub fn set_run_fn(&self, f: impl Fn(&[&str]) -> MockResult + 'static) {
            *self.run_fn.borrow_mut() = Some(Box::new(f));
        }

        pub fn call_count(&self) -> usize {
            self.calls.borrow().len()
        }

        /// True when any recorded call, space-joined, contains `substr` — Go's
        /// `hasCall`.
        pub fn has_call(&self, substr: &str) -> bool {
            self.calls.borrow().iter().any(|c| c.join(" ").contains(substr))
        }

        fn resolve(&self, args: &[&str]) -> MockResult {
            if let Some(f) = self.run_fn.borrow().as_ref() {
                return f(args);
            }
            let matches = self.match_results.borrow();
            if args.len() >= 2 {
                let key = format!("{} {}", args[0], args[1]);
                if let Some(r) = matches.get(&key) {
                    return r.clone();
                }
            }
            if let Some(first) = args.first()
                && let Some(r) = matches.get(*first)
            {
                return r.clone();
            }
            drop(matches);
            let mut results = self.results.borrow_mut();
            if results.is_empty() { MockResult::ok("") } else { results.remove(0) }
        }
    }

    impl DockerRunner for MockDocker {
        fn run(&self, args: &[&str]) -> Result<String, DockerError> {
            self.calls.borrow_mut().push(args.iter().map(ToString::to_string).collect());
            let result = self.resolve(args);
            if result.ok {
                Ok(result.output)
            } else {
                Err(DockerError::NonZero { args: args.join(" "), output: result.output })
            }
        }

        fn passthrough(&self, args: &[&str]) -> Result<(), DockerError> {
            self.calls.borrow_mut().push(args.iter().map(ToString::to_string).collect());
            Ok(())
        }
    }
}
