//! Validation for feature mutation operations (`add` / `remove`).
//!
//! [`resolve`](super::resolve) expands a selection along `requires` and
//! `implied_by` edges. This module adds the *guard rails* that a mutating
//! command needs before it writes a new selection back to `.igor.yml`:
//!
//! - [`dependents_of`] / [`requires_transitive`] — walk the dependency graph to
//!   find which explicit features would be orphaned by a removal.
//! - [`plan_remove`] — validate and compute the new explicit set for a removal,
//!   honoring `--cascade` and `--dev-only`.
//! - [`plan_add`] — validate and compute the new explicit set for an addition,
//!   honoring `--dev` companion auto-add and skipping already-enabled features.
//! - [`prune_versions`] / [`fill_default_versions`] — keep the version map in
//!   sync with the current selection.
//!
//! These functions are pure (no I/O): callers own config loading and saving.

use std::collections::{BTreeMap, HashSet};
use std::hash::BuildHasher;

use super::Registry;

/// Errors returned when validating an `add` or `remove` operation.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ValidateError {
    /// The named feature ID is not present in the registry.
    #[error("unknown feature `{id}`")]
    UnknownFeature {
        /// The unrecognized feature ID.
        id: String,
    },

    /// The feature is only present via dependency resolution, not as an
    /// explicit selection, so it cannot be removed directly.
    #[error(
        "feature `{id}` is auto-resolved, not explicitly enabled; \
         remove the feature that depends on it instead"
    )]
    NotExplicit {
        /// The auto-resolved feature ID.
        id: String,
    },

    /// The feature still has explicit dependents and `--cascade` was not set.
    #[error("cannot remove `{id}`: still required by {}", .dependents.join(", "))]
    HasDependents {
        /// The feature that cannot be removed.
        id: String,
        /// The explicit features that transitively require `id`.
        dependents: Vec<String>,
    },

    /// A `_dev` companion was requested but none exists for the feature.
    #[error("feature `{id}` has no `_dev` companion")]
    NoDevCompanion {
        /// The base feature ID whose companion is missing.
        id: String,
    },
}

/// Options controlling a [`plan_remove`] operation.
#[derive(Debug, Clone, Copy, Default)]
pub struct RemoveOptions {
    /// Also remove every explicit feature that transitively requires a target.
    pub cascade: bool,
    /// Remove only the `_dev` companion of each target, keeping the runtime
    /// feature.
    pub dev_only: bool,
}

/// Options controlling a [`plan_add`] operation.
#[derive(Debug, Clone, Copy, Default)]
pub struct AddOptions {
    /// Also add the `_dev` companion of each target.
    pub dev: bool,
}

/// Result of a successful [`plan_add`].
#[derive(Debug, Clone)]
pub struct AddOutcome {
    /// The new explicit selection after the addition.
    pub explicit: HashSet<String>,
    /// Targets (and companions) that were already enabled and thus skipped.
    pub skipped: Vec<String>,
}

/// Returns `true` if `feature_id` transitively requires `target_id`.
///
/// Walks the `requires` edges depth-first, tracking visited nodes so a cycle in
/// the dependency graph terminates instead of looping forever.
#[must_use]
pub fn requires_transitive(feature_id: &str, target_id: &str, registry: &Registry) -> bool {
    let mut visited = HashSet::new();
    requires_transitive_inner(feature_id, target_id, registry, &mut visited)
}

fn requires_transitive_inner(
    feature_id: &str,
    target_id: &str,
    registry: &Registry,
    visited: &mut HashSet<String>,
) -> bool {
    if !visited.insert(feature_id.to_string()) {
        return false;
    }
    let Some(f) = registry.get(feature_id) else {
        return false;
    };
    for req in &f.requires {
        if req == target_id || requires_transitive_inner(req, target_id, registry, visited) {
            return true;
        }
    }
    false
}

/// Returns the explicit features that transitively require `target_id`, sorted.
///
/// The target itself is excluded. Used by [`plan_remove`] to detect removals
/// that would orphan another selected feature.
#[must_use]
pub fn dependents_of<S: BuildHasher>(
    target_id: &str,
    explicit: &HashSet<String, S>,
    registry: &Registry,
) -> Vec<String> {
    let mut deps: Vec<String> = explicit
        .iter()
        .filter(|id| id.as_str() != target_id)
        .filter(|id| requires_transitive(id, target_id, registry))
        .cloned()
        .collect();
    deps.sort();
    deps
}

/// Validates a removal and returns the new explicit selection.
///
/// Each target must exist and (in normal mode) be explicitly enabled. Removing
/// a feature that other explicit features still require is rejected unless
/// [`RemoveOptions::cascade`] is set, in which case those dependents are removed
/// too. With [`RemoveOptions::dev_only`], the `_dev` companion is removed and
/// the runtime feature is kept.
///
/// # Errors
///
/// Returns [`ValidateError::UnknownFeature`] if a target is not in the registry,
/// [`ValidateError::NoDevCompanion`] if `dev_only` is set but no companion
/// exists, [`ValidateError::NotExplicit`] if the resolved removal target is not
/// explicitly enabled, and [`ValidateError::HasDependents`] if the target still
/// has explicit dependents and `cascade` is not set.
pub fn plan_remove<S: BuildHasher>(
    targets: &[String],
    explicit: &HashSet<String, S>,
    opts: RemoveOptions,
    registry: &Registry,
) -> Result<HashSet<String>, ValidateError> {
    // Resolve each named target to the concrete feature ID to remove.
    let mut to_remove: HashSet<String> = HashSet::new();
    for target in targets {
        if registry.get(target).is_none() {
            return Err(ValidateError::UnknownFeature { id: target.clone() });
        }

        let remove_id = if opts.dev_only {
            let companion = format!("{target}_dev");
            if registry.get(&companion).is_none() {
                return Err(ValidateError::NoDevCompanion { id: target.clone() });
            }
            companion
        } else {
            target.clone()
        };

        if !explicit.contains(&remove_id) {
            return Err(ValidateError::NotExplicit { id: remove_id });
        }
        to_remove.insert(remove_id);
    }

    // Pull in (or reject on) dependents until the removal set is stable. A
    // dependent already scheduled for removal is not an orphan, so it is
    // filtered out before deciding.
    loop {
        let mut changed = false;
        for remove_id in to_remove.clone() {
            let orphans: Vec<String> = dependents_of(&remove_id, explicit, registry)
                .into_iter()
                .filter(|d| !to_remove.contains(d))
                .collect();
            if orphans.is_empty() {
                continue;
            }
            if !opts.cascade {
                return Err(ValidateError::HasDependents { id: remove_id, dependents: orphans });
            }
            for orphan in orphans {
                if to_remove.insert(orphan) {
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }

    let result = explicit.iter().filter(|id| !to_remove.contains(*id)).cloned().collect();
    Ok(result)
}

/// Validates an addition and returns the new explicit selection.
///
/// Each target must exist in the registry. Targets already enabled are recorded
/// in [`AddOutcome::skipped`] rather than treated as errors. With
/// [`AddOptions::dev`], the `_dev` companion of each target is added as well.
///
/// # Errors
///
/// Returns [`ValidateError::UnknownFeature`] if a target is not in the registry,
/// or [`ValidateError::NoDevCompanion`] if `dev` is set but a target has no
/// `_dev` companion.
pub fn plan_add<S: BuildHasher>(
    targets: &[String],
    explicit: &HashSet<String, S>,
    opts: AddOptions,
    registry: &Registry,
) -> Result<AddOutcome, ValidateError> {
    let mut new_explicit: HashSet<String> = explicit.iter().cloned().collect();
    let mut skipped: Vec<String> = Vec::new();

    for target in targets {
        if registry.get(target).is_none() {
            return Err(ValidateError::UnknownFeature { id: target.clone() });
        }
        if !new_explicit.insert(target.clone()) {
            skipped.push(target.clone());
        }

        if opts.dev {
            let companion = format!("{target}_dev");
            if registry.get(&companion).is_none() {
                return Err(ValidateError::NoDevCompanion { id: target.clone() });
            }
            if !new_explicit.insert(companion.clone()) {
                skipped.push(companion);
            }
        }
    }

    Ok(AddOutcome { explicit: new_explicit, skipped })
}

/// Removes version entries whose version arg is not owned by any selected
/// feature. Call with the fully-resolved selection after a removal.
pub fn prune_versions<S: BuildHasher>(
    versions: &mut BTreeMap<String, String>,
    selection: &HashSet<String, S>,
    registry: &Registry,
) {
    let active: HashSet<&str> = selection
        .iter()
        .filter_map(|id| registry.get(id))
        .filter_map(|f| f.version_arg.as_deref())
        .collect();
    versions.retain(|key, _| active.contains(key.as_str()));
}

/// Fills default versions for selected features that have a version arg and a
/// default but no existing entry. Existing entries are left untouched.
pub fn fill_default_versions<S: BuildHasher>(
    versions: &mut BTreeMap<String, String>,
    selection: &HashSet<String, S>,
    registry: &Registry,
) {
    for id in selection {
        let Some(f) = registry.get(id) else {
            continue;
        };
        let (Some(arg), Some(default)) = (f.version_arg.as_ref(), f.default_version.as_ref())
        else {
            continue;
        };
        versions.entry(arg.clone()).or_insert_with(|| default.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn explicit(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| (*s).to_string()).collect()
    }

    fn ids(strs: &[&str]) -> Vec<String> {
        strs.iter().map(|s| (*s).to_string()).collect()
    }

    // --- dependents_of / requires_transitive ---

    #[test]
    fn no_dependents_returns_empty() {
        let reg = Registry::new();
        // python is required by python_dev, but python_dev is not selected here.
        let deps = dependents_of("python", &explicit(&["python", "node"]), &reg);
        assert!(deps.is_empty(), "expected no dependents, got {deps:?}");
    }

    #[test]
    fn direct_dependent_found() {
        let reg = Registry::new();
        // python_dev requires python.
        let deps = dependents_of("python", &explicit(&["python", "python_dev"]), &reg);
        assert_eq!(deps, ids(&["python_dev"]));
    }

    #[test]
    fn transitive_dependent_found() {
        let reg = Registry::new();
        // kotlin_dev -> kotlin -> java, so kotlin_dev transitively requires java.
        assert!(requires_transitive("kotlin_dev", "java", &reg));
        let deps = dependents_of("java", &explicit(&["java", "kotlin", "kotlin_dev"]), &reg);
        assert_eq!(deps, ids(&["kotlin", "kotlin_dev"]), "both should require java, sorted");
    }

    #[test]
    fn dependents_are_sorted() {
        let reg = Registry::new();
        // java is required by kotlin, android, java_dev (among the selected).
        let sel = explicit(&["java", "kotlin", "android", "java_dev"]);
        let deps = dependents_of("java", &sel, &reg);
        let mut expected = deps.clone();
        expected.sort();
        assert_eq!(deps, expected, "dependents_of must return sorted output");
    }

    #[test]
    fn requires_transitive_terminates_on_the_real_registry() {
        // bindfs requires cron; cron is implied_by bindfs but has no `requires`
        // edge back, so there is no requires-cycle. Assert it simply resolves.
        let reg = Registry::new();
        assert!(requires_transitive("bindfs", "cron", &reg));
        assert!(!requires_transitive("cron", "bindfs", &reg));
    }

    #[test]
    fn requires_transitive_handles_a_cycle_without_looping() {
        // A hand-built registry with a requires-cycle a -> b -> a. The visited
        // set must break the recursion. Reaching this assertion at all proves
        // termination.
        let mut reg = Registry::new();
        reg.insert_for_test(super::super::Feature {
            id: "cyc_a".into(),
            requires: vec!["cyc_b".into()],
            ..Default::default()
        });
        reg.insert_for_test(super::super::Feature {
            id: "cyc_b".into(),
            requires: vec!["cyc_a".into()],
            ..Default::default()
        });
        // Neither requires a non-participating target, so both are false — the
        // point is that the call returns rather than overflowing the stack.
        assert!(!requires_transitive("cyc_a", "python", &reg));
        assert!(requires_transitive("cyc_a", "cyc_b", &reg));
        assert!(requires_transitive("cyc_b", "cyc_a", &reg));
    }

    // --- plan_remove ---

    #[test]
    fn remove_auto_resolved_feature_errors() {
        let reg = Registry::new();
        // kotlin requires java; java is auto-resolved, not explicit.
        let sel = explicit(&["kotlin"]);
        let err = plan_remove(&ids(&["java"]), &sel, RemoveOptions::default(), &reg).unwrap_err();
        assert_eq!(err, ValidateError::NotExplicit { id: "java".into() });
    }

    #[test]
    fn remove_feature_with_dependents_errors_without_cascade() {
        let reg = Registry::new();
        let sel = explicit(&["python", "python_dev"]);
        let err = plan_remove(&ids(&["python"]), &sel, RemoveOptions::default(), &reg).unwrap_err();
        assert_eq!(
            err,
            ValidateError::HasDependents { id: "python".into(), dependents: ids(&["python_dev"]) }
        );
    }

    #[test]
    fn remove_with_cascade_drops_dependents() {
        let reg = Registry::new();
        let sel = explicit(&["python", "python_dev", "node"]);
        let opts = RemoveOptions { cascade: true, dev_only: false };
        let result = plan_remove(&ids(&["python"]), &sel, opts, &reg).unwrap();
        assert_eq!(result, explicit(&["node"]), "python and its dependent python_dev both removed");
    }

    #[test]
    fn remove_dev_only_keeps_runtime_feature() {
        let reg = Registry::new();
        let sel = explicit(&["python", "python_dev"]);
        let opts = RemoveOptions { cascade: false, dev_only: true };
        let result = plan_remove(&ids(&["python"]), &sel, opts, &reg).unwrap();
        assert_eq!(result, explicit(&["python"]), "only python_dev removed");
    }

    #[test]
    fn remove_unknown_feature_errors() {
        let reg = Registry::new();
        let sel = explicit(&["python"]);
        let err = plan_remove(&ids(&["nope"]), &sel, RemoveOptions::default(), &reg).unwrap_err();
        assert_eq!(err, ValidateError::UnknownFeature { id: "nope".into() });
    }

    // --- plan_add ---

    #[test]
    fn add_unknown_feature_errors() {
        let reg = Registry::new();
        let sel = explicit(&["python"]);
        let err = plan_add(&ids(&["nope"]), &sel, AddOptions::default(), &reg).unwrap_err();
        assert_eq!(err, ValidateError::UnknownFeature { id: "nope".into() });
    }

    #[test]
    fn add_already_enabled_is_skipped() {
        let reg = Registry::new();
        let sel = explicit(&["python"]);
        let outcome = plan_add(&ids(&["python"]), &sel, AddOptions::default(), &reg).unwrap();
        assert_eq!(outcome.skipped, ids(&["python"]));
        assert_eq!(outcome.explicit, explicit(&["python"]));
    }

    #[test]
    fn add_with_dev_adds_companion() {
        let reg = Registry::new();
        let sel = explicit(&[]);
        let outcome = plan_add(&ids(&["python"]), &sel, AddOptions { dev: true }, &reg).unwrap();
        assert_eq!(outcome.explicit, explicit(&["python", "python_dev"]));
        assert!(outcome.skipped.is_empty());
    }

    #[test]
    fn add_dev_without_companion_errors() {
        let reg = Registry::new();
        let sel = explicit(&[]);
        // `docker` has no `docker_dev` companion.
        let err = plan_add(&ids(&["docker"]), &sel, AddOptions { dev: true }, &reg).unwrap_err();
        assert_eq!(err, ValidateError::NoDevCompanion { id: "docker".into() });
    }

    // --- version helpers ---

    #[test]
    fn prune_versions_removes_stale_keys() {
        let reg = Registry::new();
        let mut versions: BTreeMap<String, String> = BTreeMap::new();
        versions.insert("PYTHON_VERSION".into(), "3.14".into());
        versions.insert("NODE_VERSION".into(), "22".into());
        // Only python remains selected.
        prune_versions(&mut versions, &explicit(&["python"]), &reg);
        assert!(versions.contains_key("PYTHON_VERSION"));
        assert!(!versions.contains_key("NODE_VERSION"), "node version should be pruned");
    }

    #[test]
    fn fill_default_versions_only_fills_missing() {
        let reg = Registry::new();
        let mut versions: BTreeMap<String, String> = BTreeMap::new();
        versions.insert("PYTHON_VERSION".into(), "3.12".into()); // pre-existing, keep
        fill_default_versions(&mut versions, &explicit(&["python", "node"]), &reg);
        assert_eq!(versions.get("PYTHON_VERSION").unwrap(), "3.12", "existing entry untouched");
        assert_eq!(versions.get("NODE_VERSION").unwrap(), "22", "node default filled");
    }
}
