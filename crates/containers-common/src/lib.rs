//! Shared types and state contracts for the containers build system.

pub mod feature;

/// Library version (tracks workspace, not container system version).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Placeholder configuration type for future use.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Config {
    /// Project name for the container build.
    pub project_name: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_set() {
        assert!(!VERSION.is_empty());
    }

    #[test]
    fn config_roundtrip() {
        let config = Config { project_name: "test".to_string() };
        let json = serde_json::to_string(&config).expect("serialize");
        let parsed: Config = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed.project_name, "test");
    }
}
