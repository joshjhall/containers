//! Desired-vs-remote label diff.
//!
//! Given the desired labels (from skill metadata) and the labels currently on
//! the remote tracker, [`compute_plan`] produces a per-label [`LabelChange`].
//! The reconcile is **additive only** — labels present on the remote but absent
//! from the metadata are left untouched (never deleted).

use std::collections::BTreeMap;

use super::metadata::{LabelDef, canon_color};

/// What will happen to a single label on sync.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LabelChange {
    /// Label is missing on the remote and will be created.
    Create(LabelDef),
    /// Label exists but its color and/or description drifted.
    Update {
        /// The desired end-state.
        desired: LabelDef,
        /// True when the color differs.
        color_changed: bool,
        /// True when the description differs.
        desc_changed: bool,
    },
    /// Label already matches the desired definition — no action.
    Ok(LabelDef),
}

impl LabelChange {
    /// The label name this change concerns.
    #[cfg(test)]
    #[must_use]
    pub fn name(&self) -> &str {
        match self {
            Self::Create(l) | Self::Ok(l) => &l.name,
            Self::Update { desired, .. } => &desired.name,
        }
    }
}

/// Tally of a plan for the summary line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct PlanCounts {
    /// Labels to create.
    pub create: usize,
    /// Labels to update.
    pub update: usize,
    /// Labels already in sync.
    pub ok: usize,
}

/// Compute the change set for `desired` labels against the `remote` set.
///
/// `remote` maps label name → (color, description) as currently on the tracker.
/// Comparison canonicalizes color (`#` stripped, uppercased) so GitHub's bare
/// hex and GitLab's `#`-prefixed hex compare equal. Output order follows
/// `desired` (already sorted by name upstream).
#[must_use]
pub fn compute_plan(
    desired: &[LabelDef],
    remote: &BTreeMap<String, (String, String)>,
) -> Vec<LabelChange> {
    desired
        .iter()
        .map(|d| match remote.get(&d.name) {
            None => LabelChange::Create(d.clone()),
            Some((rcolor, rdesc)) => {
                let color_changed = canon_color(rcolor) != canon_color(&d.color);
                let desc_changed = *rdesc != d.description;
                if color_changed || desc_changed {
                    LabelChange::Update { desired: d.clone(), color_changed, desc_changed }
                } else {
                    LabelChange::Ok(d.clone())
                }
            }
        })
        .collect()
}

/// Count creates / updates / oks in a plan.
#[must_use]
pub fn count(plan: &[LabelChange]) -> PlanCounts {
    let mut c = PlanCounts::default();
    for change in plan {
        match change {
            LabelChange::Create(_) => c.create += 1,
            LabelChange::Update { .. } => c.update += 1,
            LabelChange::Ok(_) => c.ok += 1,
        }
    }
    c
}

#[cfg(test)]
mod tests {
    use super::*;

    fn label(name: &str, color: &str, desc: &str) -> LabelDef {
        LabelDef { name: name.into(), color: color.into(), description: desc.into() }
    }

    #[test]
    fn missing_label_is_create() {
        let desired = vec![label("status/on-hold", "D4C5F9", "Deferred")];
        let plan = compute_plan(&desired, &BTreeMap::new());
        assert!(matches!(plan[0], LabelChange::Create(_)));
        assert_eq!(count(&plan), PlanCounts { create: 1, update: 0, ok: 0 });
    }

    #[test]
    fn identical_label_is_ok() {
        let desired = vec![label("type/feature", "1D76DB", "New feature")];
        let mut remote = BTreeMap::new();
        remote
            .insert("type/feature".to_string(), ("1D76DB".to_string(), "New feature".to_string()));
        let plan = compute_plan(&desired, &remote);
        assert!(matches!(plan[0], LabelChange::Ok(_)));
        assert_eq!(count(&plan), PlanCounts { create: 0, update: 0, ok: 1 });
    }

    #[test]
    fn color_case_and_hash_are_equivalent() {
        let desired = vec![label("severity/high", "D93F0B", "High")];
        let mut remote = BTreeMap::new();
        // GitLab-style `#`-prefixed, lowercase — should still compare equal.
        remote.insert("severity/high".to_string(), ("#d93f0b".to_string(), "High".to_string()));
        let plan = compute_plan(&desired, &remote);
        assert!(matches!(plan[0], LabelChange::Ok(_)));
    }

    #[test]
    fn color_drift_is_update() {
        let desired = vec![label("severity/high", "D93F0B", "High")];
        let mut remote = BTreeMap::new();
        remote.insert("severity/high".to_string(), ("000000".to_string(), "High".to_string()));
        let plan = compute_plan(&desired, &remote);
        match &plan[0] {
            LabelChange::Update { color_changed, desc_changed, .. } => {
                assert!(color_changed);
                assert!(!desc_changed);
            }
            other => panic!("expected update, got {other:?}"),
        }
    }

    #[test]
    fn description_drift_is_update() {
        let desired = vec![label("severity/high", "D93F0B", "High severity")];
        let mut remote = BTreeMap::new();
        remote.insert("severity/high".to_string(), ("D93F0B".to_string(), "High".to_string()));
        let plan = compute_plan(&desired, &remote);
        match &plan[0] {
            LabelChange::Update { color_changed, desc_changed, .. } => {
                assert!(!color_changed);
                assert!(desc_changed);
            }
            other => panic!("expected update, got {other:?}"),
        }
    }

    #[test]
    fn extra_remote_labels_are_ignored_never_deleted() {
        let desired = vec![label("type/bug", "D73A4A", "Bug")];
        let mut remote = BTreeMap::new();
        remote.insert("type/bug".to_string(), ("D73A4A".to_string(), "Bug".to_string()));
        remote.insert("wontfix".to_string(), ("FFFFFF".to_string(), "Won't fix".to_string()));
        let plan = compute_plan(&desired, &remote);
        // Only the desired label appears in the plan; `wontfix` is untouched.
        assert_eq!(plan.len(), 1);
        assert_eq!(plan[0].name(), "type/bug");
    }

    #[test]
    fn idempotent_second_run_all_ok() {
        let desired = vec![label("effort/small", "0E8A16", "Small")];
        // Simulate remote after a create: matches desired exactly.
        let mut remote = BTreeMap::new();
        remote.insert("effort/small".to_string(), ("0E8A16".to_string(), "Small".to_string()));
        let plan = compute_plan(&desired, &remote);
        assert_eq!(count(&plan), PlanCounts { create: 0, update: 0, ok: 1 });
    }
}
