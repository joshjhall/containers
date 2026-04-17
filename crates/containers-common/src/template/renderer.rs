//! Template renderer — renders embedded templates with a `RenderContext`.

use minijinja::{Environment, Value, context};

use super::context::RenderContext;
use super::funcmap::grouped_build_args;

/// Renders embedded templates with a [`RenderContext`].
pub struct Renderer {
    env: Environment<'static>,
}

impl Renderer {
    /// Creates a new renderer with all embedded templates loaded.
    ///
    /// # Errors
    ///
    /// Returns an error if templates fail to parse.
    pub fn new() -> Result<Self, Box<dyn std::error::Error>> {
        let mut env = Environment::new();
        env.set_lstrip_blocks(false);
        env.set_trim_blocks(false);

        env.add_template("docker-compose.yml.tmpl", include_str!("sources/docker-compose.yml.j2"))?;
        env.add_template("devcontainer.json.tmpl", include_str!("sources/devcontainer.json.j2"))?;
        env.add_template("env.tmpl", include_str!("sources/env.j2"))?;
        env.add_template("env-example.tmpl", include_str!("sources/env-example.j2"))?;
        env.add_template("igor.yml.tmpl", include_str!("sources/igor.yml.j2"))?;

        Ok(Self { env })
    }

    /// Renders the named template with the given context.
    ///
    /// # Errors
    ///
    /// Returns an error if the template is not found or rendering fails.
    pub fn render(
        &self,
        name: &str,
        ctx: &RenderContext,
    ) -> Result<String, Box<dyn std::error::Error>> {
        let tmpl = self.env.get_template(name)?;

        // Pre-compute grouped build args.
        let groups = grouped_build_args(ctx);
        let build_arg_groups: Vec<Value> = groups
            .iter()
            .map(|g| {
                let args: Vec<Value> = g
                    .args
                    .iter()
                    .map(|a| {
                        context! {
                            line => a.line,
                            comment => a.comment,
                        }
                    })
                    .collect();
                context! {
                    label => g.label,
                    args => args,
                }
            })
            .collect();

        // Split cache volumes into name:path pairs for the template.
        let cache_volumes: Vec<Value> = ctx
            .cache_volumes
            .iter()
            .map(|v| {
                let parts: Vec<&str> = v.splitn(2, ':').collect();
                context! {
                    name => parts[0],
                    path => parts.get(1).unwrap_or(&""),
                }
            })
            .collect();

        // Build feature set for `in` checks.
        let features: Vec<String> = ctx.enabled_features.iter().map(|f| f.id.clone()).collect();

        // Explicit features for igor.yml (only explicitly selected, in registry order).
        let explicit_features: Vec<&str> = ctx
            .enabled_features
            .iter()
            .filter(|f| ctx.selection.explicit.contains(&f.id))
            .map(|f| f.id.as_str())
            .collect();

        // Versions as a sorted list of (key, value) for deterministic iteration.
        let versions: Vec<Value> = ctx
            .versions
            .iter()
            .map(|(k, v)| {
                context! {
                    key => k,
                    val => v,
                }
            })
            .collect();

        // Agents context.
        let agents = context! {
            max => ctx.agents.max,
            username => &ctx.agents.username,
            network => &ctx.agents.network,
            image_tag => &ctx.agents.image_tag,
            shared_volumes => &ctx.agents.shared_volumes,
            repos => &ctx.agents.repos,
        };

        let template_ctx = context! {
            project_name => &ctx.project.name,
            username => &ctx.project.username,
            base_image => &ctx.project.base_image,
            containers_dir => &ctx.containers_dir,
            build_arg_groups => build_arg_groups,
            cache_volumes => cache_volumes,
            vscode_extensions => &ctx.vscode_extensions,
            needs_bindfs => ctx.needs_bindfs,
            needs_docker => ctx.needs_docker,
            worktree_mounts => &ctx.worktree_mounts,
            features => features,
            explicit_features => explicit_features,
            versions => versions,
            has_agents => ctx.has_agents(),
            agents => agents,
        };

        let output = tmpl.render(template_ctx)?;
        Ok(output)
    }
}
