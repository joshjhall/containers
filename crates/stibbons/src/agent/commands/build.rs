//! `stibbons agent build`.

use std::io::Write;

use super::super::context::AgentContext;
use super::super::docker::DockerRunner;
use super::{CmdResult, to_refs};

/// `stibbons agent build` — build the agent image from feature/version args.
///
/// # Errors
///
/// Propagates Docker failures (volume/image creation). `--dry-run` prints the
/// command and makes zero Docker calls.
pub fn run_build(
    ctx: &AgentContext,
    docker: &dyn DockerRunner,
    out: &mut dyn Write,
    dry_run: bool,
) -> CmdResult {
    // Ensure shared cache volumes exist (skipped entirely under --dry-run).
    if !dry_run {
        for vol in &ctx.shared_volumes {
            let vol_name = vol.split(':').next().unwrap_or(vol);
            if docker.run(&["volume", "inspect", vol_name]).is_err() {
                docker.run(&["volume", "create", vol_name])?;
                writeln!(out, "Created volume {vol_name}")?;
            }
        }
    }

    let image_ref = format!("{}:{}", ctx.image_name, ctx.image_tag);
    let dockerfile = format!("{}/Dockerfile", ctx.containers_dir.display());
    let project_arg = format!("PROJECT_NAME={}", ctx.project);
    let username_arg = format!("USERNAME={}", ctx.username);
    let containers_dir = ctx.containers_dir.display().to_string();

    let mut args: Vec<String> = vec![
        "build".into(),
        "-t".into(),
        image_ref,
        "-f".into(),
        dockerfile,
        "--build-arg".into(),
        "PROJECT_PATH=.".into(),
        "--build-arg".into(),
        project_arg,
        "--build-arg".into(),
        username_arg,
    ];

    for f in &ctx.features {
        args.push("--build-arg".into());
        args.push(format!("{}=true", f.build_arg));
    }
    for (arg_name, version) in &ctx.cfg.versions {
        args.push("--build-arg".into());
        args.push(format!("{arg_name}={version}"));
    }
    args.push(containers_dir);

    if dry_run {
        writeln!(out, "docker {}", args.join(" "))?;
        return Ok(());
    }

    writeln!(out, "Building {}:{} ...", ctx.image_name, ctx.image_tag)?;
    docker.passthrough(&to_refs(&args))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::super::docker::MockDocker;
    use super::super::super::test_support::load_ctx;

    use super::super::test_helpers::{capture, cfg};
    use super::*;

    // --- build ---

    #[test]
    fn build_dry_run_prints_and_makes_no_calls() {
        let mut c = cfg(&["python", "node"]);
        c.versions.insert("PYTHON_VERSION".into(), "3.12.0".into());
        let (ctx, _tmp) = load_ctx(c);
        let docker = MockDocker::new();

        let (out, res) = capture(|o| run_build(&ctx, &docker, o, true));
        res.unwrap();

        assert!(out.contains("docker build"));
        assert!(out.contains("INCLUDE_PYTHON=true"));
        assert!(out.contains("INCLUDE_NODE=true"));
        assert!(out.contains("PYTHON_VERSION=3.12.0"));
        assert!(out.contains("PROJECT_NAME=myproject"));
        // Default username is used even though no username was configured.
        assert!(out.contains("USERNAME=agent"));
        assert_eq!(docker.call_count(), 0, "dry-run must not call docker");
    }

    #[test]
    fn build_dry_run_emits_dev_and_docker_args() {
        let (ctx, _tmp) = load_ctx(cfg(&["python", "python_dev", "docker"]));
        let docker = MockDocker::new();

        let (out, res) = capture(|o| run_build(&ctx, &docker, o, true));
        res.unwrap();

        assert!(out.contains("INCLUDE_PYTHON=true"));
        assert!(out.contains("INCLUDE_PYTHON_DEV=true"));
        assert!(out.contains("INCLUDE_DOCKER=true"));
    }
}
