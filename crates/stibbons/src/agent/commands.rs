//! The seven `stibbons agent` subcommands.
//!
//! Each `run_*` function ports the matching Go `runAgent*` from
//! `cmd/igor/internal/cmd/agent_*.go`. They take an already-resolved
//! [`AgentContext`], an injected `&dyn DockerRunner`, and a `&mut dyn Write`
//! sink so tests can drive them with a [`MockDocker`](super::docker::MockDocker)
//! and a captured buffer — no real Docker or stdout needed.

use std::io::{IsTerminal, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::context::{
    AgentContext, AgentError, agent_suffix, container_exists, container_name, ensure_network,
    image_exists, is_container_running, validate_agent_num,
};
use super::db::{per_agent_db_url, provision_per_agent_dbs};
use super::docker::DockerRunner;

/// Boxed error alias matching the stibbons CLI convention (`main.rs`).
type CmdResult = Result<(), Box<dyn std::error::Error>>;

/// Embedded agent scripts, written to a host directory and mounted read-only
/// into the container at `/opt/agent-scripts`.
const AGENT_ENTRYPOINT_SH: &str = include_str!("scripts/agent-entrypoint.sh");
const AGENT_INIT_SH: &str = include_str!("scripts/agent-init.sh");
const AGENT_START_SH: &str = include_str!("scripts/agent-start.sh");

/// `stibbons agent build` — build the agent image from feature/version args.
///
/// # Errors
///
/// Propagates Docker failures (volume/image creation). `--dry-run` prints the
/// command and makes zero Docker calls.
pub fn run_build(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    dry_run: bool,
) -> CmdResult {
    // Ensure shared cache volumes exist (skipped entirely under --dry-run).
    if !dry_run {
        for vol in &ctx.shared_volumes {
            let vol_name = vol.split(':').next().unwrap_or(vol);
            if docker.run(&["volume", "inspect", vol_name]).is_err() {
                docker.run(&["volume", "create", vol_name])?;
                writeln!(out, "Created volume {vol_name}")?;
            }
        }
    }

    let image_ref = format!("{}:{}", ctx.image_name, ctx.image_tag);
    let dockerfile = format!("{}/Dockerfile", ctx.containers_dir.display());
    let project_arg = format!("PROJECT_NAME={}", ctx.project);
    let username_arg = format!("USERNAME={}", ctx.username);
    let containers_dir = ctx.containers_dir.display().to_string();

    let mut args: Vec<String> = vec![
        "build".into(),
        "-t".into(),
        image_ref,
        "-f".into(),
        dockerfile,
        "--build-arg".into(),
        "PROJECT_PATH=.".into(),
        "--build-arg".into(),
        project_arg,
        "--build-arg".into(),
        username_arg,
    ];

    for f in &ctx.features {
        args.push("--build-arg".into());
        args.push(format!("{}=true", f.build_arg));
    }
    for (arg_name, version) in &ctx.cfg.versions {
        args.push("--build-arg".into());
        args.push(format!("{arg_name}={version}"));
    }
    args.push(containers_dir);

    if dry_run {
        writeln!(out, "docker {}", args.join(" "))?;
        return Ok(());
    }

    writeln!(out, "Building {}:{} ...", ctx.image_name, ctx.image_tag)?;
    docker.passthrough(&to_refs(&args))?;
    Ok(())
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

    // Best-effort worktree probe (mirrors the Go original — the result is
    // advisory and failures are ignored; the mounts below are authoritative).
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

    let scripts_dir = extract_agent_scripts()?;

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

/// `stibbons agent status` — tabular image/network + per-agent status.
///
/// # Errors
///
/// Propagates write failures on the output sink.
pub fn run_status(ctx: &AgentContext, docker: &dyn DockerRunner, out: &mut dyn Write) -> CmdResult {
    let image_status =
        if image_exists(docker, &ctx.image_name, &ctx.image_tag) { "built" } else { "not built" };
    writeln!(out, "Image: {}:{} ({image_status})", ctx.image_name, ctx.image_tag)?;
    writeln!(out, "Network: {}\n", ctx.network)?;

    // Collect rows first so the columns can be width-aligned by hand (no table
    // crate in the workspace; mirrors the render-plan printer in main.rs).
    let mut rows: Vec<[String; 4]> =
        vec![["AGENT".into(), "CONTAINER".into(), "STATUS".into(), "WORKTREES".into()]];
    for i in 1..=ctx.max_agents {
        let name = container_name(&ctx.project, i);
        let suffix = agent_suffix(i);

        let status = if is_container_running(docker, &name) {
            "running"
        } else if container_exists(docker, &name) {
            "stopped"
        } else {
            "not created"
        };

        let exist_count = ctx
            .repos
            .iter()
            .filter(|repo| ctx.base_dir.join(format!("{repo}-{suffix}")).exists())
            .count();
        let worktrees = if exist_count == ctx.repos.len() {
            "ready".to_string()
        } else if exist_count > 0 {
            format!("{exist_count}/{}", ctx.repos.len())
        } else {
            "none".to_string()
        };

        rows.push([i.to_string(), name, status.to_string(), worktrees]);
    }

    let widths = column_widths(&rows);
    for row in &rows {
        writeln!(
            out,
            "{:<w0$}  {:<w1$}  {:<w2$}  {}",
            row[0],
            row[1],
            row[2],
            row[3],
            w0 = widths[0],
            w1 = widths[1],
            w2 = widths[2],
        )?;
    }
    Ok(())
}

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

/// Options for [`run_connect`].
#[derive(Debug, Clone, Copy)]
pub struct ConnectOptions {
    /// Readiness timeout in seconds.
    pub timeout: u64,
}

/// `stibbons agent connect <N>` — wait for readiness, then exec an interactive
/// shell.
///
/// # Errors
///
/// [`AgentError::ConnectTimeout`] if the container never starts within the
/// timeout, or a Docker error from the interactive `exec`.
pub fn run_connect(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    n_arg: &str,
    opts: ConnectOptions,
) -> CmdResult {
    let n = validate_agent_num(n_arg, ctx.max_agents)?;
    let name = container_name(&ctx.project, n);
    let suffix = agent_suffix(n);
    let workdir = ctx.base_dir.join(format!("{}-{}", ctx.repos[0], suffix)).display().to_string();
    let ready_file = format!("/home/{}/.local/state/{}/agent-ready", ctx.username, ctx.project);

    let use_tty = std::io::stdout().is_terminal();
    let deadline = Instant::now() + Duration::from_secs(opts.timeout);

    // Stage 1: container must be running (hard timeout).
    if !is_container_running(docker, &name)
        && wait_with_spinner(out, use_tty, deadline, "Waiting for container to start", || {
            is_container_running(docker, &name)
        })
        .is_err()
    {
        return Err(AgentError::ConnectTimeout { name, secs: opts.timeout }.into());
    }

    // Stage 2: readiness marker (warn-only on timeout, connect anyway).
    if wait_with_spinner(out, use_tty, deadline, "Waiting for agent initialization", || {
        docker.run(&["exec", &name, "test", "-f", &ready_file]).is_ok()
    })
    .is_err()
    {
        writeln!(out, "Warning: readiness marker not found, connecting anyway")?;
    }

    writeln!(out, "Connecting to agent {n} ...")?;
    docker.passthrough(&[
        "exec",
        "-it",
        "-u",
        &ctx.username,
        "-w",
        &workdir,
        &name,
        "bash",
        "-l",
    ])?;
    Ok(())
}

// --- helpers ---

/// Borrows a `Vec<String>` as `Vec<&str>` for the [`DockerRunner`] argv API.
fn to_refs(args: &[String]) -> Vec<&str> {
    args.iter().map(String::as_str).collect()
}

/// Per-column max width across all rows, for hand-aligned tables.
fn column_widths(rows: &[[String; 4]]) -> [usize; 4] {
    let mut widths = [0usize; 4];
    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.len());
        }
    }
    widths
}

/// Writes the embedded agent scripts to a host directory and returns its path.
///
/// The directory is intentionally NOT cleaned up: it is mounted into the
/// container and must outlive this process, exactly like the Go original.
fn extract_agent_scripts() -> std::io::Result<PathBuf> {
    let dir = std::env::temp_dir().join(format!("stibbons-agent-scripts-{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;

    for (name, body) in [
        ("agent-entrypoint.sh", AGENT_ENTRYPOINT_SH),
        ("agent-init.sh", AGENT_INIT_SH),
        ("agent-start.sh", AGENT_START_SH),
    ] {
        let path = dir.join(name);
        std::fs::write(&path, body)?;
        set_executable(&path)?;
    }

    Ok(dir)
}

/// Marks a file executable (`0o755`) on Unix. A no-op on other platforms — the
/// scripts only ever run inside the Linux agent container they're mounted into,
/// so the host's mode bits are irrelevant off-Unix (keeps the Windows build green).
//
// `allow`, not `expect`: on non-Unix the body reduces to `Ok(())` and clippy's
// `missing_const_for_fn` / `unnecessary_wraps` fire, but on Unix they do not —
// an `#[expect]` would then be unfulfilled (itself a `-D warnings` error there).
#[allow(clippy::missing_const_for_fn, clippy::unnecessary_wraps)]
fn set_executable(path: &std::path::Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

/// Polls `check` until it returns true or `deadline` passes, with a braille
/// spinner on a TTY and a single plain line otherwise. Ports Go's
/// `waitWithSpinner`: checks immediately and then once per second (~10 ticks).
fn wait_with_spinner(
    out: &mut dyn Write,
    use_tty: bool,
    deadline: Instant,
    message: &str,
    mut check: impl FnMut() -> bool,
) -> Result<(), ()> {
    const SPINNER: [char; 10] = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
    let start = Instant::now();
    let mut ticks: usize = 0;
    loop {
        let elapsed = start.elapsed().as_secs();
        if Instant::now() >= deadline {
            if use_tty {
                let _ = write!(out, "\r\x1b[K");
                let _ = out.flush();
            }
            return Err(());
        }
        if ticks.is_multiple_of(10) && check() {
            if use_tty {
                let _ = write!(out, "\r\x1b[K");
                let _ = out.flush();
            }
            return Ok(());
        }
        if use_tty {
            let _ = write!(out, "\r  {} {message}... ({elapsed}s)", SPINNER[ticks % SPINNER.len()]);
            let _ = out.flush();
        } else if ticks == 0 {
            let _ = writeln!(out, "{message}...");
        }
        std::thread::sleep(Duration::from_millis(100));
        ticks += 1;
    }
}

#[cfg(test)]
mod tests {
    use containers_common::config::IgorConfig;
    use containers_common::config::{AgentConfig, ProjectConfig};

    use super::super::docker::{MockDocker, MockResult};
    use super::super::test_support::load_ctx;
    use super::*;

    /// A base config for a `myproject` with the given features.
    fn cfg(features: &[&str]) -> IgorConfig {
        IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig { name: "myproject".into(), ..ProjectConfig::default() },
            features: features.iter().map(ToString::to_string).collect(),
            ..IgorConfig::default()
        }
    }

    /// Runs a closure with the captured output decoded as UTF-8.
    fn capture(f: impl FnOnce(&mut Vec<u8>) -> CmdResult) -> (String, CmdResult) {
        let mut buf = Vec::new();
        let res = f(&mut buf);
        (String::from_utf8(buf).unwrap(), res)
    }

    // --- build ---

    #[test]
    fn build_dry_run_prints_and_makes_no_calls() {
        let mut c = cfg(&["python", "node"]);
        c.versions.insert("PYTHON_VERSION".into(), "3.12.0".into());
        let (ctx, _tmp) = load_ctx(c);
        let docker = MockDocker::new();

        let (out, res) = capture(|o| run_build(&ctx, &docker, o, true));
        res.unwrap();

        assert!(out.contains("docker build"));
        assert!(out.contains("INCLUDE_PYTHON=true"));
        assert!(out.contains("INCLUDE_NODE=true"));
        assert!(out.contains("PYTHON_VERSION=3.12.0"));
        assert!(out.contains("PROJECT_NAME=myproject"));
        // Default username is used even though no username was configured.
        assert!(out.contains("USERNAME=agent"));
        assert_eq!(docker.call_count(), 0, "dry-run must not call docker");
    }

    #[test]
    fn build_dry_run_emits_dev_and_docker_args() {
        let (ctx, _tmp) = load_ctx(cfg(&["python", "python_dev", "docker"]));
        let docker = MockDocker::new();

        let (out, res) = capture(|o| run_build(&ctx, &docker, o, true));
        res.unwrap();

        assert!(out.contains("INCLUDE_PYTHON=true"));
        assert!(out.contains("INCLUDE_PYTHON_DEV=true"));
        assert!(out.contains("INCLUDE_DOCKER=true"));
    }

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

    // --- status ---

    #[test]
    fn status_table() {
        let mut c = cfg(&[]);
        c.agents = AgentConfig { max: 3, ..AgentConfig::default() };
        let (ctx, _tmp) = load_ctx(c);
        let docker = MockDocker::new();
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("inspect -f", MockResult::err());

        let (out, res) = capture(|o| run_status(&ctx, &docker, o));
        res.unwrap();

        assert!(out.contains("Image: myproject-agent:latest (built)"));
        assert!(out.contains("myproject-network"));
        assert!(out.contains("AGENT"));
        for i in 1..=3 {
            assert!(out.contains(&container_name("myproject", i)));
        }
        assert!(out.contains("not created"));
    }

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

    // --- connect ---

    #[test]
    fn connect_already_ready() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.set_run_fn(|args| {
            let joined = args.join(" ");
            if joined.contains("inspect") && joined.contains("Running") {
                return MockResult::ok("true");
            }
            MockResult::ok("") // test -f marker present (exit 0)
        });

        let (_out, res) =
            capture(|o| run_connect(&ctx, &docker, o, "1", ConnectOptions { timeout: 2 }));
        res.unwrap();
        assert!(docker.has_call("test -f"), "expected readiness marker check");
    }

    #[test]
    fn connect_timeout() {
        let (ctx, _tmp) = load_ctx(cfg(&[]));
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err());

        let (_out, res) =
            capture(|o| run_connect(&ctx, &docker, o, "1", ConnectOptions { timeout: 1 }));
        let err = res.unwrap_err().to_string();
        assert!(err.contains("timeout"), "{err:?}");
    }

    // --- embedded scripts ---

    #[test]
    fn embedded_scripts_are_present() {
        for body in [AGENT_ENTRYPOINT_SH, AGENT_INIT_SH, AGENT_START_SH] {
            assert!(!body.is_empty());
            assert!(body.starts_with("#!"), "script should start with a shebang");
        }
        // The entrypoint is the golem-shaped version, not the retired bare shell.
        assert!(AGENT_ENTRYPOINT_SH.contains("NEXT_ISSUE_AUTONOMOUS"));
        assert!(AGENT_ENTRYPOINT_SH.contains("agent-ready"));
    }
}
