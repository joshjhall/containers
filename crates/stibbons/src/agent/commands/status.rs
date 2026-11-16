//! `stibbons agent status`.

use std::io::Write;

use super::super::context::{
    AgentContext, agent_suffix, container_exists, container_name, image_exists,
    is_container_running,
};
use super::super::docker::DockerRunner;
use super::CmdResult;

/// `stibbons agent status` — tabular image/network + per-agent status.
///
/// # Errors
///
/// Propagates write failures on the output sink.
pub fn run_status(ctx: &AgentContext, docker: &dyn DockerRunner, out: &mut dyn Write) -> CmdResult {
    let image_status =
        if image_exists(docker, &ctx.image_name, &ctx.image_tag) { "built" } else { "not built" };
    writeln!(out, "Image: {}:{} ({image_status})", ctx.image_name, ctx.image_tag)?;
    writeln!(out, "Network: {}\n", ctx.network)?;

    // Collect rows first so the columns can be width-aligned by hand (no table
    // crate in the workspace; mirrors the render-plan printer in main.rs).
    let mut rows: Vec<[String; 4]> =
        vec![["AGENT".into(), "CONTAINER".into(), "STATUS".into(), "WORKTREES".into()]];
    for i in 1..=ctx.max_agents {
        let name = container_name(&ctx.project, i);
        let suffix = agent_suffix(i);

        let status = if is_container_running(docker, &name) {
            "running"
        } else if container_exists(docker, &name) {
            "stopped"
        } else {
            "not created"
        };

        let exist_count = ctx
            .repos
            .iter()
            .filter(|repo| ctx.base_dir.join(format!("{repo}-{suffix}")).exists())
            .count();
        let worktrees = if exist_count == ctx.repos.len() {
            "ready".to_string()
        } else if exist_count > 0 {
            format!("{exist_count}/{}", ctx.repos.len())
        } else {
            "none".to_string()
        };

        rows.push([i.to_string(), name, status.to_string(), worktrees]);
    }

    let widths = column_widths(&rows);
    for row in &rows {
        writeln!(
            out,
            "{:<w0$}  {:<w1$}  {:<w2$}  {}",
            row[0],
            row[1],
            row[2],
            row[3],
            w0 = widths[0],
            w1 = widths[1],
            w2 = widths[2],
        )?;
    }
    Ok(())
}

/// Per-column max width across all rows, for hand-aligned tables.
fn column_widths(rows: &[[String; 4]]) -> [usize; 4] {
    let mut widths = [0usize; 4];
    for row in rows {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.len());
        }
    }
    widths
}

#[cfg(test)]
mod tests {
    use containers_common::config::AgentConfig;

    use super::super::super::docker::{MockDocker, MockResult};
    use super::super::super::test_support::load_ctx;

    use super::super::test_helpers::{capture, cfg};
    use super::*;

    // --- status ---

    #[test]
    fn status_table() {
        let mut c = cfg(&[]);
        c.agents = AgentConfig { max: 3, ..AgentConfig::default() };
        let (ctx, _tmp) = load_ctx(c);
        let docker = MockDocker::new();
        docker.on("image inspect", MockResult::ok("ok"));
        docker.on("inspect -f", MockResult::err());

        let (out, res) = capture(|o| run_status(&ctx, &docker, o));
        res.unwrap();

        assert!(out.contains("Image: myproject-agent:latest (built)"));
        assert!(out.contains("myproject-network"));
        assert!(out.contains("AGENT"));
        for i in 1..=3 {
            assert!(out.contains(&container_name("myproject", i)));
        }
        assert!(out.contains("not created"));
    }
}
