//! `stibbons agent connect`.

use std::io::{IsTerminal, Write};
use std::time::{Duration, Instant};

use super::super::context::{
    AgentContext, AgentError, agent_suffix, container_name, is_container_running,
    validate_agent_num,
};
use super::super::docker::DockerRunner;
use super::CmdResult;

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
    use super::super::super::docker::{MockDocker, MockResult};
    use super::super::super::test_support::load_ctx;

    use super::super::test_helpers::{capture, cfg};
    use super::*;

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
}
