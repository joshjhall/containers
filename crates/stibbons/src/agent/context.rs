//! Resolved agent configuration and Docker container helpers.
//!
//! [`AgentContext`] is the Rust port of the Go `agentContext`: it loads
//! `.igor.yml`, resolves the enabled feature set, and applies the agent-config
//! defaults (max 5, user `agent`, network `{project}-network`, tag `latest`,
//! repos `[project]`) that every `agent` subcommand shares.
//!
//! Unlike the Go original — which stored a `DockerRunner` on the context and
//! injected a test double through a package-global — the context here holds no
//! Docker handle. Commands receive `&dyn DockerRunner` separately, which keeps
//! `load` a pure config read and makes the container helpers below trivially
//! mockable.

use std::path::{Path, PathBuf};

use containers_common::config::IgorConfig;
use containers_common::feature::{Feature, Registry, resolve};

use super::docker::DockerRunner;

/// Errors surfaced by agent commands beyond a raw [`DockerError`](super::docker::DockerError).
#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    /// No `.igor.yml` in the working directory.
    #[error("no .igor.yml found; run `stibbons init` first")]
    NoConfig,

    /// `.igor.yml` could not be read or parsed.
    #[error("loading .igor.yml: {0}")]
    Config(#[source] Box<dyn std::error::Error>),

    /// The agent-number argument was not an integer.
    #[error("invalid agent number {arg:?}: must be an integer")]
    NotAnInteger {
        /// The offending argument.
        arg: String,
    },

    /// The agent number was outside `1..=max`.
    #[error("agent number must be between 1 and {max}")]
    OutOfRange {
        /// The configured agent maximum.
        max: u32,
    },

    /// The agent image has not been built yet.
    #[error("image {image}:{tag} not found; run `stibbons agent build` first")]
    ImageMissing {
        /// Image name (`{project}-agent`).
        image: String,
        /// Image tag.
        tag: String,
    },

    /// A named container does not exist (e.g. `agent logs` on an uncreated agent).
    #[error("container {0} does not exist")]
    ContainerMissing(String),

    /// The readiness or running wait exceeded the timeout.
    #[error("timeout: container {name} is not running after {secs}s")]
    ConnectTimeout {
        /// Container name waited on.
        name: String,
        /// Timeout in seconds.
        secs: u64,
    },

    /// A required supporting service container is not running.
    #[error("service {service} ({container}) is not running; run `stibbons services start` first")]
    ServiceNotRunning {
        /// Service name from `.igor.yml`.
        service: String,
        /// Resolved service container name.
        container: String,
    },
}

/// Fully resolved configuration shared by every `agent` subcommand.
#[derive(Debug, Clone)]
pub struct AgentContext {
    /// Parsed `.igor.yml` (services, versions, etc. are read from here).
    pub cfg: IgorConfig,
    /// Project name (`cfg.project.name`).
    pub project: String,
    /// Agent image name — `{project}-agent`.
    pub image_name: String,
    /// Image tag (default `latest`).
    pub image_tag: String,
    /// Docker network name (default `{project}-network`).
    pub network: String,
    /// Container user (default `agent`).
    pub username: String,
    /// Maximum agent number (default 5).
    pub max_agents: u32,
    /// Repos to mount (default `[project]`).
    pub repos: Vec<String>,
    /// Shared cache volumes (falls back to the features' dedup'd cache volumes).
    pub shared_volumes: Vec<String>,
    /// Host base directory for repo/worktree mounts (default `/workspace`).
    pub base_dir: PathBuf,
    /// Absolute path to the containers build context (holds `Dockerfile`).
    pub containers_dir: PathBuf,
    /// Enabled features in registry order (for build args).
    pub features: Vec<Feature>,
}

impl AgentContext {
    /// Loads and resolves the agent context from an `.igor.yml` path.
    ///
    /// # Errors
    ///
    /// Returns [`AgentError::NoConfig`] if the file is absent, or
    /// [`AgentError::Config`] on a read/parse failure.
    pub fn load(cfg_path: &Path) -> Result<Self, AgentError> {
        if !cfg_path.exists() {
            return Err(AgentError::NoConfig);
        }
        let cfg = IgorConfig::load(cfg_path).map_err(AgentError::Config)?;

        let reg = Registry::new();
        let explicit: std::collections::HashSet<String> = cfg.features.iter().cloned().collect();
        let selection = resolve(&explicit, &reg);
        let all = selection.all();

        // Enabled features in registration order; dedup cache volumes the same way.
        let features: Vec<Feature> = reg.all().filter(|f| all.contains(&f.id)).cloned().collect();
        let mut seen = std::collections::HashSet::new();
        let mut cache_volumes = Vec::new();
        for f in &features {
            for v in &f.cache_volumes {
                if seen.insert(v.clone()) {
                    cache_volumes.push(v.clone());
                }
            }
        }

        let ac = &cfg.agents;
        let max_agents = if ac.max == 0 { 5 } else { ac.max };
        let username =
            if ac.username.is_empty() { "agent".to_string() } else { ac.username.clone() };
        let network = if ac.network.is_empty() {
            format!("{}-network", cfg.project.name)
        } else {
            ac.network.clone()
        };
        let image_tag =
            if ac.image_tag.is_empty() { "latest".to_string() } else { ac.image_tag.clone() };
        let shared_volumes =
            if ac.shared_volumes.is_empty() { cache_volumes } else { ac.shared_volumes.clone() };
        let repos =
            if ac.repos.is_empty() { vec![cfg.project.name.clone()] } else { ac.repos.clone() };

        // base_dir: parent of the working dir, or /workspace.
        let base_dir = cfg
            .project
            .working_dir
            .as_deref()
            .and_then(|wd| Path::new(wd).parent().map(Path::to_path_buf))
            .unwrap_or_else(|| PathBuf::from("/workspace"));

        // containers_dir: absolute as-is, else <base_dir>/<project>/<containers_dir>.
        let raw_containers =
            if cfg.containers_dir.is_empty() { "containers" } else { &cfg.containers_dir };
        let containers_path = Path::new(raw_containers);
        let containers_dir = if containers_path.is_absolute() {
            containers_path.to_path_buf()
        } else {
            base_dir.join(&cfg.project.name).join(raw_containers)
        };

        Ok(Self {
            image_name: format!("{}-agent", cfg.project.name),
            project: cfg.project.name.clone(),
            image_tag,
            network,
            username,
            max_agents,
            repos,
            shared_volumes,
            base_dir,
            containers_dir,
            features,
            cfg,
        })
    }
}

/// Docker container name for agent `n` — `{project}-agent-{n}` (decimal `n`).
#[must_use]
pub fn container_name(project: &str, n: u32) -> String {
    format!("{project}-agent-{n}")
}

/// Worktree/DB suffix for agent `n` — zero-padded `agent{nn}` (e.g. `agent01`).
#[must_use]
pub fn agent_suffix(n: u32) -> String {
    format!("agent{n:02}")
}

/// Parses and range-checks an agent-number argument against `max`.
///
/// # Errors
///
/// [`AgentError::NotAnInteger`] if `arg` is not a base-10 integer, or
/// [`AgentError::OutOfRange`] if it falls outside `1..=max`.
pub fn validate_agent_num(arg: &str, max: u32) -> Result<u32, AgentError> {
    let n: u32 = arg.parse().map_err(|_| AgentError::NotAnInteger { arg: arg.to_string() })?;
    if n < 1 || n > max {
        return Err(AgentError::OutOfRange { max });
    }
    Ok(n)
}

/// True when a container exists and is currently running.
pub fn is_container_running(docker: &dyn DockerRunner, name: &str) -> bool {
    matches!(docker.run(&["inspect", "-f", "{{.State.Running}}", name]), Ok(out) if out == "true")
}

/// True when a container exists (running or stopped).
pub fn container_exists(docker: &dyn DockerRunner, name: &str) -> bool {
    docker.run(&["inspect", "-f", "{{.State.Status}}", name]).is_ok()
}

/// True when a local image `name:tag` exists.
pub fn image_exists(docker: &dyn DockerRunner, name: &str, tag: &str) -> bool {
    docker.run(&["image", "inspect", &format!("{name}:{tag}")]).is_ok()
}

/// Service container name — `{project}-{service}` (ported from `services.go`).
#[must_use]
pub fn service_container_name(project: &str, service: &str) -> String {
    format!("{project}-{service}")
}

/// Creates the Docker `network` if `docker network inspect` reports it absent,
/// announcing the creation on `out`. A no-op when the network already exists.
///
/// Shared by `agent start` and `services start` so both attach containers to the
/// same network with identical output.
///
/// # Errors
///
/// Propagates the [`DockerError`](super::docker::DockerError) from
/// `docker network create` when the network is missing and creation fails.
pub fn ensure_network(
    docker: &dyn DockerRunner,
    out: &mut dyn std::io::Write,
    network: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if docker.run(&["network", "inspect", network]).is_err() {
        docker.run(&["network", "create", network])?;
        writeln!(out, "Created network {network}")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use containers_common::config::{AgentConfig, ProjectConfig};

    use super::super::test_support::load_ctx;
    use super::*;

    #[test]
    fn test_container_name() {
        assert_eq!(container_name("myproject", 1), "myproject-agent-1");
        assert_eq!(container_name("myproject", 5), "myproject-agent-5");
        assert_eq!(container_name("app", 10), "app-agent-10");
    }

    #[test]
    fn test_agent_suffix() {
        assert_eq!(agent_suffix(1), "agent01");
        assert_eq!(agent_suffix(5), "agent05");
        assert_eq!(agent_suffix(12), "agent12");
    }

    #[test]
    fn test_validate_agent_num() {
        assert_eq!(validate_agent_num("1", 5).unwrap(), 1);
        assert_eq!(validate_agent_num("5", 5).unwrap(), 5);
        assert_eq!(validate_agent_num("3", 3).unwrap(), 3);

        assert!(matches!(validate_agent_num("0", 5), Err(AgentError::OutOfRange { max: 5 })));
        assert!(matches!(validate_agent_num("6", 5), Err(AgentError::OutOfRange { max: 5 })));
        assert!(matches!(validate_agent_num("4", 3), Err(AgentError::OutOfRange { max: 3 })));
        assert!(matches!(validate_agent_num("abc", 5), Err(AgentError::NotAnInteger { .. })));

        // Error messages match the retired Go CLI wording.
        assert!(validate_agent_num("0", 5).unwrap_err().to_string().contains("between 1 and 5"));
        assert!(
            validate_agent_num("abc", 5).unwrap_err().to_string().contains("must be an integer")
        );
    }

    #[test]
    fn load_defaults() {
        let cfg = IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig { name: "testapp".into(), ..ProjectConfig::default() },
            features: vec!["python".into()],
            ..IgorConfig::default()
        };
        let (ctx, _tmp) = load_ctx(cfg);

        assert_eq!(ctx.project, "testapp");
        assert_eq!(ctx.image_name, "testapp-agent");
        assert_eq!(ctx.image_tag, "latest");
        assert_eq!(ctx.network, "testapp-network");
        assert_eq!(ctx.username, "agent");
        assert_eq!(ctx.max_agents, 5);
        assert_eq!(ctx.repos, vec!["testapp".to_string()]);
        assert!(!ctx.shared_volumes.is_empty(), "expected python cache volumes");
    }

    #[test]
    fn load_custom_config() {
        let cfg = IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig { name: "myapp".into(), ..ProjectConfig::default() },
            features: vec!["golang".into()],
            agents: AgentConfig {
                max: 3,
                username: "coder".into(),
                network: "custom-net".into(),
                image_tag: "v2".into(),
                shared_volumes: vec!["data:/data".into()],
                repos: vec!["myapp".into(), "shared-lib".into()],
            },
            ..IgorConfig::default()
        };
        let (ctx, _tmp) = load_ctx(cfg);

        assert_eq!(ctx.max_agents, 3);
        assert_eq!(ctx.username, "coder");
        assert_eq!(ctx.network, "custom-net");
        assert_eq!(ctx.image_tag, "v2");
        assert_eq!(ctx.shared_volumes, vec!["data:/data".to_string()]);
        assert_eq!(ctx.repos, vec!["myapp".to_string(), "shared-lib".to_string()]);
    }

    #[test]
    fn load_missing_config_errors() {
        let err = AgentContext::load(Path::new("/nonexistent/.igor.yml")).unwrap_err();
        assert!(matches!(err, AgentError::NoConfig));
    }
}
