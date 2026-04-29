//! Shared types and state contracts for the containers build system.

pub mod config;
pub mod feature;
pub mod generate;
pub mod template;
pub mod version;

/// Library version (tracks workspace, not container system version).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_set() {
        assert!(!VERSION.is_empty());
    }
}
