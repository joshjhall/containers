//! Resolution policy — caller-supplied gating rules for [`crate::Catalog::resolve_with_policy`].
//!
//! A [`ResolutionPolicy`] tells luggage three things:
//!
//! 1. The lowest [`ActivityScore`] the resolver will accept (anything below
//!    fails with [`crate::LuggageError::ActivityBelowThreshold`]).
//! 2. Whether to allow versions below the tool's `minimum_recommended`
//!    (otherwise: [`crate::LuggageError::BelowMinimumRecommended`]).
//! 3. Whether to attach a warning when the tool is in the `Slow` or `Stale`
//!    band rather than silently passing.
//!
//! Three presets cover the common consumers:
//!
//! | Preset       | `min_activity` | below-min | warn slow/stale |
//! |--------------|----------------|-----------|-----------------|
//! | `Stibbons`   | `Maintained`   | refuse    | yes             |
//! | `Igor`       | `Stale`        | allow     | no              |
//! | `Permissive` | `Abandoned`    | allow     | no              |
//!
//! `Default` matches `Stibbons` — the wizard surface is luggage's most
//! safety-critical caller, so the safe default is the strict one.
//!
//! See `crates/luggage/README.md` for the full tier semantics.

use containers_common::tooldb::ActivityScore;

/// Caller-supplied gating policy for [`crate::Catalog::resolve_with_policy`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResolutionPolicy {
    /// Lowest activity tier the resolver will accept.
    pub min_activity: ActivityScore,
    /// True to permit selecting versions below the tool's
    /// `minimum_recommended`. When false, below-minimum versions yield
    /// [`crate::LuggageError::BelowMinimumRecommended`].
    pub allow_below_min_recommended: bool,
    /// True to attach a [`crate::ResolutionWarning::SlowOrStaleActivity`]
    /// warning when the tool is in the `Slow` or `Stale` band.
    pub warn_on_slow_or_stale: bool,
}

/// Named preset bundles. See module docs for the cell-by-cell breakdown.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyPreset {
    /// Stibbons wizard defaults: refuse below-Maintained, refuse below-min, warn on slow/stale.
    Stibbons,
    /// Igor runtime defaults: accept down to Stale, allow below-min, no warnings.
    Igor,
    /// Permissive: accept anything, allow below-min, no warnings. Used by `--policy permissive`.
    Permissive,
}

impl ResolutionPolicy {
    /// The default policy used by [`crate::Catalog::resolve`] and the
    /// stibbons wizard. Refuses anything below `Maintained` and anything
    /// below `minimum_recommended`; warns on `Slow`/`Stale`.
    #[must_use]
    pub const fn stibbons() -> Self {
        Self {
            min_activity: ActivityScore::Maintained,
            allow_below_min_recommended: false,
            warn_on_slow_or_stale: true,
        }
    }

    /// The runtime install policy. Accepts down to `Stale` (igor will
    /// install whatever the user asked for as long as it isn't outright
    /// dormant) and tolerates below-min versions silently.
    #[must_use]
    pub const fn igor() -> Self {
        Self {
            min_activity: ActivityScore::Stale,
            allow_below_min_recommended: true,
            warn_on_slow_or_stale: false,
        }
    }

    /// Permissive policy: all tiers permitted, including dormant and
    /// abandoned. Used by `--policy permissive` and tests.
    #[must_use]
    pub const fn permissive() -> Self {
        Self {
            min_activity: ActivityScore::Abandoned,
            allow_below_min_recommended: true,
            warn_on_slow_or_stale: false,
        }
    }

    /// Build a policy from a named preset.
    #[must_use]
    pub const fn from_preset(preset: PolicyPreset) -> Self {
        match preset {
            PolicyPreset::Stibbons => Self::stibbons(),
            PolicyPreset::Igor => Self::igor(),
            PolicyPreset::Permissive => Self::permissive(),
        }
    }
}

impl Default for ResolutionPolicy {
    fn default() -> Self {
        Self::stibbons()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_matches_stibbons_preset() {
        assert_eq!(ResolutionPolicy::default(), ResolutionPolicy::stibbons());
    }

    #[test]
    fn stibbons_preset_is_strict() {
        let p = ResolutionPolicy::stibbons();
        assert_eq!(p.min_activity, ActivityScore::Maintained);
        assert!(!p.allow_below_min_recommended);
        assert!(p.warn_on_slow_or_stale);
    }

    #[test]
    fn igor_preset_is_lenient_about_min_recommended() {
        let p = ResolutionPolicy::igor();
        assert_eq!(p.min_activity, ActivityScore::Stale);
        assert!(p.allow_below_min_recommended);
        assert!(!p.warn_on_slow_or_stale);
    }

    #[test]
    fn permissive_preset_accepts_everything() {
        let p = ResolutionPolicy::permissive();
        assert_eq!(p.min_activity, ActivityScore::Abandoned);
        assert!(p.allow_below_min_recommended);
        assert!(!p.warn_on_slow_or_stale);
    }

    #[test]
    fn from_preset_round_trips() {
        assert_eq!(
            ResolutionPolicy::from_preset(PolicyPreset::Stibbons),
            ResolutionPolicy::stibbons(),
        );
        assert_eq!(ResolutionPolicy::from_preset(PolicyPreset::Igor), ResolutionPolicy::igor());
        assert_eq!(
            ResolutionPolicy::from_preset(PolicyPreset::Permissive),
            ResolutionPolicy::permissive(),
        );
    }
}
