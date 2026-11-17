//! Unit tests for the build script's repo-baseline pin resolution (#1649).
//!
//! `build.rs` is not compiled as a test target, so the logic lives in
//! `../build_baseline_pin.rs` and is `include!`d here as well.

include!("../build_baseline_pin.rs");

const SHA: &str = "a2c04c8c22c71a73ba8e9b206db1c3ba1e712e24";
const OTHER: &str = "0123456789abcdef0123456789abcdef01234567";

fn toml(rest: &str) -> String {
    format!(
        "[workspace.dependencies]\n\
         luggage = {{ path = \"crates/luggage\" }}\n\
         repo-baseline = {{ git = \"https://github.com/joshjhall/containers-db\"{rest} }}\n"
    )
}

fn lock(sha: &str) -> String {
    format!(
        "version = 4\n\n\
         [[package]]\nname = \"regex\"\nversion = \"1.0.0\"\n\
         source = \"registry+https://github.com/rust-lang/crates.io-index\"\n\n\
         [[package]]\nname = \"repo-baseline\"\nversion = \"0.1.0\"\n\
         source = \"git+https://github.com/joshjhall/containers-db?rev={sha}#{sha}\"\n"
    )
}

#[test]
fn resolves_when_lock_matches_the_pinned_rev() {
    let t = toml(&format!(", rev = \"{SHA}\""));
    assert_eq!(resolve_baseline_sha(&t, &lock(SHA)).unwrap(), SHA);
}

#[test]
fn a_stale_lock_is_refused_naming_both_shas() {
    let t = toml(&format!(", rev = \"{SHA}\""));
    let err = resolve_baseline_sha(&t, &lock(OTHER)).unwrap_err();
    assert_eq!(
        err,
        format!(
            "Cargo.toml pins repo-baseline at {SHA} but Cargo.lock has {OTHER}; \
             run `cargo update -p repo-baseline`"
        )
    );
}

#[test]
fn rev_must_be_a_full_sha_not_a_moving_ref() {
    for (rest, want) in [
        (", rev = \"a2c04c8\"".to_string(), "rev must be a full 40-hex commit SHA"),
        (format!(", rev = \"{}\"", SHA.to_uppercase()), "rev must be a full 40-hex commit SHA"),
        (", branch = \"main\"".to_string(), "not a branch"),
        (", tag = \"v1\"".to_string(), "not a tag"),
        (format!(", rev = \"{SHA}\", branch = \"main\""), "not a branch"),
        (String::new(), "has no `rev"),
    ] {
        let err = manifest_baseline_rev(&toml(&rest)).unwrap_err();
        assert!(err.contains(want), "{rest:?}: expected `{want}` in `{err}`");
    }
}

#[test]
fn the_rev_key_is_matched_exactly() {
    // `rev` inside the URL or another key must not be read as the pin.
    let t = "repo-baseline = { git = \"https://example.com/rev=deadbeef\", prev = \"x\", \
             rev = \"a2c04c8c22c71a73ba8e9b206db1c3ba1e712e24\" }\n";
    assert_eq!(manifest_baseline_rev(t).unwrap(), SHA);
}

#[test]
fn missing_or_non_inline_declaration_errors() {
    assert!(manifest_baseline_rev("[workspace]\n").unwrap_err().contains("does not declare"));
    let err = manifest_baseline_rev("repo-baseline = \"0.1\"\n").unwrap_err();
    assert!(err.contains("must be an inline table"), "{err}");
}

#[test]
fn lock_errors() {
    assert_eq!(
        locked_baseline_sha("version = 4\n").unwrap_err(),
        "Cargo.lock has no repo-baseline package"
    );
    let dup = format!("{}{}", lock(SHA), lock(SHA));
    assert!(locked_baseline_sha(&dup).unwrap_err().contains("2 repo-baseline packages"));
    let registry = "[[package]]\nname = \"repo-baseline\"\nversion = \"0.1.0\"\n\
                    source = \"registry+https://github.com/rust-lang/crates.io-index\"\n";
    assert!(locked_baseline_sha(registry).unwrap_err().contains("is not a git dependency"));
    let short = "[[package]]\nname = \"repo-baseline\"\nversion = \"0.1.0\"\n\
                 source = \"git+https://x?rev=a2c04c8#a2c04c8\"\n";
    assert!(locked_baseline_sha(short).unwrap_err().contains("not a full commit SHA"));
    let path_dep = "[[package]]\nname = \"repo-baseline\"\nversion = \"0.1.0\"\n";
    assert!(locked_baseline_sha(path_dep).unwrap_err().contains("has no source line"));
}

/// The real workspace Cargo.toml and Cargo.lock agree on a full-SHA pin.
#[test]
fn the_workspace_pin_resolves() {
    let read = |f: &str| {
        std::fs::read_to_string(format!("{}/../../{f}", env!("CARGO_MANIFEST_DIR"))).unwrap()
    };
    let sha = resolve_baseline_sha(&read("Cargo.toml"), &read("Cargo.lock")).unwrap();
    assert!(is_full_sha(&sha), "{sha}");
}
