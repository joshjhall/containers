//! Unit tests for the `services` subcommands, driven by
//! [`MockDocker`](crate::agent::docker::MockDocker) so no Docker daemon runs.

use std::collections::BTreeMap;

use containers_common::config::{AgentConfig, IgorConfig, ProjectConfig, ServiceConfig};

use crate::agent::context::AgentContext;
use crate::agent::docker::{MockDocker, MockResult};
use crate::agent::test_support::load_ctx;

use super::*;

/// A postgres service with `per_agent_db` set.
fn pg_service() -> ServiceConfig {
    ServiceConfig {
        image: "postgres:16".into(),
        environment: vec!["POSTGRES_USER=postgres".into()],
        volumes: vec!["pgdata:/var/lib/postgresql/data".into()],
        port: 5432,
        per_agent_db: true,
    }
}

/// A plain redis service (no per-agent DB).
fn redis_service() -> ServiceConfig {
    ServiceConfig { image: "redis:7".into(), port: 6379, ..ServiceConfig::default() }
}

/// Builds a `myproject` context with the given services and `max_agents = 3`.
fn ctx_with(services: BTreeMap<String, ServiceConfig>) -> (AgentContext, tempfile::TempDir) {
    let cfg = IgorConfig {
        schema_version: 1,
        containers_dir: "containers".into(),
        project: ProjectConfig { name: "myproject".into(), ..ProjectConfig::default() },
        agents: AgentConfig { max: 3, ..AgentConfig::default() },
        services,
        ..IgorConfig::default()
    };
    load_ctx(cfg)
}

fn both_services() -> BTreeMap<String, ServiceConfig> {
    let mut m = BTreeMap::new();
    m.insert("postgres".to_string(), pg_service());
    m.insert("redis".to_string(), redis_service());
    m
}

fn run_to_string(f: impl FnOnce(&mut Vec<u8>)) -> String {
    let mut buf = Vec::new();
    f(&mut buf);
    String::from_utf8(buf).unwrap()
}

// --- target resolution ---

#[test]
fn target_all_returns_sorted_services() {
    let (ctx, _tmp) = ctx_with(both_services());
    let targets = target_services(&ctx, None).unwrap();
    let names: Vec<&str> = targets.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, ["postgres", "redis"]); // BTreeMap order
}

#[test]
fn target_named_returns_one() {
    let (ctx, _tmp) = ctx_with(both_services());
    let targets = target_services(&ctx, Some("redis")).unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!(targets[0].0, "redis");
}

#[test]
fn target_unknown_errors() {
    let (ctx, _tmp) = ctx_with(both_services());
    let err = target_services(&ctx, Some("mongo")).unwrap_err();
    assert!(err.to_string().contains("unknown service"), "{err}");
}

// --- start ---

#[test]
fn start_all_creates_network_and_runs_each_service() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::err()); // network absent → create
    docker.on("inspect -f", MockResult::err()); // no container running/exists

    let out = run_to_string(|buf| run_start(&ctx, &docker, buf, None).unwrap());

    assert!(docker.has_call("network create myproject-network"));
    assert!(out.contains("Created network myproject-network"), "{out}");
    assert!(docker.has_call("run -d --name myproject-postgres"), "postgres run missing");
    assert!(docker.has_call("run -d --name myproject-redis"), "redis run missing");
    // Service env/volume/image are threaded through for postgres.
    assert!(docker.has_call("-e POSTGRES_USER=postgres"));
    assert!(docker.has_call("-v pgdata:/var/lib/postgresql/data"));
    assert!(docker.has_call("postgres:16"));
}

#[test]
fn start_named_only_runs_that_service() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::ok("ok")); // network exists
    docker.on("inspect -f", MockResult::err());

    run_to_string(|buf| run_start(&ctx, &docker, buf, Some("redis")).unwrap());

    assert!(docker.has_call("run -d --name myproject-redis"));
    assert!(!docker.has_call("run -d --name myproject-postgres"), "should not start postgres");
}

#[test]
fn start_skips_already_running() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::ok("ok"));
    docker.on("inspect -f", MockResult::ok("true")); // running

    let out = run_to_string(|buf| run_start(&ctx, &docker, buf, Some("redis")).unwrap());

    assert!(out.contains("myproject-redis is already running"), "{out}");
    assert!(!docker.has_call("run -d --name myproject-redis"));
}

#[test]
fn start_starts_stopped_container() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::ok("ok"));
    docker.set_run_fn(|args| {
        let joined = args.join(" ");
        // running check → false, exists check → true.
        if joined.contains("State.Running") {
            return MockResult::ok("false");
        }
        if joined.contains("State.Status") {
            return MockResult::ok("exited");
        }
        MockResult::ok("")
    });

    run_to_string(|buf| run_start(&ctx, &docker, buf, Some("redis")).unwrap());

    assert!(docker.has_call("start myproject-redis"));
    assert!(!docker.has_call("run -d --name myproject-redis"));
}

#[test]
fn start_readiness_failure_warns_but_succeeds() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::ok("ok"));
    docker.set_run_fn(|args| {
        let joined = args.join(" ");
        if joined.contains("inspect -f") {
            return MockResult::err(); // not running / not created
        }
        if args.first() == Some(&"exec") {
            return MockResult::err(); // readiness poll times out
        }
        MockResult::ok("")
    });

    // Best-effort: the command still returns Ok despite the readiness failure.
    let out = run_to_string(|buf| run_start(&ctx, &docker, buf, Some("redis")).unwrap());
    assert!(out.contains("readiness"), "expected a readiness warning: {out}");
}

#[test]
fn start_per_service_error_does_not_abort_batch() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("network inspect", MockResult::ok("ok"));
    docker.set_run_fn(|args| {
        let joined = args.join(" ");
        if joined.contains("inspect -f") {
            return MockResult::err();
        }
        // postgres run fails; redis run succeeds.
        if joined.contains("run -d --name myproject-postgres") {
            return MockResult::err();
        }
        MockResult::ok("")
    });

    let out = run_to_string(|buf| run_start(&ctx, &docker, buf, None).unwrap());
    assert!(out.contains("⚠ postgres"), "postgres failure should be surfaced: {out}");
    assert!(docker.has_call("run -d --name myproject-redis"), "redis should still start");
}

#[test]
fn start_no_services_configured() {
    let (ctx, _tmp) = ctx_with(BTreeMap::new());
    let docker = MockDocker::new();
    let out = run_to_string(|buf| run_start(&ctx, &docker, buf, None).unwrap());
    assert!(out.contains("No services configured"), "{out}");
    assert_eq!(docker.call_count(), 0, "no docker calls when nothing configured");
}

// --- readiness helpers ---

#[test]
fn wait_for_port_execs_nc_loop() {
    let docker = MockDocker::new();
    wait_for_port(&docker, "myproject-redis", 6379, 30).unwrap();
    assert!(docker.has_call("nc -z localhost 6379"), "expected nc probe");
    assert!(docker.has_call("exec myproject-redis sh -c"));
}

#[test]
fn wait_for_ready_uses_pg_isready_for_per_agent_db() {
    let docker = MockDocker::new();
    wait_for_ready(&docker, "myproject-postgres", &pg_service()).unwrap();
    assert!(docker.has_call("pg_isready"), "postgres readiness should use pg_isready");
    assert!(!docker.has_call("nc -z"), "should not fall back to nc for a pg service");
}

// --- stop ---

#[test]
fn stop_running_service() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::ok("true"));

    run_to_string(|buf| run_stop(&ctx, &docker, buf, Some("redis"), false).unwrap());
    assert!(docker.has_call("stop myproject-redis"));
    assert!(!docker.has_call("rm myproject-redis"), "no --clean → no rm");
}

#[test]
fn stop_not_running_is_informational() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::err()); // not running/exists

    let out = run_to_string(|buf| run_stop(&ctx, &docker, buf, Some("redis"), false).unwrap());
    assert!(out.contains("myproject-redis is not running"), "{out}");
    assert!(!docker.has_call("stop myproject-redis"));
}

#[test]
fn stop_clean_removes_container_and_named_volumes() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::ok("true")); // running + exists

    run_to_string(|buf| run_stop(&ctx, &docker, buf, Some("postgres"), true).unwrap());
    assert!(docker.has_call("stop myproject-postgres"));
    assert!(docker.has_call("rm myproject-postgres"));
    assert!(docker.has_call("volume rm pgdata"), "named volume should be removed");
}

#[test]
fn stop_clean_skips_bind_mount_volumes() {
    let mut svcs = BTreeMap::new();
    svcs.insert(
        "web".to_string(),
        ServiceConfig {
            image: "nginx".into(),
            volumes: vec!["/host/path:/etc/nginx".into(), "named:/data".into()],
            ..ServiceConfig::default()
        },
    );
    let (ctx, _tmp) = ctx_with(svcs);
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::ok("true"));

    run_to_string(|buf| run_stop(&ctx, &docker, buf, Some("web"), true).unwrap());
    assert!(docker.has_call("volume rm named"), "named volume removed");
    assert!(!docker.has_call("volume rm /host/path"), "bind mount must be skipped");
}

// --- status ---

#[test]
fn status_shows_network_and_sorted_table() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.set_run_fn(|args| {
        let joined = args.join(" ");
        // postgres running, redis not created.
        if joined.contains("myproject-postgres") && joined.contains("State.Running") {
            return MockResult::ok("true");
        }
        MockResult::err()
    });

    let out = run_to_string(|buf| run_status(&ctx, &docker, buf).unwrap());
    assert!(out.contains("Network: myproject-network"), "{out}");
    assert!(out.contains("SERVICE"), "header row missing: {out}");
    // postgres appears before redis (sorted).
    let pg = out.find("postgres").unwrap();
    let redis = out.find("redis").unwrap();
    assert!(pg < redis, "services should be sorted by name");
    assert!(out.contains("running"), "postgres should show running: {out}");
    assert!(out.contains("not created"), "redis should show not created: {out}");
    assert!(out.contains("postgres:16") && out.contains("redis:7"), "images: {out}");
}

#[test]
fn status_empty_services() {
    let (ctx, _tmp) = ctx_with(BTreeMap::new());
    let docker = MockDocker::new();
    let out = run_to_string(|buf| run_status(&ctx, &docker, buf).unwrap());
    assert!(out.contains("No services configured"), "{out}");
}

// --- reset ---

#[test]
fn reset_unknown_service_errors() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    let err = run_to_string_err(|buf| run_reset(&ctx, &docker, buf, "mongo"));
    assert!(err.contains("unknown service"), "{err}");
}

#[test]
fn reset_per_agent_db_recreates_all_agent_dbs() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::ok("true")); // service running

    let out = run_to_string(|buf| run_reset(&ctx, &docker, buf, "postgres").unwrap());
    for n in ["agent01", "agent02", "agent03"] {
        let db = format!("myproject_{n}");
        assert!(docker.has_call(&format!("DROP DATABASE IF EXISTS \"{db}\"")), "drop {db}");
        assert!(docker.has_call(&format!("CREATE DATABASE \"{db}\"")), "create {db}");
    }
    assert!(out.contains("Recreated 3 agent databases"), "{out}");
}

#[test]
fn reset_per_agent_db_requires_running_service() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::err()); // not running
    let err = run_to_string_err(|buf| run_reset(&ctx, &docker, buf, "postgres"));
    assert!(err.contains("is not running"), "{err}");
}

#[test]
fn reset_standard_service_stops_and_removes() {
    let (ctx, _tmp) = ctx_with(both_services());
    let docker = MockDocker::new();
    docker.on("inspect -f", MockResult::ok("true")); // running + exists

    run_to_string(|buf| run_reset(&ctx, &docker, buf, "redis").unwrap());
    assert!(docker.has_call("stop myproject-redis"));
    assert!(docker.has_call("rm myproject-redis"));
    // No per-agent DB churn for a standard service.
    assert!(!docker.has_call("CREATE DATABASE"));
}

/// Runs `f` capturing output, expecting an `Err`, and returns the error string.
fn run_to_string_err(f: impl FnOnce(&mut Vec<u8>) -> CmdResult) -> String {
    let mut buf = Vec::new();
    f(&mut buf).unwrap_err().to_string()
}
