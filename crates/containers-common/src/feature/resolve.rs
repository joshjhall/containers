//! Dependency resolution — expands explicit feature selections by following
//! `requires` and `implied_by` edges until stable.

use std::collections::HashSet;
use std::hash::BuildHasher;

use super::{Registry, Selection};

/// Expands a set of explicitly selected feature IDs by following dependency
/// chains (`requires`) and implied-by rules. Returns a [`Selection`] with
/// explicit and auto-resolved sets separated.
#[must_use]
pub fn resolve<S: BuildHasher>(explicit: &HashSet<String, S>, registry: &Registry) -> Selection {
    let mut sel =
        Selection { explicit: explicit.iter().cloned().collect(), auto_resolved: HashSet::new() };

    // Iteratively resolve until stable.
    loop {
        let mut changed = false;
        let snapshot: Vec<String> = sel.all().into_iter().collect();

        // Follow Requires edges.
        for id in &snapshot {
            let Some(f) = registry.get(id) else {
                continue;
            };
            for req in &f.requires {
                if !sel.has(req) {
                    sel.auto_resolved.insert(req.clone());
                    changed = true;
                }
            }
        }

        // Check ImpliedBy: if any feature in ImpliedBy is selected,
        // add the feature that declares it.
        for f in registry.all() {
            if sel.has(&f.id) {
                continue;
            }
            for implier in &f.implied_by {
                if sel.has(implier) {
                    sel.auto_resolved.insert(f.id.clone());
                    changed = true;
                }
            }
        }

        if !changed {
            break;
        }
    }

    sel
}

#[cfg(test)]
mod tests {
    use super::*;

    fn explicit(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn kotlin_implies_java() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["kotlin"]), &reg);

        assert!(sel.has("java"), "kotlin should auto-select java");
        assert!(
            sel.auto_resolved.contains("java"),
            "java should be in auto_resolved, not explicit"
        );
        assert!(sel.explicit.contains("kotlin"), "kotlin should remain in explicit set");
    }

    #[test]
    fn dev_tools_chain() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["dev_tools"]), &reg);

        // dev_tools → bindfs → cron
        assert!(sel.has("bindfs"), "dev_tools should auto-select bindfs");
        assert!(sel.has("cron"), "dev_tools should auto-select cron (via bindfs)");
    }

    #[test]
    fn rust_dev_implies_cron() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["rust_dev"]), &reg);

        // rust_dev requires rust and cron
        assert!(sel.has("rust"), "rust_dev should auto-select rust");
        assert!(sel.has("cron"), "rust_dev should auto-select cron");
    }

    #[test]
    fn dev_implies_base() {
        let reg = Registry::new();

        let cases = [
            ("python_dev", "python"),
            ("node_dev", "node"),
            ("rust_dev", "rust"),
            ("golang_dev", "golang"),
            ("ruby_dev", "ruby"),
            ("java_dev", "java"),
            ("r_dev", "r"),
            ("mojo_dev", "mojo"),
            ("kotlin_dev", "kotlin"),
            ("android_dev", "android"),
        ];

        for (dev, base) in cases {
            let sel = resolve(&explicit(&[dev]), &reg);
            assert!(sel.has(base), "{dev} should auto-select {base}");
        }
    }

    #[test]
    fn cloudflare_implies_node() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["cloudflare"]), &reg);

        assert!(sel.has("node"), "cloudflare should auto-select node");
    }

    #[test]
    fn android_implies_java() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["android"]), &reg);

        assert!(sel.has("java"), "android should auto-select java");
    }

    #[test]
    fn no_extra_deps() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["python"]), &reg);

        assert!(
            sel.auto_resolved.is_empty(),
            "python alone should have no auto deps, got: {:?}",
            sel.auto_resolved
        );
    }

    #[test]
    fn cron_required_by_bindfs() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["bindfs"]), &reg);

        assert!(sel.has("cron"), "bindfs should auto-select cron (via requires)");
    }

    #[test]
    fn selection_all() {
        let sel = Selection {
            explicit: ["python".to_string(), "node".to_string()].into_iter().collect(),
            auto_resolved: std::iter::once("cron".to_string()).collect(),
        };
        let all = sel.all();
        assert_eq!(all.len(), 3, "expected 3 features");
    }

    #[test]
    fn bindfs_implied_by_dev_tools() {
        let reg = Registry::new();
        let sel = resolve(&explicit(&["dev_tools"]), &reg);

        // bindfs has implied_by: ["dev_tools"]
        assert!(sel.has("bindfs"), "bindfs should be implied by dev_tools");
        assert!(sel.auto_resolved.contains("bindfs"), "bindfs should be in auto_resolved set");
    }
}
