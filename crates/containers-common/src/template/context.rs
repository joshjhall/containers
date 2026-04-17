//! Template rendering context — assembles all data needed to render templates.

use std::collections::{BTreeMap, HashSet};

use crate::config::{AgentConfig, ProjectConfig};
use crate::feature::{Feature, Registry, Selection};

/// Assembles all data needed to render templates.
#[derive(Debug, Clone)]
pub struct RenderContext {
    /// Project configuration.
    pub project: ProjectConfig,

    /// Relative path to the containers directory.
    pub containers_dir: String,

    /// Tracks explicit vs auto-resolved features.
    pub selection: Selection,

    /// Enabled features in deterministic (registry) order.
    pub enabled_features: Vec<Feature>,

    /// Maps version arg name to chosen version.
    pub versions: BTreeMap<String, String>,

    /// Deduplicated list of cache volume specs (feature order).
    pub cache_volumes: Vec<String>,

    /// Deduplicated, sorted list of VS Code extension IDs.
    pub vscode_extensions: Vec<String>,

    /// True when bindfs is selected (needs `cap_add` + device).
    pub needs_bindfs: bool,

    /// True when docker feature is selected.
    pub needs_docker: bool,

    /// Optional agent/worktree settings.
    pub agents: AgentConfig,

    /// Volume mount specs for agent worktrees.
    pub worktree_mounts: Vec<String>,
}

impl RenderContext {
    /// Returns true when agents config has been explicitly set.
    #[must_use]
    pub const fn has_agents(&self) -> bool {
        !self.agents.is_zero()
    }

    /// Builds a `RenderContext` from resolved selection and config.
    #[must_use]
    pub fn new(
        project: ProjectConfig,
        containers_dir: &str,
        selection: &Selection,
        registry: &Registry,
        versions: BTreeMap<String, String>,
        agents: AgentConfig,
    ) -> Self {
        let mut ctx = Self {
            project,
            containers_dir: containers_dir.into(),
            selection: selection.clone(),
            enabled_features: Vec::new(),
            versions,
            cache_volumes: Vec::new(),
            vscode_extensions: Vec::new(),
            needs_bindfs: selection.has("bindfs"),
            needs_docker: selection.has("docker"),
            agents,
            worktree_mounts: Vec::new(),
        };

        // Collect enabled features in registry order.
        let all_ids = selection.all();
        for f in registry.all() {
            if all_ids.contains(&f.id) {
                ctx.enabled_features.push(f.clone());
            }
        }

        // Collect cache volumes (deduplicated, feature order).
        let mut vol_set = HashSet::new();
        for f in &ctx.enabled_features {
            for v in &f.cache_volumes {
                if vol_set.insert(v.clone()) {
                    ctx.cache_volumes.push(v.clone());
                }
            }
        }

        // Auto-derive agent shared volumes when not explicitly set.
        if !ctx.agents.is_zero()
            && ctx.agents.shared_volumes.is_empty()
            && !ctx.cache_volumes.is_empty()
        {
            ctx.agents.shared_volumes.clone_from(&ctx.cache_volumes);
        }

        // Collect VS Code extensions (deduplicated, sorted).
        let mut ext_set = HashSet::new();
        for f in &ctx.enabled_features {
            for e in &f.vscode_extensions {
                ext_set.insert(e.clone());
            }
        }
        ctx.vscode_extensions = ext_set.into_iter().collect();
        ctx.vscode_extensions.sort();

        ctx
    }
}
