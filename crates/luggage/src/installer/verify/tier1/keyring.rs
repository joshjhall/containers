//! Pinned-keyring loading for tier 1: resolve `gpg_keyring` under the catalog
//! root and parse its certificates. See the module docs in [`super`].

use std::fs::File;
use std::path::{Component, Path, PathBuf};

use pgp::composed::{Deserializable, SignedPublicKey};

/// Resolve `rel` under `root`, refusing anything that could name a file
/// outside the reviewed catalog tree.
///
/// The lexical check (relative, only plain components) rejects `/etc/x.asc`
/// and `../x.asc` before touching the filesystem; the canonical prefix check
/// after it catches a symlink inside the catalog pointing out of it.
pub(super) fn resolve_keyring(root: &Path, rel: &str) -> std::result::Result<PathBuf, String> {
    let rel_path = Path::new(rel);
    if rel.is_empty() || !rel_path.components().all(|c| matches!(c, Component::Normal(_))) {
        return Err(format!(
            "`gpg_keyring` must be a plain relative path inside the catalog, got `{rel}`"
        ));
    }
    let canonical_root = root
        .canonicalize()
        .map_err(|e| format!("catalog root {} is not accessible: {e}", root.display()))?;
    let resolved = canonical_root
        .join(rel_path)
        .canonicalize()
        .map_err(|e| format!("pinned keyring `{rel}` not found in the catalog: {e}"))?;
    if !resolved.starts_with(&canonical_root) {
        return Err(format!("pinned keyring `{rel}` resolves outside the catalog root"));
    }
    Ok(resolved)
}

/// Parse every certificate in an armored keyring.
///
/// A certificate the parser cannot handle (an obsolete algorithm, say) is
/// skipped rather than failing the whole keyring: it simply cannot be the
/// signer, and a signature by it is then refused as "not in the keyring". A
/// keyring that yields no usable certificate at all is an error.
pub(super) fn load_keyring(path: &Path) -> std::result::Result<Vec<SignedPublicKey>, String> {
    let file = File::open(path)
        .map_err(|e| format!("cannot read pinned keyring {}: {e}", path.display()))?;
    let (iter, _) = SignedPublicKey::from_armor_many(file)
        .map_err(|e| format!("pinned keyring {} is not an armored keyring: {e}", path.display()))?;
    let keys: Vec<_> = iter
        .filter_map(|k| {
            k.map_err(|e| {
                tracing::warn!("skipping unparsable certificate in {}: {e}", path.display());
            })
            .ok()
        })
        .collect();
    if keys.is_empty() {
        return Err(format!("pinned keyring {} holds no usable certificate", path.display()));
    }
    Ok(keys)
}
