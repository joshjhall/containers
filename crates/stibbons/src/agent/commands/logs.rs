//! `stibbons agent logs`.

use std::io::Write;

use super::super::context::{
    AgentContext, AgentError, container_exists, container_name, validate_agent_num,
};
use super::super::docker::DockerRunner;
use super::CmdResult;

/// Options for [`run_logs`].
#[derive(Debug, Clone, Copy)]
pub struct LogsOptions {
    /// Follow log output (`docker logs -f`).
    pub follow: bool,
}

/// `stibbons agent logs <N>` — forward to `docker logs`.
///
/// # Errors
///
/// [`AgentError::ContainerMissing`] if the container doesn't exist, or a Docker
/// error from the passthrough.
pub fn run_logs(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    _out: &mut dyn Write,
    n_arg: &str,
    opts: LogsOptions,
) -> CmdResult {
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let name = container_name(&ctx.project, n);

    if !container_exists(docker, &name) {
        return Err(AgentError::ContainerMissing(name).into());
    }

    let mut args: Vec<&str> = vec!["logs"];
    if opts.follow {
        args.push("-f");
    }
    args.push(&name);
    docker.passthrough(&args)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::super::docker::{MockDocker, MockResult};
    use super::super::super::test_support::load_ctx;

    use super::super::test_helpers::{capture, cfg};
    use super::*;

    // --- logs ---

    #[test]
    fn logs_basic() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::ok("exited"));

        let (_out, res) =
            capture(|o| run_logs(&ctx, &docker, o, "1", LogsOptions { follow: false }));
        res.unwrap();
        assert!(docker.has_call("logs myproject-agent-1"));
    }

    #[test]
    fn logs_follow() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::ok("exited"));

        let (_out, res) =
            capture(|o| run_logs(&ctx, &docker, o, "1", LogsOptions { follow: true }));
        res.unwrap();
        assert!(docker.has_call("logs -f myproject-agent-1"));
    }

    #[test]
    fn logs_missing_container_errors() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());

        let (_out, res) =
            capture(|o| run_logs(&ctx, &docker, o, "1", LogsOptions { follow: false }));
        let err = res.unwrap_err().to_string();
        assert!(err.contains("does not exist"), "{err:?}");
    }
}
