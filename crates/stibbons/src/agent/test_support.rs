//! Shared test helpers for the `agent` module's unit tests.

use std::cell::RefCell;
use std::path::Path;

use containers_common::config::IgorConfig;
use tempfile::TempDir;

use super::context::AgentContext;
use super::git::{GitError, GitRunner};

/// Writes `cfg` to a temp `.igor.yml` (with `working_dir` under it so the
/// resolved `base_dir` is the temp root) and loads an [`AgentContext`].
///
/// Returns the [`TempDir`] alongside the context so the caller keeps the
/// directory alive — worktree-existence checks in `status`/`connect` stat paths
/// under `base_dir`.
pub fn load_ctx(mut cfg: IgorConfig) -> (AgentContext, TempDir) {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join(&cfg.project.name);
    std::fs::create_dir_all(&project_dir).unwrap();
    cfg.project.working_dir = Some(project_dir.to_str().unwrap().to_string());
    let cfg_path = tmp.path().join(".igor.yml");
    cfg.save(&cfg_path).unwrap();
    let ctx = AgentContext::load(&cfg_path).unwrap();
    (ctx, tmp)
}

/// Builds an [`AgentContext`] over `repos` rooted at `base_dir`, for the
/// multi-repo tests (which need a context, not just a base dir).
///
/// Shared by the `worktree` and `worktree::sync` test modules (#843): the
/// create/remove and sync multi-repo walks are tested on either side of that
/// module boundary and both need this builder.
#[must_use]
pub fn ctx_with_repos(base_dir: &Path, repos: &[&str]) -> AgentContext {
    use containers_common::config::{AgentConfig, ProjectConfig};

    let mut ctx = AgentContext::from_config(IgorConfig {
        schema_version: 1,
        containers_dir: "containers".into(),
        project: ProjectConfig { name: "myapp".into(), ..ProjectConfig::default() },
        agents: AgentConfig {
            repos: repos.iter().map(ToString::to_string).collect(),
            ..AgentConfig::default()
        },
        ..IgorConfig::default()
    });
    ctx.base_dir = base_dir.to_path_buf();
    ctx
}

/// Recording [`GitRunner`] test double. Records every argv and returns a
/// canned result matched by the first two args, mirroring `MockDocker`.
///
/// Shared by the `worktree` and `worktree::sync` test modules (#843): the sync
/// split put tests needing this double on both sides of a module boundary, so
/// it lives here rather than being duplicated.
#[derive(Default)]
pub struct MockGit {
    calls: RefCell<Vec<Vec<String>>>,
    /// Keyed by the first two args joined (e.g. `"worktree add"`); value is
    /// `Ok`/`Err` plus canned output.
    results: RefCell<std::collections::HashMap<String, Result<String, ()>>>,
}

impl MockGit {
    /// A double with no canned results: every call returns an empty string.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Pin a canned result for calls whose 2nd/3rd argv join to `key`.
    pub fn on(&self, key: &str, result: Result<&str, ()>) {
        self.results.borrow_mut().insert(key.to_string(), result.map(ToString::to_string));
    }

    /// Whether any recorded argv contains `substr`.
    #[must_use]
    pub fn has_call(&self, substr: &str) -> bool {
        self.calls.borrow().iter().any(|c| c.join(" ").contains(substr))
    }
}

impl GitRunner for MockGit {
    fn run(&self, args: &[&str]) -> Result<String, GitError> {
        self.calls.borrow_mut().push(args.iter().map(ToString::to_string).collect());
        // Worktree subcommands land at args[2..] because of the `-C <dir>`
        // prefix; key on the subcommand + verb.
        let key = if args.len() >= 4 {
            format!("{} {}", args[2], args[3])
        } else if args.len() >= 3 {
            format!("{} {}", args[1], args[2])
        } else {
            String::new()
        };
        match self.results.borrow().get(&key) {
            Some(Ok(out)) => Ok(out.clone()),
            Some(Err(())) => {
                Err(GitError::NonZero { args: args.join(" "), output: "mock error".into() })
            }
            None => Ok(String::new()),
        }
    }
}

/// [`GitRunner`] double that fails one git subcommand for one repo only —
/// when the argv contains both `subcommand` and `failing_dir` — succeeding
/// everywhere else, and recording every call.
///
/// [`MockGit`] keys its canned results on the git *subcommand*, not the
/// `-C <dir>` argument, so it cannot express "fail repo A's rebase but not
/// repo B's" — exactly the shape the multi-repo tests need to distinguish
/// sync's attempt-all walk (#712) from create/remove's abort-on-first.
pub struct FailGitIn {
    subcommand: String,
    failing_dir: String,
    calls: RefCell<Vec<String>>,
}

impl FailGitIn {
    /// A double failing `subcommand` only when the argv also names `failing_dir`.
    #[must_use]
    pub fn new(subcommand: &str, failing_dir: &str) -> Self {
        Self {
            subcommand: subcommand.to_string(),
            failing_dir: failing_dir.to_string(),
            calls: RefCell::new(Vec::new()),
        }
    }

    /// Every recorded argv, space-joined.
    #[must_use]
    pub fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }
}

impl GitRunner for FailGitIn {
    fn run(&self, args: &[&str]) -> Result<String, GitError> {
        let joined = args.join(" ");
        self.calls.borrow_mut().push(joined.clone());
        if joined.contains(&self.subcommand) && joined.contains(&self.failing_dir) {
            return Err(GitError::NonZero { args: joined, output: "boom".into() });
        }
        // `sync` resolves a base branch before rebasing; keep it off detached HEAD.
        if joined.contains("rev-parse") {
            return Ok("main".into());
        }
        Ok(String::new())
    }
}
