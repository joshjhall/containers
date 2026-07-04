//! Per-agent `PostgreSQL` database provisioning.
//!
//! When a service in `.igor.yml` sets `per_agent_db: true`, each agent gets its
//! own database named `{project}_agent{nn}` (e.g. `myproject_agent01`) so
//! parallel agents don't share state. These helpers port `agent_db.go`: they
//! run `psql` inside the already-running service container via `docker exec`.

use containers_common::config::ServiceConfig;

use super::context::{AgentError, agent_suffix, is_container_running, service_container_name};
use super::docker::DockerRunner;

/// Default Postgres credentials when `.igor.yml` does not override them.
const DEFAULT_PG_USER: &str = "postgres";
const DEFAULT_PG_PASSWORD: &str = "devpassword";

/// Per-agent database name — `{project}_agent{nn}`.
fn db_name(project: &str, n: u32) -> String {
    format!("{project}_{}", agent_suffix(n))
}

/// Creates per-agent databases for every service with `per_agent_db` set.
///
/// Best-effort at the call site: `agent start` warns rather than aborting if
/// this fails (the service may simply not be up yet).
///
/// # Errors
///
/// Returns [`AgentError::ServiceNotRunning`] if a `per_agent_db` service's
/// container is not running, or a [`DockerError`](super::docker::DockerError)
/// wrapped via `?` if a `psql`/readiness call fails.
pub fn provision_per_agent_dbs(
    docker: &dyn DockerRunner,
    project: &str,
    n: u32,
    services: &std::collections::BTreeMap<String, ServiceConfig>,
) -> Result<(), Box<dyn std::error::Error>> {
    let name = db_name(project, n);

    for (svc_name, svc) in services {
        if !svc.per_agent_db {
            continue;
        }

        let svc_container = service_container_name(project, svc_name);
        if !is_container_running(docker, &svc_container) {
            return Err(Box::new(AgentError::ServiceNotRunning {
                service: svc_name.clone(),
                container: svc_container,
            }));
        }

        let (user, _) = extract_pg_credentials(&svc.environment);
        wait_for_postgres(docker, &svc_container, &user, 30)?;

        // Skip creation if this service's database already exists. Each
        // per_agent_db service is a *separate* container, so `continue` to the
        // next service rather than returning — an early return would silently
        // skip provisioning every later service in the map.
        let check = docker.run(&[
            "exec",
            &svc_container,
            "psql",
            "-U",
            &user,
            "-tc",
            &format!("SELECT 1 FROM pg_database WHERE datname = '{}'", sql_literal(&name)),
        ])?;
        if check.trim() == "1" {
            continue;
        }

        // Quote as a SQL identifier: the DB name embeds the project name from
        // `.igor.yml`, which may contain hyphens (invalid unquoted) or, in the
        // worst case, injection characters. Double-quoting + escaping handles both.
        docker.run(&[
            "exec",
            &svc_container,
            "psql",
            "-U",
            &user,
            "-c",
            &format!("CREATE DATABASE {}", sql_ident(&name)),
        ])?;
    }

    Ok(())
}

/// Escapes a string for use inside a single-quoted SQL string literal
/// (`'...'`) by doubling embedded single quotes.
fn sql_literal(s: &str) -> String {
    s.replace('\'', "''")
}

/// Quotes a string as a SQL identifier (`"..."`), doubling embedded double
/// quotes. Needed because the per-agent DB name embeds the project name, which
/// may contain characters (e.g. hyphens) that are invalid in a bare identifier.
fn sql_ident(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// Blocks until `PostgreSQL` accepts connections (via `pg_isready` inside the
/// container), up to `timeout_secs`.
///
/// # Errors
///
/// Propagates the [`DockerError`](super::docker::DockerError) if the wait
/// command exits non-zero (i.e. the timeout elapsed).
pub fn wait_for_postgres(
    docker: &dyn DockerRunner,
    container: &str,
    user: &str,
    timeout_secs: u32,
) -> Result<(), super::docker::DockerError> {
    let check = format!(
        "timeout {timeout_secs} sh -c 'until pg_isready -U {user} 2>/dev/null; do sleep 1; done'"
    );
    docker.run(&["exec", container, "sh", "-c", &check])?;
    Ok(())
}

/// Parses `POSTGRES_USER` / `POSTGRES_PASSWORD` from a service's env list,
/// falling back to `postgres` / `devpassword`.
#[must_use]
pub fn extract_pg_credentials(environment: &[String]) -> (String, String) {
    let mut user = DEFAULT_PG_USER.to_string();
    let mut password = DEFAULT_PG_PASSWORD.to_string();
    for entry in environment {
        if let Some((key, value)) = entry.split_once('=') {
            match key {
                "POSTGRES_USER" => user = value.to_string(),
                "POSTGRES_PASSWORD" => password = value.to_string(),
                _ => {}
            }
        }
    }
    (user, password)
}

/// Builds the `DATABASE_URL` an agent uses to reach its per-agent database.
#[must_use]
pub fn per_agent_db_url(project: &str, n: u32, svc_name: &str, svc: &ServiceConfig) -> String {
    let name = db_name(project, n);
    let host = service_container_name(project, svc_name);
    let (user, password) = extract_pg_credentials(&svc.environment);
    format!("postgres://{user}:{password}@{host}:{}/{name}", svc.port)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::super::docker::{MockDocker, MockResult};
    use super::*;

    fn pg_service() -> ServiceConfig {
        ServiceConfig {
            image: "postgres:16".into(),
            environment: vec!["POSTGRES_USER=postgres".into()],
            port: 5432,
            per_agent_db: true,
            ..ServiceConfig::default()
        }
    }

    #[test]
    fn db_name_is_project_underscore_padded_suffix() {
        assert_eq!(db_name("myproject", 1), "myproject_agent01");
        assert_eq!(db_name("app", 12), "app_agent12");
    }

    #[test]
    fn provision_errors_when_service_not_running() {
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::err()); // is_container_running → false
        let mut services = BTreeMap::new();
        services.insert("postgres".to_string(), pg_service());

        let err = provision_per_agent_dbs(&docker, "myproject", 1, &services).unwrap_err();
        assert!(err.to_string().contains("is not running"), "{err}");
    }

    #[test]
    fn provision_creates_database_when_absent() {
        let docker = MockDocker::new();
        docker.on("inspect -f", MockResult::ok("true")); // running
        // wait_for_postgres (sh -c) and the existence check both go through the
        // default queue; the existence check returns "" (absent) → CREATE runs.
        let mut services = BTreeMap::new();
        services.insert("postgres".to_string(), pg_service());

        provision_per_agent_dbs(&docker, "myproject", 1, &services).unwrap();
        assert!(
            docker.has_call("CREATE DATABASE \"myproject_agent01\""),
            "expected quoted CREATE DATABASE call"
        );
    }

    #[test]
    fn provision_continues_to_later_service_when_first_db_exists() {
        // Two per_agent_db services. The alphabetically-first (`pg_a`) already
        // has its DB (existence check → "1"); the loop must still provision the
        // second (`pg_b`). A `return` instead of `continue` would skip pg_b.
        let docker = MockDocker::new();
        docker.set_run_fn(|args| {
            let joined = args.join(" ");
            if args.len() >= 2 && args[0] == "inspect" && args[1] == "-f" {
                return MockResult::ok("true"); // both services running
            }
            if joined.contains("pg_isready") {
                return MockResult::ok("");
            }
            // Existence check: pg_a's DB exists, pg_b's does not.
            if joined.contains("SELECT 1 FROM pg_database") {
                return if joined.contains("myproject-pg_a") {
                    MockResult::ok("1")
                } else {
                    MockResult::ok("")
                };
            }
            MockResult::ok("")
        });
        let mut services = BTreeMap::new();
        services.insert("pg_a".to_string(), pg_service());
        services.insert("pg_b".to_string(), pg_service());

        provision_per_agent_dbs(&docker, "myproject", 1, &services).unwrap();
        // pg_b's database must still be created despite pg_a already existing.
        let created_for_b = docker.calls.borrow().iter().any(|c| {
            c.contains(&"myproject-pg_b".to_string()) && c.join(" ").contains("CREATE DATABASE")
        });
        assert!(
            created_for_b,
            "second service's DB should still be created (return-vs-continue bug)"
        );
    }

    #[test]
    fn sql_ident_quotes_and_escapes() {
        assert_eq!(sql_ident("my-app_agent01"), "\"my-app_agent01\"");
        assert_eq!(sql_ident(r#"a"b"#), "\"a\"\"b\"");
    }

    #[test]
    fn sql_literal_doubles_quotes() {
        assert_eq!(sql_literal("x'y"), "x''y");
    }

    #[test]
    fn extract_credentials_defaults() {
        let (user, password) = extract_pg_credentials(&[]);
        assert_eq!(user, "postgres");
        assert_eq!(password, "devpassword");
    }

    #[test]
    fn extract_credentials_overrides() {
        let env = vec![
            "POSTGRES_USER=admin".to_string(),
            "POSTGRES_PASSWORD=s3cret".to_string(),
            "UNRELATED=x".to_string(),
        ];
        let (user, password) = extract_pg_credentials(&env);
        assert_eq!(user, "admin");
        assert_eq!(password, "s3cret");
    }

    #[test]
    fn db_url_format() {
        let svc = ServiceConfig {
            image: "postgres:16".into(),
            environment: vec!["POSTGRES_USER=admin".into(), "POSTGRES_PASSWORD=pw".into()],
            port: 5432,
            per_agent_db: true,
            ..ServiceConfig::default()
        };
        let url = per_agent_db_url("myproject", 1, "postgres", &svc);
        assert_eq!(url, "postgres://admin:pw@myproject-postgres:5432/myproject_agent01");
    }
}
