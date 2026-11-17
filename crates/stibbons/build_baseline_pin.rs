// Repo-baseline snapshot pin resolution for the stibbons build script (#1649).
//
// `stibbons setup standards` embeds containers-db's templates through the
// `repo-baseline` git dependency, pinned by `rev = "<full sha>"` in the
// workspace Cargo.toml. The build script stamps that SHA into the binary as
// `REPO_BASELINE_SHA`, so `.stibbons-standards.yml` can record which snapshot
// rendered a repo. It is read from Cargo.lock (what cargo actually built) and
// cross-checked against Cargo.toml (what the pin says), so a lockfile left
// behind after a rev edit fails the build instead of stamping the wrong SHA.
//
// Kept in an `include!`-able file, like `build_version.rs`, so
// `tests/build_baseline_pin.rs` can test it. Regular `//` comments only.

/// The package name of the pinned templates crate.
const BASELINE_PACKAGE: &str = "repo-baseline";

/// Whether `s` is a full, lowercase 40-hex git commit SHA.
fn is_full_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The commit SHA cargo resolved `repo-baseline` to, from Cargo.lock text.
///
/// Reads the `[[package]]` block whose `name` is `repo-baseline` and takes the
/// `#<sha>` fragment of its `source = "git+…"` line.
///
/// # Errors
///
/// A message when the package is missing, appears more than once, is not a git
/// source, or its fragment is not a full SHA.
fn locked_baseline_sha(lock: &str) -> Result<String, String> {
    let mut found: Vec<String> = Vec::new();
    for block in lock.split("[[package]]").skip(1) {
        let field = |key: &str| {
            block.lines().find_map(|l| {
                let (k, v) = l.split_once('=')?;
                (k.trim() == key).then(|| v.trim().trim_matches('"').to_string())
            })
        };
        if field("name").as_deref() != Some(BASELINE_PACKAGE) {
            continue;
        }
        let source = field("source")
            .ok_or_else(|| format!("Cargo.lock: {BASELINE_PACKAGE} has no source line"))?;
        let rest = source.strip_prefix("git+").ok_or_else(|| {
            format!("Cargo.lock: {BASELINE_PACKAGE} is not a git dependency: {source}")
        })?;
        let (_, sha) = rest.rsplit_once('#').ok_or_else(|| {
            format!("Cargo.lock: {BASELINE_PACKAGE} source has no #<sha> fragment: {source}")
        })?;
        if !is_full_sha(sha) {
            return Err(format!(
                "Cargo.lock: {BASELINE_PACKAGE} resolved to {sha:?}, not a full commit SHA"
            ));
        }
        found.push(sha.to_string());
    }
    match found.len() {
        1 => Ok(found.remove(0)),
        0 => Err(format!("Cargo.lock has no {BASELINE_PACKAGE} package")),
        n => Err(format!("Cargo.lock has {n} {BASELINE_PACKAGE} packages; expected one")),
    }
}

/// The `rev` the workspace Cargo.toml pins `repo-baseline` to.
///
/// Expects the one-line inline-table form under `[workspace.dependencies]`:
/// `repo-baseline = { git = "…", rev = "<sha>" }`.
///
/// # Errors
///
/// A message when there is no such line, it has no `rev`, the rev is not a full
/// SHA, or it also names a `branch`/`tag` (a moving ref).
fn manifest_baseline_rev(cargo_toml: &str) -> Result<String, String> {
    let line = cargo_toml
        .lines()
        .map(str::trim)
        .find(|l| l.split_once('=').is_some_and(|(k, _)| k.trim() == BASELINE_PACKAGE))
        .ok_or_else(|| format!("workspace Cargo.toml does not declare {BASELINE_PACKAGE}"))?;
    let table = line
        .split_once('=')
        .map(|(_, v)| v.trim())
        .and_then(|v| v.strip_prefix('{'))
        .and_then(|v| v.strip_suffix('}'))
        .ok_or_else(|| format!("{BASELINE_PACKAGE} must be an inline table: {line}"))?;
    let mut rev = None;
    for pair in table.split(',') {
        let Some((k, v)) = pair.split_once('=') else { continue };
        match k.trim() {
            "rev" => rev = Some(v.trim().trim_matches('"').to_string()),
            moving @ ("branch" | "tag") => {
                return Err(format!(
                    "{BASELINE_PACKAGE} must be pinned by a full `rev`, not a {moving}: {line}"
                ));
            }
            _ => {}
        }
    }
    match rev {
        Some(r) if is_full_sha(&r) => Ok(r),
        Some(_) => Err(format!("{BASELINE_PACKAGE} rev must be a full 40-hex commit SHA: {line}")),
        None => Err(format!("{BASELINE_PACKAGE} has no `rev = \"<sha>\"`: {line}")),
    }
}

/// The snapshot SHA to stamp: the locked SHA, which must equal the pinned rev.
///
/// # Errors
///
/// Either lookup's error, or a mismatch naming both SHAs and the fix.
fn resolve_baseline_sha(cargo_toml: &str, lock: &str) -> Result<String, String> {
    let rev = manifest_baseline_rev(cargo_toml)?;
    let locked = locked_baseline_sha(lock)?;
    if rev != locked {
        return Err(format!(
            "Cargo.toml pins {BASELINE_PACKAGE} at {rev} but Cargo.lock has {locked}; \
             run `cargo update -p {BASELINE_PACKAGE}`"
        ));
    }
    Ok(locked)
}
