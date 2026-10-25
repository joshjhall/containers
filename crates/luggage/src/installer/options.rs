//! [`InstallerOptions`]: the installer's configuration and its validation.
//!
//! Validation rejects rather than clamps. That matches the CLI's
//! malformed-is-fatal contract for the same settings: a caller who passed a
//! zero deadline should hear about it, not silently get a limit they did not
//! choose. The bounds are the ones the env parsers enforce, so the library
//! and CLI paths accept exactly the same values.

use std::path::PathBuf;
use std::time::Duration;

use crate::error::{LuggageError, Result};

use super::{idempotency, methods};

/// Installer configuration.
///
/// Every field is public, so a hand-built value can carry a degenerate
/// setting no CLI path would produce. [`super::Installer::with_options`] and
/// [`super::Installer::with_runners`] therefore run [`Self::validate`] and
/// refuse such a value rather than clamping it (#1399).
///
/// The flags are independent install toggles, not a state machine, so the
/// plain-struct shape is the clearest carrier despite the bool count.
#[derive(Debug, Clone)]
#[allow(clippy::struct_excessive_bools)]
pub struct InstallerOptions {
    /// Skip side-effects; build the plan and return it.
    pub dry_run: bool,
    /// Bypass the idempotency check and reinstall regardless.
    pub force: bool,
    /// Per-feature log directory (`/var/log/luggage/` in production).
    pub log_dir: PathBuf,
    /// Where binaries are symlinked (default `/usr/local/bin`). Tests override.
    pub bin_root: PathBuf,
    /// Cache root for tool data (default `/cache`). Tests override.
    pub cache_root: PathBuf,
    /// Scratch directory for downloads. Defaults to `/tmp`.
    pub tmp_root: PathBuf,
    /// Optional override for the install user; falls back to `$USERNAME`.
    pub user_override: Option<String>,
    /// When `true`, the installer also runs `apt-get update && apt-get
    /// install -y ...` (or distro equivalent) for catalog dependencies.
    /// Defaults to `true`; tests turn it off to stay hermetic.
    pub install_system_packages: bool,
    /// When `true`, after a successful install the installer queries the host
    /// package manager for each dependency's resolved version and records
    /// them on [`super::InstallReport::dependencies`]. Defaults to `false`; the CLI
    /// turns it on only when `--json-report` is requested (the sole consumer)
    /// so ordinary installs and hermetic tests skip the extra queries.
    pub record_dependency_versions: bool,
    /// When `true` (the default), a catalog dependency id with no
    /// system-package mapping is a hard error
    /// ([`LuggageError::UnknownDependency`]) rather than a warn-and-skip.
    /// The CLI's `--allow-unknown-deps` flag sets this to `false`.
    pub fail_on_unknown_deps: bool,
    /// When `true`, a tier-4 (TOFU) verification is refused outright rather
    /// than accepted with a warning — the artifact has no publisher checksum,
    /// so nothing establishes its authenticity. Defaults to `false`, matching
    /// the bash build's `REQUIRE_VERIFIED_DOWNLOADS` default; the CLI's
    /// `--require-verified-downloads` flag (same env var) sets it.
    pub require_verified_downloads: bool,
    /// Ceiling on total decompressed bytes a `binary-tarball` install may
    /// produce. Guards the build host's disk against a decompression bomb —
    /// a small artifact that expands enormously. Defaults to
    /// [`methods::archive_limit::DEFAULT_MAX_EXTRACT_BYTES`] (2 GiB); the CLI
    /// reads `LUGGAGE_MAX_EXTRACT_BYTES` to override it.
    pub max_extract_bytes: u64,
    /// Deadline for each version probe — the idempotency pre-check and the
    /// post-install validation. Defaults to
    /// [`idempotency::VERSION_PROBE_TIMEOUT`] (10s); the CLI reads
    /// `LUGGAGE_VERSION_PROBE_TIMEOUT` (seconds) to override it, for hosts
    /// where a correct probe is just slow (qemu emulation, a cold cache).
    pub version_probe_timeout: Duration,
}

impl Default for InstallerOptions {
    fn default() -> Self {
        Self {
            dry_run: false,
            force: false,
            log_dir: PathBuf::from("/var/log/luggage"),
            bin_root: PathBuf::from("/usr/local/bin"),
            cache_root: PathBuf::from("/cache"),
            tmp_root: PathBuf::from("/tmp"),
            user_override: None,
            install_system_packages: true,
            record_dependency_versions: false,
            fail_on_unknown_deps: true,
            require_verified_downloads: false,
            max_extract_bytes: methods::archive_limit::DEFAULT_MAX_EXTRACT_BYTES,
            version_probe_timeout: idempotency::VERSION_PROBE_TIMEOUT,
        }
    }
}

impl InstallerOptions {
    /// Reject a setting that would make every install fail in a confusing way.
    ///
    /// - `version_probe_timeout` must lie within
    ///   [`idempotency::MIN_VERSION_PROBE_TIMEOUT`] and
    ///   [`idempotency::MAX_VERSION_PROBE_TIMEOUT`]. A zero or tiny deadline
    ///   kills every probe on its first poll: the idempotency pre-check never
    ///   skips and post-install validation always fails.
    /// - `max_extract_bytes` must be non-zero, or every archive is refused.
    ///
    /// # Errors
    ///
    /// [`LuggageError::Catalog`] naming the offending field.
    pub fn validate(&self) -> Result<()> {
        let timeout = self.version_probe_timeout;
        if timeout < idempotency::MIN_VERSION_PROBE_TIMEOUT
            || timeout > idempotency::MAX_VERSION_PROBE_TIMEOUT
        {
            return Err(LuggageError::Catalog(format!(
                "InstallerOptions.version_probe_timeout is {timeout:?}, outside the accepted \
                 {:?}..={:?} range; the default is {:?}",
                idempotency::MIN_VERSION_PROBE_TIMEOUT,
                idempotency::MAX_VERSION_PROBE_TIMEOUT,
                idempotency::VERSION_PROBE_TIMEOUT,
            )));
        }
        if self.max_extract_bytes == 0 {
            return Err(LuggageError::Catalog(format!(
                "InstallerOptions.max_extract_bytes is 0, which would refuse every archive; \
                 the default is {} bytes",
                methods::archive_limit::DEFAULT_MAX_EXTRACT_BYTES,
            )));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn with_timeout(timeout: Duration) -> InstallerOptions {
        InstallerOptions { version_probe_timeout: timeout, ..InstallerOptions::default() }
    }

    fn catalog_msg(opts: &InstallerOptions) -> String {
        match opts.validate().unwrap_err() {
            LuggageError::Catalog(msg) => msg,
            other => panic!("expected Catalog, got {other:?}"),
        }
    }

    #[test]
    fn default_options_validate() {
        InstallerOptions::default().validate().unwrap();
    }

    #[test]
    fn degenerate_version_probe_timeouts_are_rejected() {
        let one_day = idempotency::MAX_VERSION_PROBE_TIMEOUT;
        for bad in [Duration::ZERO, Duration::from_millis(500), one_day + Duration::from_secs(1)] {
            let msg = catalog_msg(&with_timeout(bad));
            assert!(msg.contains("version_probe_timeout"), "{bad:?}: {msg}");
            assert!(msg.contains(&format!("{bad:?}")), "{bad:?} must be named: {msg}");
        }
    }

    #[test]
    fn version_probe_timeout_bounds_are_inclusive() {
        with_timeout(Duration::from_secs(1)).validate().unwrap();
        with_timeout(Duration::from_hours(24)).validate().unwrap();
    }

    #[test]
    fn zero_max_extract_bytes_is_rejected() {
        let opts = InstallerOptions { max_extract_bytes: 0, ..InstallerOptions::default() };
        let msg = catalog_msg(&opts);
        assert!(msg.contains("max_extract_bytes"), "got: {msg}");

        InstallerOptions { max_extract_bytes: 1, ..InstallerOptions::default() }
            .validate()
            .unwrap();
    }

    /// The check is wired into both constructors, not just available as a
    /// helper: a degenerate value handed to either one is refused up front,
    /// and the refusal is `validate`'s own (it names the field), not some
    /// other `Catalog` error raised earlier.
    #[test]
    fn both_constructors_refuse_invalid_options() {
        use std::sync::Arc;

        use crate::installer::Installer;
        use crate::installer::download::UreqClient;
        use crate::installer::methods::ProcessRunner;

        let cases = [
            (with_timeout(Duration::ZERO), "version_probe_timeout"),
            (
                InstallerOptions { max_extract_bytes: 0, ..InstallerOptions::default() },
                "max_extract_bytes",
            ),
        ];
        for (bad, field) in cases {
            let via_options = Installer::with_options(bad.clone()).map(|_| ());
            let via_runners = Installer::with_runners(
                bad,
                Arc::new(UreqClient::default()),
                Arc::new(ProcessRunner),
            )
            .map(|_| ());
            for (ctor, got) in [("with_options", via_options), ("with_runners", via_runners)] {
                match got {
                    Err(LuggageError::Catalog(msg)) => {
                        assert!(msg.contains(field), "{ctor} must name {field}, got: {msg}");
                    }
                    other => panic!("{ctor} with bad {field}: expected Catalog, got {other:?}"),
                }
            }
        }
    }

    /// The library bounds and the CLI env parsers accept exactly the same
    /// values (#1399): every value a parser accepts validates, and the
    /// parsers refuse the values just outside `validate`'s range. Without
    /// this the two could drift — a parser-accepted value would then fail
    /// later at the constructor with an error naming the struct field rather
    /// than the env var the operator actually set.
    #[test]
    fn validate_accepts_exactly_what_the_env_parsers_accept() {
        use crate::installer::idempotency::{
            MAX_VERSION_PROBE_TIMEOUT, MIN_VERSION_PROBE_TIMEOUT, parse_version_probe_timeout,
        };
        use crate::installer::methods::archive_limit::parse_max_extract_bytes;

        let min = MIN_VERSION_PROBE_TIMEOUT.as_secs().to_string();
        let max = MAX_VERSION_PROBE_TIMEOUT.as_secs().to_string();
        for raw in [None, Some(min.as_str()), Some(max.as_str())] {
            let parsed = parse_version_probe_timeout(raw).unwrap();
            with_timeout(parsed).validate().unwrap();
        }
        let below = (MIN_VERSION_PROBE_TIMEOUT.as_secs() - 1).to_string();
        let above = (MAX_VERSION_PROBE_TIMEOUT.as_secs() + 1).to_string();
        for raw in [below.as_str(), above.as_str()] {
            assert!(parse_version_probe_timeout(Some(raw)).is_err(), "parser accepted {raw}");
        }

        for raw in [None, Some("1")] {
            let max_extract_bytes = parse_max_extract_bytes(raw).unwrap();
            InstallerOptions { max_extract_bytes, ..InstallerOptions::default() }
                .validate()
                .unwrap();
        }
        assert!(parse_max_extract_bytes(Some("0")).is_err());
    }
}
