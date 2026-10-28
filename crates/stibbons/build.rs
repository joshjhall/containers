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

    embed_repo_baseline(&manifest_dir);
}

/// Generate `$OUT_DIR/repo_baseline_assets.rs`: a `(relative path, bytes)`
/// table of every file under `assets/repo-baseline/`, so `stibbons setup
/// standards` carries its templates inside the binary (no librarian checkout
/// needed on the host). Paths use `/` separators and are sorted, so the table
/// is identical across platforms and builds.
fn embed_repo_baseline(manifest_dir: &str) {
    use std::fmt::Write as _;

    let root = Path::new(manifest_dir).join("assets/repo-baseline");
    println!("cargo:rerun-if-changed={}", root.display());

    let mut files = Vec::new();
    collect_files(&root, &root, &mut files);
    files.sort();

    let mut table = String::from("&[\n");
    for rel in &files {
        let abs = root.join(rel);
        println!("cargo:rerun-if-changed={}", abs.display());
        let _ =
            writeln!(table, "    ({rel:?}, include_bytes!({:?}) as &[u8]),", abs.to_string_lossy());
    }
    table.push(']');

    let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR is always set by cargo");
    std::fs::write(Path::new(&out_dir).join("repo_baseline_assets.rs"), table)
        .expect("failed to write repo_baseline_assets.rs");
}

/// Recursively collect files under `dir`, as `/`-separated paths relative to
/// `root`. Directories are watched too, so an added or removed file reruns
/// the build script.
fn collect_files(root: &Path, dir: &Path, out: &mut Vec<String>) {
    let entries =
        std::fs::read_dir(dir).unwrap_or_else(|e| panic!("failed to read {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.expect("failed to read directory entry").path();
        if path.is_dir() {
            println!("cargo:rerun-if-changed={}", path.display());
            collect_files(root, &path, out);
        } else {
            let rel = path.strip_prefix(root).expect("entry is under root");
            let parts: Vec<String> =
                rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
            out.push(parts.join("/"));
        }
    }
}
