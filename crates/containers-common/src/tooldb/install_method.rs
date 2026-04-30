//! `InstallMethod` — how to install a specific tool version.
//!
//! Mirrors the `install_methods[]` items in `version.schema.json`.

use std::collections::BTreeMap;

use serde::de::{Deserializer, Error as _, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};

use super::Dependency;

/// One install strategy for a [`super::ToolVersion`].
///
/// luggage walks `install_methods[]` in array order and picks the first whose
/// [`PlatformPredicate`] matches the target host.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstallMethod {
    /// Method identifier (e.g., `rustup`, `apt`, `tarball`).
    pub name: String,
    /// Predicate restricting which hosts this method applies to.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<PlatformPredicate>,
    /// Download-verification configuration (4-tier model).
    pub verification: Verification,
    /// URL template for the artifact to download.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_url_template: Option<String>,
    /// How to invoke the installer artifact.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invoke: Option<Invoke>,
    /// Steps run after primary install.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub post_install: Option<Vec<PostInstall>>,
    /// Method-level install chain (typically `system_package` deps).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dependencies: Option<Vec<Dependency>>,
}

/// AND-combined predicate restricting an [`InstallMethod`] to specific hosts.
///
/// Each field, when present, is matched against the target host. String values
/// match exactly; arrays match if the host's value is in the array. Missing
/// fields match any host.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PlatformPredicate {
    /// Distro id or array of ids.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os: Option<StringOrVec>,
    /// Distro version or array of versions.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub os_version: Option<StringOrVec>,
    /// CPU architecture or array of architectures.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arch: Option<StringOrVec>,
}

/// Either a single string or a list of strings.
///
/// Mirrors the schema's `oneOf: [string, array of string]` shape used by
/// [`PlatformPredicate`] fields. Always materializes as `Vec<String>`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct StringOrVec(pub Vec<String>);

impl StringOrVec {
    /// True when `value` matches any element.
    #[must_use]
    pub fn contains(&self, value: &str) -> bool {
        self.0.iter().any(|v| v == value)
    }

    /// Iterate over the underlying entries.
    pub fn iter(&self) -> std::slice::Iter<'_, String> {
        self.0.iter()
    }
}

impl<'a> IntoIterator for &'a StringOrVec {
    type Item = &'a String;
    type IntoIter = std::slice::Iter<'a, String>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

impl<'de> Deserialize<'de> for StringOrVec {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        struct StringOrVecVisitor;

        impl<'de> Visitor<'de> for StringOrVecVisitor {
            type Value = StringOrVec;

            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("a string or array of strings")
            }

            fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Self::Value, E> {
                Ok(StringOrVec(vec![v.to_owned()]))
            }

            fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Self::Value, E> {
                Ok(StringOrVec(vec![v]))
            }

            fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Self::Value, A::Error> {
                let mut out = Vec::new();
                while let Some(item) = seq.next_element::<String>()? {
                    out.push(item);
                }
                if out.is_empty() {
                    return Err(A::Error::invalid_length(0, &"at least one string"));
                }
                Ok(StringOrVec(out))
            }
        }

        deserializer.deserialize_any(StringOrVecVisitor)
    }
}

/// Download-verification configuration carrying the 4-tier model.
///
/// `tier` selects the strategy; tier-specific fields land in the matching
/// optional positions. Unrecognised fields land in [`Self::extra`] so a
/// schema bump in containers-db doesn't immediately break luggage.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Verification {
    /// 1 = signature, 2 = pinned checksum, 3 = published checksum, 4 = TOFU.
    pub tier: u8,
    /// Verification algorithm (`sha256`/`sha512`/`gpg`/`sigstore`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub algorithm: Option<String>,
    /// Tier 2 — hex-encoded checksum baked into the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pinned_checksum: Option<String>,
    /// Tier 3 — URL template the publisher serves the checksum at.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checksum_url_template: Option<String>,
    /// Tier 1 (GPG) — publisher public key URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_key_url: Option<String>,
    /// Tier 1 (GPG) — detached signature URL template.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signature_url_template: Option<String>,
    /// Tier 1 (sigstore) — expected cosign identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sigstore_identity: Option<String>,
    /// Tier 1 (sigstore) — expected OIDC issuer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sigstore_issuer: Option<String>,
    /// Tier 4 — explicit TOFU acknowledgment.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tofu: Option<bool>,
}

/// Installer-invocation arguments.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invoke {
    /// Argument vector passed to the installer.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub args: Option<Vec<String>>,
    /// Environment variables exported for the installer process.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<BTreeMap<String, String>>,
}

/// Step run after the primary install.
///
/// Tagged on `kind` per the schema. An `Unknown` fallback variant absorbs
/// future kinds without breaking deserialization of older luggage builds.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PostInstall {
    /// Run a single binary with args.
    Command {
        /// Binary to run.
        command: String,
        /// Argument vector.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        args: Option<Vec<String>>,
    },
    /// Install a crate via `cargo install`.
    CargoInstall {
        /// Crate name.
        package: String,
        /// Crate version (must be exact per the cargo-install policy).
        version: String,
    },
    /// Install a rustup component via `rustup component add`.
    ComponentAdd {
        /// rustup component name.
        component: String,
    },
    /// Forward-compatibility fallback — captures the raw object for unknown kinds.
    #[serde(other)]
    Unknown,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_install_method_string_os() {
        let json = r#"{
            "name": "rustup-init",
            "platform": { "os": "alpine", "arch": ["amd64", "arm64"] },
            "verification": { "tier": 4, "tofu": true }
        }"#;
        let m: InstallMethod = serde_json::from_str(json).unwrap();
        let pred = m.platform.unwrap();
        assert_eq!(pred.os.unwrap().0, vec!["alpine"]);
        assert_eq!(pred.arch.unwrap().0, vec!["amd64", "arm64"]);
    }

    #[test]
    fn parses_install_method_array_os() {
        let json = r#"{
            "name": "rustup-init",
            "platform": { "os": ["debian", "ubuntu", "rhel"] },
            "verification": { "tier": 3, "algorithm": "sha256", "checksum_url_template": "https://example.test/{version}.sha256" }
        }"#;
        let m: InstallMethod = serde_json::from_str(json).unwrap();
        let pred = m.platform.unwrap();
        assert_eq!(pred.os.unwrap().0, vec!["debian", "ubuntu", "rhel"]);
        assert_eq!(m.verification.tier, 3);
    }

    #[test]
    fn string_or_vec_membership() {
        let s = StringOrVec(vec!["debian".into(), "ubuntu".into()]);
        assert!(s.contains("debian"));
        assert!(!s.contains("alpine"));
    }

    #[test]
    fn parses_post_install_variants() {
        let json = r#"[
            { "kind": "component_add", "component": "rustfmt" },
            { "kind": "cargo_install", "package": "ripgrep", "version": "14.0.0" },
            { "kind": "command", "command": "true" }
        ]"#;
        let steps: Vec<PostInstall> = serde_json::from_str(json).unwrap();
        assert_eq!(steps.len(), 3);
        assert!(matches!(steps[0], PostInstall::ComponentAdd { .. }));
        assert!(matches!(steps[1], PostInstall::CargoInstall { .. }));
        assert!(matches!(steps[2], PostInstall::Command { .. }));
    }

    #[test]
    fn unknown_post_install_kind_falls_back() {
        let json = r#"{ "kind": "future_step", "package": "x" }"#;
        let step: PostInstall = serde_json::from_str(json).unwrap();
        assert!(matches!(step, PostInstall::Unknown));
    }

    #[test]
    fn parses_tier1_gpg_verification() {
        let json = r#"{
            "tier": 1,
            "algorithm": "gpg",
            "gpg_key_url": "https://example.test/key",
            "signature_url_template": "https://example.test/{version}.asc"
        }"#;
        let v: Verification = serde_json::from_str(json).unwrap();
        assert_eq!(v.tier, 1);
        assert_eq!(v.algorithm.as_deref(), Some("gpg"));
        assert!(v.gpg_key_url.is_some());
    }
}
