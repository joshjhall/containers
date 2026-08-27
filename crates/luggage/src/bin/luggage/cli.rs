//! `clap` argument types for the `luggage` CLI.
//!
//! These are the parser's surface only — every type here is binary-private
//! (`pub(crate)`), deliberately kept out of the `luggage` library crate so the
//! CLI's shape is not part of the library's public API.

use std::path::PathBuf;

use clap::{Args, Parser, Subcommand, ValueEnum};
use luggage::PolicyPreset;

/// Luggage — catalog loader and version/platform resolver.
#[derive(Parser, Debug)]
#[command(name = "luggage", version, about, long_about = None)]
pub struct Cli {
    /// Enable debug-level tracing output.
    #[arg(short, long, global = true)]
    pub verbose: bool,

    #[command(subcommand)]
    pub command: Commands,
}

#[derive(Subcommand, Debug)]
pub enum Commands {
    /// Resolve `(tool, version, platform)` into a concrete install plan.
    Resolve(ResolveArgs),
    /// Install a tool — download, verify, run installer, validate.
    Install(InstallArgs),
    /// Reconcile `support_matrix` claims against `tested[]` evidence.
    Reconcile(ReconcileArgs),
    /// Catalog maintenance (write-side helpers for the vendored catalog).
    Catalog {
        #[command(subcommand)]
        command: CatalogCommand,
    },
}

#[derive(Subcommand, Debug)]
pub enum CatalogCommand {
    /// Add a tool version by cloning the latest existing version entry.
    ///
    /// Used by the version-bump pipeline to keep the vendored catalog in
    /// lockstep with a Dockerfile pin. Additive and idempotent: a version
    /// already present is a no-op, and `default_version` is never changed.
    AddVersion(CatalogAddVersionArgs),
}

/// `luggage catalog add-version <tool>@<version>` arguments.
#[derive(Args, Debug)]
pub struct CatalogAddVersionArgs {
    /// Catalog tool id with a required `@<version>` suffix (e.g. `rust@1.96.0`).
    pub tool: String,

    /// Path to the catalog root (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    pub catalog: PathBuf,

    /// Upstream release date `YYYY-MM-DD` (defaults to today, UTC).
    #[arg(long)]
    pub released: Option<String>,
}

#[derive(Args, Debug)]
pub struct ResolveArgs {
    /// Catalog tool id (e.g. `rust`, `node`).
    pub tool: String,

    #[command(flatten)]
    pub common: CommonArgs,

    /// Emit JSON instead of human-readable output.
    #[arg(long)]
    pub json: bool,
}

/// CLI fields shared by `resolve` and `install`.
#[derive(Args, Debug)]
pub struct CommonArgs {
    /// Exact or partial version (e.g. `1.95.0`, `1.84`). Mutually exclusive with `--channel`.
    #[arg(long, conflicts_with = "channel")]
    pub version: Option<String>,

    /// Channel name (e.g. `stable`, `nightly`). Mutually exclusive with `--version`.
    #[arg(long)]
    pub channel: Option<String>,

    /// Override target OS (defaults to the value from `/etc/os-release`).
    #[arg(long)]
    pub os: Option<String>,

    /// Override target OS version (defaults to the value from `/etc/os-release`).
    #[arg(long)]
    pub os_version: Option<String>,

    /// Override target architecture (defaults to mapping `std::env::consts::ARCH`).
    #[arg(long)]
    pub arch: Option<String>,

    /// Path to a containers-db checkout (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    pub catalog: PathBuf,

    /// Named policy preset to start from. Defaults to `stibbons`.
    #[arg(long, value_enum)]
    pub policy: Option<PolicyChoice>,

    /// Allow tools whose activity tier is `dormant` or `abandoned`. Lowers
    /// `min_activity` to `Abandoned` regardless of preset.
    #[arg(long)]
    pub allow_abandoned: bool,

    /// Allow versions below the tool's `minimum_recommended` (emits a
    /// warning instead of refusing).
    #[arg(long)]
    pub allow_below_min_recommended: bool,
}

/// `luggage install <tool>[@<version>]` arguments.
///
/// The boolean fields are independent clap flags, so plain `bool`s are the
/// idiomatic shape here rather than a state machine.
#[derive(Args, Debug)]
#[allow(clippy::struct_excessive_bools)]
pub struct InstallArgs {
    /// Catalog tool id with an optional `@<version>` suffix
    /// (e.g. `rust`, `rust@1.95.0`, `node@22`).
    pub tool: String,

    #[command(flatten)]
    pub common: CommonArgs,

    /// Print the substituted install plan as JSON without performing I/O.
    #[arg(long)]
    pub dry_run: bool,

    /// Reinstall even when the idempotency check thinks the tool is current.
    #[arg(long)]
    pub force: bool,

    /// Per-feature log directory.
    #[arg(long, default_value = "/var/log/luggage")]
    pub log_dir: PathBuf,

    /// Where the installer symlinks tool binaries.
    #[arg(long, default_value = "/usr/local/bin")]
    pub bin_root: PathBuf,

    /// Cache root for tool data (`CARGO_HOME` and `RUSTUP_HOME` live under here).
    #[arg(long, default_value = "/cache")]
    pub cache_root: PathBuf,

    /// Scratch directory for downloads.
    #[arg(long, default_value = "/tmp")]
    pub tmp_root: PathBuf,

    /// Override the install user (defaults to `$USERNAME`, then `vscode`,
    /// then `root` if the resolved user doesn't exist on the system).
    #[arg(long)]
    pub user: Option<String>,

    /// Skip system-package installation. Use when the host package
    /// manager is unavailable or already pre-populated.
    #[arg(long)]
    pub skip_system_packages: bool,

    /// Opt out of strict dependency handling: a catalog dependency id with
    /// no system-package mapping is warned-and-skipped instead of aborting
    /// the install. Strict (fail-fast) is the default; evidence-run relies
    /// on it to catch catalog drift, so do not pass this in CI.
    #[arg(long)]
    pub allow_unknown_deps: bool,

    /// Refuse tier-4 TOFU verification instead of accepting it with a
    /// warning. A tier-4 artifact has no publisher checksum, so nothing
    /// establishes its authenticity — pass this where that is unacceptable
    /// (production images), and pin a known-good checksum in the catalog for
    /// any tool it then refuses.
    ///
    /// `REQUIRE_VERIFIED_DOWNLOADS` in the environment does the same thing
    /// (falling back to `PRODUCTION_MODE` when unset), so an existing bash
    /// build configuration keeps working. That is read by
    /// [`require_verified_downloads_from_env`] rather than clap's `env`
    /// attribute on purpose: `env` makes a bool arg *take a value*, which
    /// both breaks `--require-verified-downloads` as a bare switch and turns
    /// the set-but-empty var that build environments commonly export into a
    /// hard CLI error.
    #[arg(long)]
    pub require_verified_downloads: bool,

    /// Write a JSON [`InstallReport`] to this path. Emitted on every
    /// exit path — success, skip, dry-run, or failure — so evidence-run
    /// CI can record a row even when the install itself failed. On the
    /// success path this also captures the resolved versions of installed
    /// system dependencies (best-effort) for the evidence row.
    #[arg(long, value_name = "PATH")]
    pub json_report: Option<PathBuf>,
}

/// CLI mirror of [`luggage::PolicyPreset`].
#[derive(Copy, Clone, Debug, Eq, PartialEq, ValueEnum)]
#[clap(rename_all = "lowercase")]
pub enum PolicyChoice {
    /// Stibbons defaults: refuse below-Maintained, refuse below-min, warn on slow/stale.
    Stibbons,
    /// Igor defaults: accept down to Stale, allow below-min.
    Igor,
    /// Permissive: accept any tier.
    Permissive,
}

impl From<PolicyChoice> for PolicyPreset {
    fn from(value: PolicyChoice) -> Self {
        match value {
            PolicyChoice::Stibbons => Self::Stibbons,
            PolicyChoice::Igor => Self::Igor,
            PolicyChoice::Permissive => Self::Permissive,
        }
    }
}

/// `luggage reconcile [TOOL[@VERSION]]` arguments.
#[derive(Args, Debug)]
pub struct ReconcileArgs {
    /// Catalog target. Omit to reconcile every tool/version; pass a tool id
    /// (`rust`) for all its versions, or `tool@version` (`rust@1.96.0`) for
    /// a single version.
    pub target: Option<String>,

    /// Path to a containers-db checkout (or `CONTAINERS_DB` env var).
    #[arg(long, env = "CONTAINERS_DB", default_value = "../containers-db")]
    pub catalog: PathBuf,

    /// Exit non-zero when any `supported` cell lacks a passing evidence row,
    /// or an `unsupported` cell has one. Use this in CI to block a catalog PR
    /// that claims support it cannot back.
    #[arg(long)]
    pub gate: bool,

    /// Emit JSON instead of human-readable output.
    #[arg(long)]
    pub json: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verify_cli() {
        use clap::CommandFactory;
        Cli::command().debug_assert();
    }
}
