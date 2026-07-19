//! Build script: inject the product version into the stibbons binary.
//!
//! Replaces the Go `ldflags` version stamping used by the legacy igor binary.
//! The single source of truth is the repo-root `VERSION` file (also consumed
//! by `bin/release.sh` and the Dockerfile). We resolve it by walking up from
//! this crate's manifest directory so the lookup works from any build cwd,
//! including the release cross-compile legs in `release-binaries.yml`.
//!
//! Emits `STIBBONS_VERSION` for `env!()` use in `main.rs`. If the `VERSION`
//! file cannot be found (e.g. an isolated crate checkout published to a
//! registry), we fall back to the crate's own `CARGO_PKG_VERSION` so the build
//! still succeeds.
//!
//! The pure resolution logic lives in `build_version.rs` (included below) so it
//! can be unit-tested from `tests/build_version.rs` — a build script is not
//! compiled as a test target, so the logic is kept in an `include!`-able file
//! shared by both the build script and the test.

// `Path`/`PathBuf` are brought into scope by the `use` inside the included file.
include!("build_version.rs");

fn main() {
    let manifest_dir =
        std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is always set by cargo");
    let pkg_version =
        std::env::var("CARGO_PKG_VERSION").expect("CARGO_PKG_VERSION is always set by cargo");

    // Re-run the build script when the VERSION file changes so the stamped
    // version stays in sync without a manual clean.
    let mut emit_rerun = |path: &Path| println!("cargo:rerun-if-changed={}", path.display());

    let version = resolve_version_from(&manifest_dir, &pkg_version, &mut emit_rerun);
    println!("cargo:rustc-env=STIBBONS_VERSION={version}");
}
