//! `stibbons agent start` / `stop` / `restart`, and the embedded agent scripts
//! `start` mounts into the container.

use std::io::Write;

use super::super::context::{
    AgentContext, AgentError, agent_suffix, container_exists, container_name, ensure_network,
    image_exists, is_container_running, validate_agent_num,
};
use super::super::db::{per_agent_db_url, provision_per_agent_dbs};
use super::super::docker::DockerRunner;
use super::super::scripts_dir;
use super::build::run_build;
use super::{CmdResult, to_refs};

/// Embedded agent scripts, written by [`scripts_dir::prepare_scripts_dir`] to a
/// user-private host directory and mounted read-only into the container at
/// `/opt/agent-scripts`.
const AGENT_ENTRYPOINT_SH: &str = include_str!("../scripts/agent-entrypoint.sh");
const AGENT_INIT_SH: &str = include_str!("../scripts/agent-init.sh");
const AGENT_START_SH: &str = include_str!("../scripts/agent-start.sh");

/// The scripts as `prepare_scripts_dir` wants them: `(file name, contents)`.
/// `agent-entrypoint.sh` is the container's command; it runs the other two.
const AGENT_SCRIPTS: [(&str, &str); 3] = [
    ("agent-entrypoint.sh", AGENT_ENTRYPOINT_SH),
    ("agent-init.sh", AGENT_INIT_SH),
    ("agent-start.sh", AGENT_START_SH),
];

/// Best-effort probe that agent `suffix`'s first worktree exists on the host.
///
/// Mirrors the Go original: the result is advisory and every failure is
/// ignored — the bind mounts assembled in [`run_start`] are authoritative.
fn probe_first_worktree(ctx: &AgentContext, docker: &dyn DockerRunner, suffix: &str) {
    let base = ctx.base_dir.display().to_string();
    let first_worktree =
        ctx.base_dir.join(format!("{}-{}", ctx.repos[0], suffix)).display().to_string();
    let _ = docker.run(&[
        "run",
        "--rm",
        "-v",
        &format!("{base}:{base}:ro"),
        "alpine",
        "test",
        "-d",
        &first_worktree,
    ]);
}

/// Options for [`run_start`].
#[derive(Debug, Clone, Copy)]
pub struct StartOptions {
    /// Rebuild the image before starting.
    pub rebuild: bool,
}

/// `stibbons agent start <N>` — create-or-start agent container `n`.
///
/// # Errors
///
/// [`AgentError`] for bad agent numbers or a missing image, or a Docker error
/// during network/container creation.
pub fn run_start(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    n_arg: &str,
    opts: StartOptions,
) -> CmdResult {
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let name = container_name(&ctx.project, n);
    let suffix = agent_suffix(n);

    if opts.rebuild {
        run_build(ctx, docker, out, false)?;
    }

    if is_container_running(docker, &name) {
        writeln!(out, "{name} is already running")?;
        return Ok(());
    }

    // Existing but stopped → just start it.
    if container_exists(docker, &name) {
        writeln!(out, "Starting stopped container {name} ...")?;
        docker.run(&["start", &name])?;
        writeln!(out, "{name} started")?;
        return Ok(());
    }

    if !image_exists(docker, &ctx.image_name, &ctx.image_tag) {
        return Err(AgentError::ImageMissing {
            image: ctx.image_name.clone(),
            tag: ctx.image_tag.clone(),
        }
        .into());
    }

    probe_first_worktree(ctx, docker, &suffix);

    // User-private 0700 directory keyed by container name, NOT a PID-named path
    // under the shared temp dir (#924, CWE-377) — it is mounted alongside
    // docker.sock below, so anyone able to write into it gets code execution
    // there.
    let scripts_dir =
        scripts_dir::prepare_scripts_dir(ctx.state_root.as_deref(), &name, &AGENT_SCRIPTS)?;

    // Create the network if it doesn't already exist.
    ensure_network(docker, out, &ctx.network)?;

    let hostname = format!("agent-{n}");
    let scripts_mount = format!("{}:/opt/agent-scripts:ro", scripts_dir.display());
    let mut args: Vec<String> = vec![
        "run".into(),
        "-d".into(),
        "--name".into(),
        name.clone(),
        "--hostname".into(),
        hostname,
        "--network".into(),
        ctx.network.clone(),
        "--restart".into(),
        "unless-stopped".into(),
        "--init".into(),
        "-v".into(),
        "/var/run/docker.sock:/var/run/docker.sock".into(),
        "-v".into(),
        scripts_mount,
    ];

    // Mount each repo's main checkout and its per-agent worktree.
    for repo in &ctx.repos {
        let main_repo = ctx.base_dir.join(repo).display().to_string();
        args.push("-v".into());
        args.push(format!("{main_repo}:{main_repo}"));
    }
    for repo in &ctx.repos {
        let worktree = ctx.base_dir.join(format!("{repo}-{suffix}")).display().to_string();
        args.push("-v".into());
        args.push(format!("{worktree}:{worktree}"));
    }

    for vol in &ctx.shared_volumes {
        args.push("-v".into());
        args.push(vol.clone());
    }

    args.push("-e".into());
    args.push(format!("PROJECT_NAME={}", ctx.project));
    args.push("-e".into());
    args.push(format!("AGENT_REPOS={}", ctx.repos.join(",")));

    // Forward librarian's golem event-sink config into the container so the
    // in-container emitter (`golem-notify.sh`) can POST a golem's decision-point
    // events to the orchestrator's HTTP sink(s) in addition to the file feed
    // (#759, additive over the #743 feed transport). Only forwarded when the
    // orchestrator set a sink: an unset `GOLEM_EVENT_SINKS` pushes zero `-e`
    // flags, so the container is byte-for-byte the file-feed-only baseline
    // (matches the emitter's own empty/unset ⇒ no-op contract). The timeout
    // rides along only with a sink, deferring to the emitter's 2s default when
    // unset.
    if !ctx.golem_event_sinks.is_empty() {
        args.push("-e".into());
        args.push(format!("GOLEM_EVENT_SINKS={}", ctx.golem_event_sinks));
        if !ctx.golem_event_sink_timeout.is_empty() {
            args.push("-e".into());
            args.push(format!("GOLEM_EVENT_SINK_TIMEOUT={}", ctx.golem_event_sink_timeout));
        }
    }

    for (svc_name, svc) in &ctx.cfg.services {
        if svc.per_agent_db && svc.port > 0 {
            args.push("-e".into());
            args.push(format!("DATABASE_URL={}", per_agent_db_url(&ctx.project, n, svc_name, svc)));
        }
    }

    args.push(format!("{}:{}", ctx.image_name, ctx.image_tag));
    args.push("/opt/agent-scripts/agent-entrypoint.sh".into());

    writeln!(out, "Creating container {name} ...")?;
    docker.run(&to_refs(&args))?;
    writeln!(out, "{name} started")?;

    // Provision per-agent databases (best-effort — the service may not be up).
    if !ctx.cfg.services.is_empty()
        && let Err(e) = provision_per_agent_dbs(docker, &ctx.project, n, &ctx.cfg.services)
    {
        writeln!(out, "  ⚠ database provisioning: {e}")?;
    }

    Ok(())
}

/// `stibbons agent stop <N>`.
///
/// # Errors
///
/// [`AgentError`] for a bad agent number, or a Docker error stopping the container.
pub fn run_stop(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    n_arg: &str,
) -> CmdResult {
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let name = container_name(&ctx.project, n);

    if !is_container_running(docker, &name) {
        writeln!(out, "{name} is not running")?;
        return Ok(());
    }

    writeln!(out, "Stopping {name} ...")?;
    docker.run(&["stop", &name])?;
    writeln!(out, "{name} stopped")?;
    Ok(())
}

/// `stibbons agent restart <N>` — stop, remove, then start fresh.
///
/// # Errors
///
/// [`AgentError`] for a bad agent number, or a Docker error during the sequence.
pub fn run_restart(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    n_arg: &str,
) -> CmdResult {
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let name = container_name(&ctx.project, n);

    if is_container_running(docker, &name) {
        writeln!(out, "Stopping {name} ...")?;
        docker.run(&["stop", &name])?;
    }
    if container_exists(docker, &name) {
        writeln!(out, "Removing {name} ...")?;
        docker.run(&["rm", &name])?;
    }

    run_start(ctx, docker, out, n_arg, StartOptions { rebuild: false })
}

#[cfg(test)]
mod tests {
    use containers_common::config::AgentConfig;

    use super::super::super::docker::{MockDocker, MockResult};
    use super::super::super::test_support::load_ctx;

    use super::super::test_helpers::{capture, cfg};
    use super::*;

    // --- start ---

    #[test]
    fn start_rejects_invalid_agent_number() {
        let mut c = cfg(&[]);
        c.agents = AgentConfig { max: 5, ..AgentConfig::default() };
        let (ctx, _tmp) = load_ctx(c);

        for (arg, needle) in
            [("0", "between 1 and 5"), ("abc", "must be an integer"), ("6", "between 1 and 5")]
        {
            let docker = MockDocker::new();
            let (_out, res) =
                capture(|o| run_start(&ctx, &docker, o, arg, StartOptions { rebuild: false }));
            let err = res.unwrap_err().to_string();
            assert!(err.contains(needle), "arg {arg}: {err:?} should contain {needle:?}");
        }
    }

    #[test]
    fn start_already_running() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::ok("true"));

        let (out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(out.contains("already running"));
    }

    #[test]
    fn start_no_image_errors() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::err());

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        let err = res.unwrap_err().to_string();
        assert!(err.contains("run `stibbons agent build` first"), "{err:?}");
    }

    /// A `MockDocker` on which `run_start` reaches the scripts-dir step: no
    /// existing container, image present, network present.
    fn docker_reaching_scripts_dir() -> MockDocker {
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::ok("ok"));
        docker
    }

    /// #926: no user-private state root is fatal (#924) — and fatal *before*
    /// the container is created. Asserting only the `Err` would pass if the
    /// container were started and the error raised afterwards.
    #[test]
    fn start_aborts_without_state_root() {
        let (mut ctx, _tmp) = load_ctx(cfg(&[]));
        ctx.state_root = None;
        let docker = docker_reaching_scripts_dir();

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        let err = res.unwrap_err();
        assert!(
            matches!(
                err.downcast_ref::<scripts_dir::ScriptsDirError>(),
                Some(scripts_dir::ScriptsDirError::NoStateRoot)
            ),
            "{err:?}"
        );
        assert!(!docker.has_call("run -d"), "no container may be created");
        assert!(!docker.has_call("network"), "abort precedes network setup");
    }

    /// #926: a scripts dir planted at a non-private mode is rejected through
    /// `run_start` — not adopted, not wiped — and no container is created.
    #[cfg(unix)]
    #[test]
    fn start_aborts_on_planted_scripts_dir() {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let parent = ctx.state_root.clone().unwrap().join("stibbons").join("agent-scripts");
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&parent).unwrap();
        let planted = parent.join(container_name(&ctx.project, 1));
        std::fs::create_dir(&planted).unwrap();
        std::fs::set_permissions(&planted, std::fs::Permissions::from_mode(0o755)).unwrap();
        let sentinel = planted.join("agent-entrypoint.sh");
        std::fs::write(&sentinel, "planted").unwrap();
        let docker = docker_reaching_scripts_dir();

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        let err = res.unwrap_err();
        assert!(
            matches!(
                err.downcast_ref::<scripts_dir::ScriptsDirError>(),
                Some(scripts_dir::ScriptsDirError::UnsafePath { .. })
            ),
            "{err:?}"
        );
        assert_eq!(std::fs::read_to_string(&sentinel).unwrap(), "planted");
        assert!(!docker.has_call("run -d"), "no container may be created");
    }

    #[test]
    fn start_new_container_assembles_run_args() {
        let (ctx, _tmp) = load_ctx(cfg(&["python"]));
        // Build the expected worktree path the same way run_start does, so the
        // assertion holds regardless of the host path separator.
        let worktree = ctx.base_dir.join("myproject-agent01").display().to_string();
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::err());
        docker.on("network create", MockResult::ok("ok"));

        let (out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();

        assert!(out.contains("Creating container"));
        assert!(out.contains("started"));
        assert!(docker.has_call("run -d"));
        assert!(docker.has_call("--name myproject-agent-1"));
        assert!(docker.has_call("--network myproject-network"));
        assert!(docker.has_call("--hostname agent-1"));
        assert!(docker.has_call(&worktree), "expected worktree mount");
        assert!(docker.has_call("/opt/agent-scripts/agent-entrypoint.sh"));
    }

    #[test]
    fn start_stopped_container() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        // First inspect -f (is-running) → false; second (exists) → "exited".
        let call = std::cell::Cell::new(0);
        docker.set_run_fn(move |args| {
            if args.len() >= 2 && args[0] == "inspect" && args[1] == "-f" {
                call.set(call.get() + 1);
                return if call.get() == 1 {
                    MockResult::ok("false")
                } else {
                    MockResult::ok("exited")
                };
            }
            MockResult::ok("")
        });

        let (out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(out.contains("Starting stopped container"));
        assert!(docker.has_call("start myproject-agent-1"));
    }

    #[test]
    fn start_mounts_scripts_and_env() {
        let (ctx, _tmp) = load_ctx(cfg(&["python"]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::ok("ok"));

        let (out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(out.contains("started"));
        assert!(docker.has_call("/opt/agent-scripts:ro"));
        assert!(docker.has_call("/opt/agent-scripts/agent-entrypoint.sh"));
        assert!(docker.has_call("PROJECT_NAME=myproject"));
        assert!(docker.has_call("AGENT_REPOS=myproject"));
        assert!(!docker.has_call("sleep infinity"), "entrypoint replaces sleep infinity");
    }

    /// #759: with no orchestrator sink configured (the default), the run args
    /// carry no `GOLEM_EVENT_SINKS` — the container is the file-feed-only
    /// baseline and the emitter's no-op contract holds.
    #[test]
    fn start_omits_golem_sinks_when_unset() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        assert!(ctx.golem_event_sinks.is_empty(), "load_ctx must not set sinks");
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::ok("ok"));

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(!docker.has_call("GOLEM_EVENT_SINKS"), "no sink env when unset");
        assert!(!docker.has_call("GOLEM_EVENT_SINK_TIMEOUT"), "no timeout without a sink");
    }

    /// #759: a configured sink (and its timeout) is forwarded verbatim into the
    /// container env for librarian's multi-sink emitter.
    #[test]
    fn start_forwards_golem_sinks_when_set() {
        let (mut ctx, _tmp) = load_ctx(cfg(&[]));
        ctx.golem_event_sinks = "https://orchestrator.local/events".into();
        ctx.golem_event_sink_timeout = "5".into();
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::ok("ok"));

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(docker.has_call("GOLEM_EVENT_SINKS=https://orchestrator.local/events"));
        assert!(docker.has_call("GOLEM_EVENT_SINK_TIMEOUT=5"));
    }

    /// #759: the timeout only rides along with a sink — it is never pushed on
    /// its own (an orphan `GOLEM_EVENT_SINK_TIMEOUT` would be meaningless to the
    /// emitter, which reads it only when fanning to sinks).
    #[test]
    fn start_omits_lone_golem_sink_timeout() {
        let (mut ctx, _tmp) = load_ctx(cfg(&[]));
        ctx.golem_event_sink_timeout = "5".into();
        // golem_event_sinks stays empty.
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("network inspect", MockResult::ok("ok"));

        let (_out, res) =
            capture(|o| run_start(&ctx, &docker, o, "1", StartOptions { rebuild: false }));
        res.unwrap();
        assert!(!docker.has_call("GOLEM_EVENT_SINK_TIMEOUT"), "timeout needs a sink");
    }

    // --- stop ---

    #[test]
    fn stop_running() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::ok("true"));

        let (out, res) = capture(|o| run_stop(&ctx, &docker, o, "1"));
        res.unwrap();
        assert!(out.contains("stopped"));
        assert!(docker.has_call("stop myproject-agent-1"));
    }

    #[test]
    fn stop_not_running() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());

        let (out, res) = capture(|o| run_stop(&ctx, &docker, o, "1"));
        res.unwrap();
        assert!(out.contains("not running"));
    }

    // --- restart ---

    #[test]
    fn restart_sequences_stop_rm_start() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        // 4 inspect -f calls: running(yes), exists(yes), start-running(no), start-exists(no).
        let call = std::cell::Cell::new(0);
        docker.set_run_fn(move |args| {
            if args.len() >= 2 && args[0] == "inspect" && args[1] == "-f" {
                call.set(call.get() + 1);
                return match call.get() {
                    1 => MockResult::ok("true"),
                    2 => MockResult::ok("exited"),
                    _ => MockResult::err(),
                };
            }
            if args.len() >= 2 && args[0] == "image" && args[1] == "inspect" {
                return MockResult::ok("ok");
            }
            if args.len() >= 2 && args[0] == "network" && args[1] == "inspect" {
                return MockResult::ok("ok");
            }
            MockResult::ok("")
        });

        let (out, res) = capture(|o| run_restart(&ctx, &docker, o, "1"));
        res.unwrap();
        assert!(out.contains("Stopping"));
        assert!(out.contains("Removing"));
        assert!(docker.has_call("stop myproject-agent-1"));
        assert!(docker.has_call("rm myproject-agent-1"));
        assert!(docker.has_call("run -d"));
    }

    // --- embedded scripts ---

    #[test]
    fn embedded_scripts_are_present() {
        for body in [AGENT_ENTRYPOINT_SH, AGENT_INIT_SH, AGENT_START_SH] {
            assert!(!body.is_empty(), "expected non-empty");
            assert!(body.starts_with("#!"), "script should start with a shebang");
        }
        // The entrypoint is the golem-shaped version, not the retired bare shell.
        assert!(AGENT_ENTRYPOINT_SH.contains("NEXT_ISSUE_AUTONOMOUS"));
        assert!(AGENT_ENTRYPOINT_SH.contains("agent-ready"));
    }
}
