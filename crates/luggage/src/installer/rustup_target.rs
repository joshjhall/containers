//! Map a [`crate::Platform`] to a rustup target triple.
//!
//! rustup's distribution URLs are keyed by target triples like
//! `x86_64-unknown-linux-gnu`. The catalog uses the abstract
//! os/arch vocabulary (`debian`/`amd64` etc.) so this helper bridges the
//! two for the `{rustup_target}` URL placeholder.
//!
//! # Pilot scope
//!
//! Only the four combinations rust@1.95.0 supports are wired in. Other
//! platforms return [`crate::LuggageError::NotImplemented`]; future tools
//! may need a different mapping function entirely.

use crate::Platform;
use crate::error::{LuggageError, Result};

/// Pick the rustup target triple for `platform`.
///
/// # Errors
///
/// - [`LuggageError::NotImplemented`] when the (os, arch) pair has no entry
///   in the table. Issue follow-ups may extend this.
pub fn rustup_target_for(platform: &Platform) -> Result<&'static str> {
    Ok(match (platform.os.as_str(), platform.arch.as_str()) {
        ("debian" | "ubuntu" | "rhel", "amd64") => "x86_64-unknown-linux-gnu",
        ("debian" | "ubuntu" | "rhel", "arm64") => "aarch64-unknown-linux-gnu",
        ("alpine", "amd64") => "x86_64-unknown-linux-musl",
        ("alpine", "arm64") => "aarch64-unknown-linux-musl",
        _ => return Err(LuggageError::NotImplemented("rustup_target for this platform")),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(os: &str, arch: &str) -> Platform {
        Platform { os: os.into(), os_version: None, arch: arch.into() }
    }

    #[test]
    fn debian_amd64_maps_to_gnu_triple() {
        assert_eq!(rustup_target_for(&p("debian", "amd64")).unwrap(), "x86_64-unknown-linux-gnu");
    }

    #[test]
    fn debian_arm64_maps_to_gnu_triple() {
        assert_eq!(rustup_target_for(&p("debian", "arm64")).unwrap(), "aarch64-unknown-linux-gnu");
    }

    #[test]
    fn ubuntu_amd64_maps_to_gnu_triple() {
        assert_eq!(rustup_target_for(&p("ubuntu", "amd64")).unwrap(), "x86_64-unknown-linux-gnu");
    }

    #[test]
    fn rhel_arm64_maps_to_gnu_triple() {
        assert_eq!(rustup_target_for(&p("rhel", "arm64")).unwrap(), "aarch64-unknown-linux-gnu");
    }

    #[test]
    fn alpine_amd64_maps_to_musl_triple() {
        assert_eq!(rustup_target_for(&p("alpine", "amd64")).unwrap(), "x86_64-unknown-linux-musl");
    }

    #[test]
    fn alpine_arm64_maps_to_musl_triple() {
        assert_eq!(rustup_target_for(&p("alpine", "arm64")).unwrap(), "aarch64-unknown-linux-musl");
    }

    #[test]
    fn unknown_platform_returns_not_implemented() {
        let err = rustup_target_for(&p("windows", "amd64")).unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }

    #[test]
    fn unknown_arch_returns_not_implemented() {
        let err = rustup_target_for(&p("debian", "riscv64")).unwrap_err();
        assert!(matches!(err, LuggageError::NotImplemented(_)));
    }
}
