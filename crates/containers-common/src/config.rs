//! `.igor.yml` configuration schema and YAML parsing.
//!
//! The configuration file tracks project settings, feature selections, version
//! overrides, agent/worktree settings, and service definitions.

use std::collections::BTreeMap;
use std::path::Path;

/// The `.igor.yml` state file.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct IgorConfig {
    /// Schema version for future migration support.
    #[serde(default)]
    pub schema_version: u32,

    /// Git ref (tag/commit) of the containers submodule.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub containers_ref: Option<String>,

    /// Relative path to the containers submodule.
    #[serde(default)]
    pub containers_dir: String,

    /// Project-level settings.
    #[serde(default)]
    pub project: ProjectConfig,

    /// Explicitly selected feature IDs.
    #[serde(default)]
    pub features: Vec<String>,

    /// Maps version arg names to chosen versions (e.g. `PYTHON_VERSION` → `"3.14.0"`).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub versions: BTreeMap<String, String>,

    /// Tracks generated file paths and their SHA-256 hashes.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub generated: BTreeMap<String, String>,

    /// Optional agent/worktree settings.
    #[serde(default, skip_serializing_if = "AgentConfig::is_zero")]
    pub agents: AgentConfig,

    /// Maps service names to their configuration.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub services: BTreeMap<String, ServiceConfig>,
}

/// Project-level configuration.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ProjectConfig {
    /// Project name (used for workspace directory).
    #[serde(default)]
    pub name: String,

    /// Container user.
    #[serde(default)]
    pub username: String,

    /// Base image (e.g. `"debian:trixie-slim"`).
    #[serde(default)]
    pub base_image: String,

    /// Workspace directory inside the container.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub working_dir: Option<String>,
}

/// Agent/worktree settings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct AgentConfig {
    /// Maximum agent count.
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    pub max: u32,

    /// Agent container user.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub username: String,

    /// Docker network name.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub network: String,

    /// Container image tag.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub image_tag: String,

    /// Named Docker volumes for caching.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shared_volumes: Vec<String>,

    /// List of git repos to mount.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repos: Vec<String>,
}

impl AgentConfig {
    /// Returns true when no agent fields have been explicitly set.
    #[must_use]
    pub const fn is_zero(&self) -> bool {
        self.max == 0
            && self.username.is_empty()
            && self.network.is_empty()
            && self.image_tag.is_empty()
            && self.shared_volumes.is_empty()
            && self.repos.is_empty()
    }
}

/// Returns an [`AgentConfig`] with sensible defaults derived from the project
/// name and cache volumes.
#[must_use]
pub fn agent_defaults(project_name: &str, cache_volumes: &[String]) -> AgentConfig {
    AgentConfig {
        max: 5,
        username: "agent".into(),
        network: format!("{project_name}-network"),
        image_tag: "latest".into(),
        shared_volumes: cache_volumes.to_vec(),
        repos: Vec::new(),
    }
}

/// Describes a service container (e.g. postgres, redis).
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ServiceConfig {
    /// Docker image (e.g. `"postgres:16"`).
    #[serde(default)]
    pub image: String,

    /// List of env vars for the service container.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub environment: Vec<String>,

    /// List of volume mounts for the service container.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub volumes: Vec<String>,

    /// Container port the service listens on (used for health checks).
    #[serde(default, skip_serializing_if = "is_zero_u16")]
    pub port: u16,

    /// When true, triggers per-agent database creation and `DATABASE_URL` injection.
    #[serde(default, skip_serializing_if = "is_false")]
    pub per_agent_db: bool,
}

impl IgorConfig {
    /// Reads an `.igor.yml` file.
    ///
    /// # Errors
    ///
    /// Returns an error if the file cannot be read or contains invalid YAML.
    pub fn load(path: impl AsRef<Path>) -> Result<Self, Box<dyn std::error::Error>> {
        let data = std::fs::read_to_string(path)?;
        let cfg: Self = serde_yaml::from_str(&data)?;
        Ok(cfg)
    }

    /// Writes the config to the given path.
    ///
    /// # Errors
    ///
    /// Returns an error if the file cannot be written or the config cannot be
    /// serialized.
    pub fn save(&self, path: impl AsRef<Path>) -> Result<(), Box<dyn std::error::Error>> {
        let data = serde_yaml::to_string(self)?;
        std::fs::write(path, data)?;
        Ok(())
    }
}

// These helpers must take `&T` (not `T`) because serde's `skip_serializing_if`
// requires `fn(&T) -> bool`.
#[expect(clippy::trivially_copy_pass_by_ref)]
const fn is_zero_u32(v: &u32) -> bool {
    *v == 0
}

#[expect(clippy::trivially_copy_pass_by_ref)]
const fn is_zero_u16(v: &u16) -> bool {
    *v == 0
}

#[expect(clippy::trivially_copy_pass_by_ref)]
const fn is_false(v: &bool) -> bool {
    !(*v)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    fn testdata_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
    }

    #[test]
    fn load_minimal() {
        let cfg = IgorConfig::load(testdata_dir().join("minimal.igor.yml")).unwrap();

        assert_eq!(cfg.schema_version, 1);
        assert_eq!(cfg.containers_dir, "containers");
        assert_eq!(cfg.project.name, "myapp");
        assert_eq!(cfg.project.username, "developer");
        assert_eq!(cfg.project.base_image, "debian:trixie-slim");
        assert_eq!(cfg.features, vec!["python", "python_dev"]);
    }

    #[test]
    fn load_fullstack() {
        let cfg = IgorConfig::load(testdata_dir().join("fullstack.igor.yml")).unwrap();

        assert_eq!(cfg.project.name, "fullstack");
        assert_eq!(cfg.project.username, "dev");
        assert_eq!(cfg.project.base_image, "debian:bookworm-slim");
        assert_eq!(cfg.features.len(), 17);

        let feature_set: HashSet<&str> = cfg.features.iter().map(String::as_str).collect();
        for want in
            ["python", "node", "rust", "golang", "dev_tools", "docker", "kubernetes", "ollama"]
        {
            assert!(feature_set.contains(want), "missing feature {want}");
        }
    }

    #[test]
    fn load_with_agents() {
        let cfg = IgorConfig::load(testdata_dir().join("agents.igor.yml")).unwrap();

        assert_eq!(cfg.agents.max, 3);
        assert_eq!(cfg.agents.username, "worker");
        assert_eq!(cfg.agents.network, "myapp-dev-network");
        assert_eq!(cfg.agents.image_tag, "v2.0");
        assert_eq!(cfg.agents.shared_volumes, vec!["pip-cache:/cache/pip", "npm-cache:/cache/npm"]);
        assert_eq!(cfg.agents.repos, vec!["myapp", "myapp-frontend"]);
    }

    #[test]
    fn load_without_agents() {
        let cfg = IgorConfig::load(testdata_dir().join("minimal.igor.yml")).unwrap();
        assert!(cfg.agents.is_zero(), "agents should be zero for minimal config");
    }

    #[test]
    fn load_with_services() {
        let cfg = IgorConfig::load(testdata_dir().join("services.igor.yml")).unwrap();

        assert_eq!(cfg.services.len(), 2);

        let pg = cfg.services.get("postgres").expect("missing postgres service");
        assert_eq!(pg.image, "postgres:16");
        assert_eq!(pg.port, 5432);
        assert!(pg.per_agent_db);
        assert_eq!(pg.environment.len(), 2);
        assert_eq!(pg.volumes.len(), 1);

        let redis = cfg.services.get("redis").expect("missing redis service");
        assert_eq!(redis.image, "redis:7");
        assert_eq!(redis.port, 6379);
        assert!(!redis.per_agent_db);
    }

    #[test]
    fn load_without_services() {
        let cfg = IgorConfig::load(testdata_dir().join("minimal.igor.yml")).unwrap();
        assert!(cfg.services.is_empty());
    }

    #[test]
    fn load_nonexistent_file() {
        let result = IgorConfig::load("/nonexistent/path/to/.igor.yml");
        assert!(result.is_err());
    }

    #[test]
    fn load_malformed_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bad.yml");
        std::fs::write(&path, ":\n  :\n    - [\ninvalid").unwrap();

        let result = IgorConfig::load(&path);
        assert!(result.is_err());
    }

    #[test]
    fn load_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("empty.yml");
        std::fs::write(&path, "").unwrap();

        let cfg = IgorConfig::load(&path).unwrap();
        assert_eq!(cfg.schema_version, 0);
        assert!(cfg.features.is_empty());
    }

    #[test]
    fn test_agent_defaults() {
        let cache_vols = vec!["pip-cache:/cache/pip".into(), "npm-cache:/cache/npm".into()];
        let defaults = agent_defaults("myproject", &cache_vols);

        assert_eq!(defaults.max, 5);
        assert_eq!(defaults.username, "agent");
        assert_eq!(defaults.network, "myproject-network");
        assert_eq!(defaults.image_tag, "latest");
        assert_eq!(defaults.shared_volumes, cache_vols);
        assert!(defaults.repos.is_empty());
    }

    #[test]
    fn test_agent_defaults_empty_cache_volumes() {
        let defaults = agent_defaults("proj", &[]);
        assert!(defaults.shared_volumes.is_empty());
    }

    #[test]
    fn save_roundtrip() {
        let original = IgorConfig {
            schema_version: 1,
            containers_dir: "containers".into(),
            project: ProjectConfig {
                name: "roundtrip-test".into(),
                username: "testuser".into(),
                base_image: "debian:trixie-slim".into(),
                ..ProjectConfig::default()
            },
            features: vec!["python".into(), "python_dev".into(), "node".into()],
            versions: BTreeMap::from([
                ("PYTHON_VERSION".into(), "3.14.0".into()),
                ("NODE_VERSION".into(), "22.12.0".into()),
            ]),
            generated: BTreeMap::from([
                (".devcontainer/docker-compose.yml".into(), "abc123".into()),
                (".igor.yml".into(), "def456".into()),
            ]),
            agents: AgentConfig {
                max: 3,
                username: "worker".into(),
                network: "roundtrip-network".into(),
                image_tag: "v1.0".into(),
                shared_volumes: vec!["pip-cache:/cache/pip".into()],
                repos: vec!["myrepo".into()],
            },
            ..IgorConfig::default()
        };

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".igor.yml");

        original.save(&path).unwrap();
        let reloaded = IgorConfig::load(&path).unwrap();

        assert_eq!(reloaded.schema_version, original.schema_version);
        assert_eq!(reloaded.containers_dir, original.containers_dir);
        assert_eq!(reloaded.project.name, original.project.name);
        assert_eq!(reloaded.project.username, original.project.username);
        assert_eq!(reloaded.project.base_image, original.project.base_image);
        assert_eq!(reloaded.features, original.features);
        assert_eq!(reloaded.versions, original.versions);
        assert_eq!(reloaded.generated, original.generated);
        assert_eq!(reloaded.agents.max, original.agents.max);
        assert_eq!(reloaded.agents.username, original.agents.username);
        assert_eq!(reloaded.agents.network, original.agents.network);
        assert_eq!(reloaded.agents.image_tag, original.agents.image_tag);
        assert_eq!(reloaded.agents.shared_volumes, original.agents.shared_volumes);
        assert_eq!(reloaded.agents.repos, original.agents.repos);
    }

    #[test]
    fn save_to_nonexistent_dir() {
        let cfg = IgorConfig {
            schema_version: 1,
            features: vec!["python".into()],
            ..IgorConfig::default()
        };

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("subdir").join("config.yml");

        let result = cfg.save(&path);
        assert!(result.is_err());
    }
}
