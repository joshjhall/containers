//! Template functions — `groupedBuildArgs` and related types.

use crate::feature::{Category, Feature};

use super::context::RenderContext;

/// A category of build args with a label header.
#[derive(Debug, Clone)]
pub struct BuildArgGroup {
    /// Display label (e.g. "Languages", "Tools").
    pub label: String,

    /// Ordered entries within the group.
    pub args: Vec<BuildArgEntry>,
}

/// A single build arg line with an optional inline comment.
#[derive(Debug, Clone)]
pub struct BuildArgEntry {
    /// e.g. `"INCLUDE_PYTHON_DEV=true"`.
    pub line: String,

    /// e.g. `"includes Python runtime"` (empty if none).
    pub comment: String,
}

/// Maps feature categories to display labels.
const fn category_label(cat: Category) -> &'static str {
    match cat {
        Category::Language => "Languages",
        Category::Tool => "Tools",
        Category::Ai => "AI/ML",
        Category::Cloud => "Cloud",
        Category::Database => "Database",
    }
}

/// Category rendering order.
const CATEGORY_ORDER: [Category; 5] =
    [Category::Language, Category::Tool, Category::Ai, Category::Cloud, Category::Database];

/// Groups enabled features by category, collapses base+dev pairs (emitting
/// only the dev line with an annotation), and attaches version args after the
/// corresponding feature entry.
#[must_use]
pub fn grouped_build_args(ctx: &RenderContext) -> Vec<BuildArgGroup> {
    // Build a set of enabled feature IDs for quick lookup.
    let enabled_ids: std::collections::HashSet<&str> =
        ctx.enabled_features.iter().map(|f| f.id.as_str()).collect();

    // Bucket features by category, preserving registry order.
    let mut buckets: std::collections::HashMap<Category, Vec<&Feature>> =
        std::collections::HashMap::new();
    for f in &ctx.enabled_features {
        buckets.entry(f.category).or_default().push(f);
    }

    let mut groups = Vec::new();
    for cat in CATEGORY_ORDER {
        let Some(features) = buckets.get(&cat) else {
            continue;
        };
        if features.is_empty() {
            continue;
        }

        // Track base features suppressed because their dev counterpart is present.
        let mut suppressed = std::collections::HashSet::new();
        for f in features {
            if f.is_dev
                && let Some(base_lang) = &f.base_lang
                && enabled_ids.contains(base_lang.as_str())
            {
                suppressed.insert(base_lang.as_str());
            }
        }

        let mut entries = Vec::new();
        for f in features {
            // Skip base feature if its dev counterpart is also enabled.
            if suppressed.contains(f.id.as_str()) {
                continue;
            }

            let mut entry =
                BuildArgEntry { line: format!("{}=true", f.build_arg), comment: String::new() };

            // For dev features, add "includes X runtime" comment.
            if f.is_dev
                && let Some(base_lang) = &f.base_lang
            {
                for base in features {
                    if base.id == *base_lang {
                        entry.comment = format!("includes {} runtime", base.display_name);
                        break;
                    }
                }
            }
            entries.push(entry);

            // Attach version arg: for dev features, use the base feature's version.
            let version_feature = if f.is_dev {
                f.base_lang
                    .as_ref()
                    .and_then(|bl| features.iter().find(|base| base.id == *bl))
                    .unwrap_or(f)
            } else {
                f
            };

            if let Some(version_arg) = &version_feature.version_arg
                && let Some(ver) = ctx.versions.get(version_arg)
                && !ver.is_empty()
            {
                entries.push(BuildArgEntry {
                    line: format!("{version_arg}={ver}"),
                    comment: String::new(),
                });
            }
        }

        if !entries.is_empty() {
            groups.push(BuildArgGroup { label: category_label(cat).into(), args: entries });
        }
    }

    groups
}
