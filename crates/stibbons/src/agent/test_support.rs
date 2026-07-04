//! Shared test helpers for the `agent` module's unit tests.

use containers_common::config::IgorConfig;
use tempfile::TempDir;

use super::context::AgentContext;

/// Writes `cfg` to a temp `.igor.yml` (with `working_dir` under it so the
/// resolved `base_dir` is the temp root) and loads an [`AgentContext`].
///
/// Returns the [`TempDir`] alongside the context so the caller keeps the
/// directory alive — worktree-existence checks in `status`/`connect` stat paths
/// under `base_dir`.
pub(super) fn load_ctx(mut cfg: IgorConfig) -> (AgentContext, TempDir) {
    let tmp = tempfile::tempdir().unwrap();
    let project_dir = tmp.path().join(&cfg.project.name);
    std::fs::create_dir_all(&project_dir).unwrap();
    cfg.project.working_dir = Some(project_dir.to_str().unwrap().to_string());
    let cfg_path = tmp.path().join(".igor.yml");
    cfg.save(&cfg_path).unwrap();
    let ctx = AgentContext::load(&cfg_path).unwrap();
    (ctx, tmp)
}
