//! Archive entry path safety for the `binary-tarball` method.
//!
//! Split out of `tarball.rs` (issue #808) because this is the security
//! core of that method and reviews best on its own: three pure functions
//! over paths, with no I/O and no archive state, each directly testable.
//!
//! Extraction runs as **root** during the image build, so an archive entry
//! that escapes the extraction prefix could write anywhere on the
//! filesystem. Nothing here trusts the `tar` crate's own path handling —
//! issue #808 requires the rejection be proven by crafted fixtures, and the
//! tests below plus `tarball.rs`'s end-to-end fixtures do exactly that.

use std::path::{Component, Path, PathBuf};

use crate::error::{LuggageError, Result};

/// Normalise an archive entry path, rejecting anything that could escape the
/// extraction root.
///
/// Rejects absolute paths, root/prefix components (Windows drive letters),
/// and any `..`. `..` is rejected outright rather than resolved: a path that
/// *nets out* inside the root (`a/../b`) still has no legitimate reason to
/// appear in a published tarball, and refusing the whole class is simpler to
/// reason about — and to test — than tracking depth as we walk.
/// `.` components are dropped as the no-ops they are.
pub(super) fn safe_relative_path(path: &Path, artifact_name: &str) -> Result<PathBuf> {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(LuggageError::UnsafeArchiveEntry {
                    artifact: artifact_name.to_owned(),
                    entry: path.display().to_string(),
                    reason: "path contains a `..` component that could escape the prefix"
                        .to_owned(),
                });
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(LuggageError::UnsafeArchiveEntry {
                    artifact: artifact_name.to_owned(),
                    entry: path.display().to_string(),
                    reason: "path is absolute; entries must be relative to the prefix".to_owned(),
                });
            }
        }
    }
    Ok(out)
}

/// Reject a link whose target resolves outside the extraction root.
///
/// `link_path` is the already-validated location of the link itself
/// (relative to the root); `target` is what it points at. An absolute target
/// is refused outright. A relative one is walked against the link's own
/// parent directory, decrementing on `..`: if the depth ever goes negative
/// the target is outside the root.
pub(super) fn validate_link_target(
    link_path: &Path,
    target: &Path,
    raw: &Path,
    artifact_name: &str,
) -> Result<()> {
    if target.is_absolute() {
        return Err(LuggageError::UnsafeArchiveEntry {
            artifact: artifact_name.to_owned(),
            entry: raw.display().to_string(),
            reason: format!("link target `{}` is absolute", target.display()),
        });
    }

    // Depth of the directory the link lives in. A `..` pops one level; if it
    // would pop past the root, the target is outside the prefix.
    let mut depth = link_path.components().count().saturating_sub(1);
    for component in target.components() {
        match component {
            Component::ParentDir => {
                depth = depth.checked_sub(1).ok_or_else(|| LuggageError::UnsafeArchiveEntry {
                    artifact: artifact_name.to_owned(),
                    entry: raw.display().to_string(),
                    reason: format!("link target `{}` escapes the prefix", target.display()),
                })?;
            }
            Component::Normal(_) => depth += 1,
            Component::CurDir => {}
            Component::RootDir | Component::Prefix(_) => {
                return Err(LuggageError::UnsafeArchiveEntry {
                    artifact: artifact_name.to_owned(),
                    entry: raw.display().to_string(),
                    reason: format!("link target `{}` is absolute", target.display()),
                });
            }
        }
    }
    Ok(())
}

/// Drop `strip` leading components, mirroring `tar --strip-components`.
///
/// Returns `None` when the path has no components left — the archive's own
/// top-level directory when stripping it away, which `tar` also skips.
pub(super) fn strip_prefix_components(path: &Path, strip: u32) -> Option<PathBuf> {
    let mut components = path.components();
    for _ in 0..strip {
        components.next()?;
    }
    let rest: PathBuf = components.collect();
    (!rest.as_os_str().is_empty()).then_some(rest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_relative_path_normalises_and_rejects() {
        assert_eq!(
            safe_relative_path(Path::new("./go/bin/go"), "t").unwrap(),
            PathBuf::from("go/bin/go"),
            "`.` components are dropped"
        );
        // A path that nets out inside the root is still refused — `..` has no
        // legitimate place in a published tarball.
        assert!(safe_relative_path(Path::new("a/../b"), "t").is_err());
        assert!(safe_relative_path(Path::new("../b"), "t").is_err());
        assert!(safe_relative_path(Path::new("/abs"), "t").is_err());
    }

    #[test]
    fn strip_prefix_components_matches_tar_semantics() {
        let p = Path::new("node-v22/bin/node");
        assert_eq!(strip_prefix_components(p, 0).unwrap(), PathBuf::from("node-v22/bin/node"));
        assert_eq!(strip_prefix_components(p, 1).unwrap(), PathBuf::from("bin/node"));
        assert_eq!(strip_prefix_components(p, 2).unwrap(), PathBuf::from("node"));
        // Stripping the whole path away skips the entry, as `tar` does for
        // the archive's own top-level directory.
        assert!(strip_prefix_components(p, 3).is_none());
        assert!(strip_prefix_components(p, 4).is_none());
    }

    #[test]
    fn validate_link_target_allows_sideways_and_upward_within_root() {
        let raw = Path::new("pkg/sub/link");
        // `../sibling` from `pkg/sub/` lands in `pkg/` — still inside.
        assert!(
            validate_link_target(raw, Path::new("../sibling"), raw, "t").is_ok(),
            "a `..` that stays within the root is legitimate"
        );
        // One level further is out.
        assert!(validate_link_target(raw, Path::new("../../../out"), raw, "t").is_err());
    }
}
