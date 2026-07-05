//! The four `stibbons services` subcommands.
//!
//! Each `run_*` function takes an already-resolved
//! [`AgentContext`](crate::agent::context::AgentContext), an injected
//! `&dyn DockerRunner`, and a `&mut dyn Write` sink so tests can drive them with
//! a [`MockDocker`](crate::agent::docker::MockDocker) and a captured buffer — no
//! real Docker or stdout needed. They port the Go `runServices*` bodies from the
//! retired `cmd/igor/internal/cmd/services*.go`.

use std::io::Write;

use containers_common::config::ServiceConfig;

use crate::agent::context::{
    AgentContext, container_exists, ensure_network, is_container_running, service_container_name,
};
use crate::agent::db::{extract_pg_credentials, reset_per_agent_dbs, wait_for_postgres};
use crate::agent::docker::DockerRunner;

/// Boxed error alias matching the stibbons CLI convention.
type CmdResult = Result<(), Box<dyn std::error::Error>>;

/// Errors specific to the `services` command group.
#[derive(Debug, thiserror::Error)]
pub enum ServicesError {
    /// The named service is not declared in `.igor.yml`.
    #[error("unknown service {name:?}; not declared in .igor.yml")]
    UnknownService {
        /// The offending service name.
        name: String,
    },
}

/// Resolves the target services: the single named one, or all of them.
///
/// Returns the entries as `(name, config)` pairs in `BTreeMap` order (sorted by
/// name). Errors with [`ServicesError::UnknownService`] when `name` is given but
/// absent from the config.
fn target_services<'a>(
    ctx: &'a AgentContext,
    name: Option<&str>,
) -> Result<Vec<(&'a String, &'a ServiceConfig)>, ServicesError> {
    match name {
        Some(n) => {
            let svc = ctx
                .cfg
                .services
                .get(n)
                .ok_or_else(|| ServicesError::UnknownService { name: n.to_string() })?;
            // `get_key_value` keeps the borrow tied to the map's own `String`.
            let (key, _) = ctx.cfg.services.get_key_value(n).expect("present");
            Ok(vec![(key, svc)])
        }
        None => Ok(ctx.cfg.services.iter().collect()),
    }
}

/// `stibbons services start [name]` — create the network, then run each target
/// service container and poll it for readiness.
///
/// Per-service failures are best-effort: a service that fails to start is
/// reported and the loop continues to the next one, mirroring `agent start`.
///
/// # Errors
///
/// [`ServicesError::UnknownService`] if `name` is given but absent, or a Docker
/// error creating the network.
pub fn run_start(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    name: Option<&str>,
) -> CmdResult {
    let targets = target_services(ctx, name)?;
    if targets.is_empty() {
        writeln!(out, "No services configured in .igor.yml")?;
        return Ok(());
    }

    ensure_network(docker, out, &ctx.network)?;

    for (svc_name, svc) in targets {
        if let Err(e) = start_one(ctx, docker, out, svc_name, svc) {
            writeln!(out, "  ⚠ {svc_name}: {e}")?;
        }
    }
    Ok(())
}

/// Starts a single service container (idempotent) and waits for readiness.
fn start_one(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    svc_name: &str,
    svc: &ServiceConfig,
) -> CmdResult {
    let container = service_container_name(&ctx.project, svc_name);

    if is_container_running(docker, &container) {
        writeln!(out, "{container} is already running")?;
        return Ok(());
    }

    // Existing but stopped → start it rather than recreating.
    if container_exists(docker, &container) {
        writeln!(out, "Starting stopped container {container} ...")?;
        docker.run(&["start", &container])?;
    } else {
        let mut args: Vec<String> = vec![
            "run".into(),
            "-d".into(),
            "--name".into(),
            container.clone(),
            "--network".into(),
            ctx.network.clone(),
            "--restart".into(),
            "unless-stopped".into(),
            "--init".into(),
        ];
        for env in &svc.environment {
            args.push("-e".into());
            args.push(env.clone());
        }
        for vol in &svc.volumes {
            args.push("-v".into());
            args.push(vol.clone());
        }
        args.push(svc.image.clone());

        writeln!(out, "Starting {container} ...")?;
        docker.run(&to_refs(&args))?;
    }

    // Readiness poll (best-effort — a slow service warns but does not fail).
    if svc.port > 0 {
        if let Err(e) = wait_for_ready(docker, &container, svc) {
            writeln!(out, "  ⚠ {svc_name} readiness: {e}")?;
        } else {
            writeln!(out, "{container} ready")?;
        }
    }
    Ok(())
}

/// Waits for a service to accept connections. Uses semantic `pg_isready` for a
/// `per_agent_db`/postgres service, else a generic TCP-connect probe on the port.
fn wait_for_ready(
    docker: &dyn DockerRunner,
    container: &str,
    svc: &ServiceConfig,
) -> Result<(), Box<dyn std::error::Error>> {
    if svc.per_agent_db {
        let (user, _) = extract_pg_credentials(&svc.environment);
        wait_for_postgres(docker, container, &user, 30)?;
    } else {
        wait_for_port(docker, container, svc.port, 30)?;
    }
    Ok(())
}

/// Blocks until a TCP port inside `container` accepts a connection, up to
/// `timeout_secs`, by exec-ing a `nc -z` loop. Runs inside the container so it
/// needs no host tooling and stays [`MockDocker`](crate::agent::docker::MockDocker)-testable.
///
/// # Errors
///
/// Propagates the [`DockerError`](crate::agent::docker::DockerError) if the wait
/// command exits non-zero (i.e. the timeout elapsed).
pub fn wait_for_port(
    docker: &dyn DockerRunner,
    container: &str,
    port: u16,
    timeout_secs: u32,
) -> Result<(), crate::agent::docker::DockerError> {
    let check = format!(
        "timeout {timeout_secs} sh -c 'until nc -z localhost {port} 2>/dev/null; do sleep 1; done'"
    );
    docker.run(&["exec", container, "sh", "-c", &check])?;
    Ok(())
}

/// `stibbons services stop [name] [--clean]` — stop each target service, and
/// with `--clean` also remove the container and its named volumes.
///
/// # Errors
///
/// [`ServicesError::UnknownService`] if `name` is given but absent, or a Docker
/// error stopping/removing a container.
pub fn run_stop(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    name: Option<&str>,
    clean: bool,
) -> CmdResult {
    let targets = target_services(ctx, name)?;

    for (svc_name, svc) in targets {
        let container = service_container_name(&ctx.project, svc_name);

        if is_container_running(docker, &container) {
            writeln!(out, "Stopping {container} ...")?;
            docker.run(&["stop", &container])?;
        } else {
            writeln!(out, "{container} is not running")?;
        }

        if clean {
            if container_exists(docker, &container) {
                writeln!(out, "Removing {container} ...")?;
                docker.run(&["rm", &container])?;
            }
            for vol in named_volumes(svc) {
                writeln!(out, "Removing volume {vol} ...")?;
                // Best-effort: a still-referenced or absent volume must not abort
                // the rest of the cleanup.
                let _ = docker.run(&["volume", "rm", vol]);
            }
        }
    }
    Ok(())
}

/// `stibbons services status` — the network name plus a width-aligned table of
/// every configured service (sorted by name, since `services` is a `BTreeMap`).
///
/// # Errors
///
/// Propagates write failures on the output sink.
pub fn run_status(ctx: &AgentContext, docker: &dyn DockerRunner, out: &mut dyn Write) -> CmdResult {
    writeln!(out, "Network: {}\n", ctx.network)?;

    if ctx.cfg.services.is_empty() {
        writeln!(out, "No services configured in .igor.yml")?;
        return Ok(());
    }

    let mut rows: Vec<[String; 4]> =
        vec![["SERVICE".into(), "CONTAINER".into(), "STATUS".into(), "IMAGE".into()]];
    for (svc_name, svc) in &ctx.cfg.services {
        let container = service_container_name(&ctx.project, svc_name);
        let status = if is_container_running(docker, &container) {
            "running"
        } else if container_exists(docker, &container) {
            "stopped"
        } else {
            "not created"
        };
        rows.push([svc_name.clone(), container, status.to_string(), svc.image.clone()]);
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

/// `stibbons services reset <name>` — for a `per_agent_db` service, drop and
/// recreate every agent's database; for a standard service, stop and remove the
/// container so a subsequent `start` recreates it fresh.
///
/// # Errors
///
/// [`ServicesError::UnknownService`] if `name` is absent from the config, or a
/// Docker/`psql` error during the reset.
pub fn run_reset(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    name: &str,
) -> CmdResult {
    let svc = ctx
        .cfg
        .services
        .get(name)
        .ok_or_else(|| ServicesError::UnknownService { name: name.to_string() })?;

    if svc.per_agent_db {
        writeln!(out, "Resetting per-agent databases for {name} ...")?;
        reset_per_agent_dbs(docker, &ctx.project, name, svc, ctx.max_agents)?;
        writeln!(out, "Recreated {} agent databases", ctx.max_agents)?;
    } else {
        let container = service_container_name(&ctx.project, name);
        if is_container_running(docker, &container) {
            writeln!(out, "Stopping {container} ...")?;
            docker.run(&["stop", &container])?;
        }
        if container_exists(docker, &container) {
            writeln!(out, "Removing {container} ...")?;
            docker.run(&["rm", &container])?;
        }
        writeln!(out, "{container} reset; run `stibbons services start {name}` to recreate")?;
    }
    Ok(())
}

// --- helpers ---

/// Borrows a `Vec<String>` as `Vec<&str>` for the [`DockerRunner`] argv API.
fn to_refs(args: &[String]) -> Vec<&str> {
    args.iter().map(String::as_str).collect()
}

/// The named Docker volumes referenced by a service, i.e. the left-hand side of
/// each `name:/path` mount. Bind mounts (absolute or relative host paths, which
/// contain a `/` before the colon) are skipped — `docker volume rm` only applies
/// to named volumes.
fn named_volumes(svc: &ServiceConfig) -> impl Iterator<Item = &str> {
    svc.volumes.iter().filter_map(|v| {
        let source = v.split(':').next().unwrap_or(v);
        (!source.is_empty() && !source.contains('/')).then_some(source)
    })
}

/// Per-column max width across all rows, for hand-aligned tables (mirrors the
/// agent status printer).
fn column_widths(rows: &[[String; 4]]) -> [usize; 4] {
    let mut widths = [0usize; 4];
    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.len());
        }
    }
    widths
}

#[cfg(test)]
mod tests;
