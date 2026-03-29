//! Template rendering tests — ports Go `renderer_test.go`.

use std::collections::BTreeMap;

use crate::config::{AgentConfig, ProjectConfig};
use crate::feature::{Registry, resolve};

use super::{RenderContext, Renderer};

fn testdata_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("testdata")
}

fn make_explicit(ids: &[&str]) -> std::collections::HashSet<String> {
    ids.iter().map(|s| (*s).to_string()).collect()
}

const TEMPLATE_NAMES: [&str; 5] = [
    "docker-compose.yml.tmpl",
    "devcontainer.json.tmpl",
    "env.tmpl",
    "env-example.tmpl",
    "igor.yml.tmpl",
];

#[test]
fn renderer_minimal_python() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["python", "python_dev"]), &reg);

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "myapp".into(),
            username: "developer".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::from([("PYTHON_VERSION".into(), "3.14".into())]),
        AgentConfig::default(),
    );

    let renderer = Renderer::new().unwrap();

    for tmpl in TEMPLATE_NAMES {
        let output = renderer.render(tmpl, &ctx).unwrap_or_else(|e| panic!("Render({tmpl}): {e}"));
        assert!(!output.is_empty(), "Render({tmpl}) produced empty output");

        let golden_path =
            testdata_dir().join("golden").join("minimal").join(format!("{tmpl}.golden"));

        if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
            std::fs::create_dir_all(golden_path.parent().unwrap()).unwrap();
            std::fs::write(&golden_path, &output).unwrap();
            continue;
        }

        match std::fs::read_to_string(&golden_path) {
            Ok(golden) => {
                if output != golden {
                    // Show a helpful diff
                    let out_lines: Vec<&str> = output.lines().collect();
                    let gold_lines: Vec<&str> = golden.lines().collect();
                    for (i, (o, g)) in out_lines.iter().zip(gold_lines.iter()).enumerate() {
                        if o != g {
                            panic!(
                                "Render({tmpl}) differs from golden at line {}.\n  Got:  {o}\n  Want: {g}\n\nFull output:\n{output}\n\nFull golden:\n{golden}",
                                i + 1
                            );
                        }
                    }
                    if out_lines.len() != gold_lines.len() {
                        panic!(
                            "Render({tmpl}) has {} lines, golden has {} lines.\n\nFull output:\n{output}\n\nFull golden:\n{golden}",
                            out_lines.len(),
                            gold_lines.len()
                        );
                    }
                }
            }
            Err(_) => {
                eprintln!("No golden file at {golden_path:?} (run with UPDATE_GOLDEN=1 to create)");
            }
        }
    }
}

#[test]
fn renderer_fullstack() {
    let reg = Registry::new();
    let sel = resolve(
        &make_explicit(&[
            "python",
            "python_dev",
            "node",
            "node_dev",
            "rust",
            "rust_dev",
            "golang",
            "golang_dev",
            "dev_tools",
            "docker",
            "op",
            "kubernetes",
            "terraform",
            "aws",
            "postgres_client",
            "redis_client",
            "ollama",
        ]),
        &reg,
    );

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "fullstack".into(),
            username: "dev".into(),
            base_image: "debian:bookworm-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::from([
            ("PYTHON_VERSION".into(), "3.14".into()),
            ("NODE_VERSION".into(), "22".into()),
            ("RUST_VERSION".into(), "1.83".into()),
            ("GO_VERSION".into(), "1.23".into()),
        ]),
        AgentConfig::default(),
    );

    let renderer = Renderer::new().unwrap();

    for tmpl in TEMPLATE_NAMES {
        let output = renderer.render(tmpl, &ctx).unwrap_or_else(|e| panic!("Render({tmpl}): {e}"));
        assert!(!output.is_empty(), "Render({tmpl}) produced empty output");

        let golden_path =
            testdata_dir().join("golden").join("fullstack").join(format!("{tmpl}.golden"));

        if std::env::var("UPDATE_GOLDEN").as_deref() == Ok("1") {
            std::fs::create_dir_all(golden_path.parent().unwrap()).unwrap();
            std::fs::write(&golden_path, &output).unwrap();
            continue;
        }

        match std::fs::read_to_string(&golden_path) {
            Ok(golden) => {
                if output != golden {
                    let out_lines: Vec<&str> = output.lines().collect();
                    let gold_lines: Vec<&str> = golden.lines().collect();
                    for (i, (o, g)) in out_lines.iter().zip(gold_lines.iter()).enumerate() {
                        if o != g {
                            panic!(
                                "Render({tmpl}) differs from golden at line {}.\n  Got:  {o}\n  Want: {g}\n\nFull output:\n{output}\n\nFull golden:\n{golden}",
                                i + 1
                            );
                        }
                    }
                    if out_lines.len() != gold_lines.len() {
                        panic!(
                            "Render({tmpl}) has {} lines, golden has {} lines.\n\nFull output:\n{output}\n\nFull golden:\n{golden}",
                            out_lines.len(),
                            gold_lines.len()
                        );
                    }
                }
            }
            Err(_) => {
                eprintln!("No golden file at {golden_path:?} (run with UPDATE_GOLDEN=1 to create)");
            }
        }
    }
}

#[test]
fn bindfs_capabilities() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["dev_tools"]), &reg);

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::new(),
        AgentConfig::default(),
    );

    let renderer = Renderer::new().unwrap();
    let output = renderer.render("docker-compose.yml.tmpl", &ctx).unwrap();

    // dev_tools implies bindfs, which needs cap_add and devices
    assert!(
        output.contains("SYS_ADMIN"),
        "docker-compose should include SYS_ADMIN cap_add when bindfs is selected"
    );
    assert!(
        output.contains("/dev/fuse"),
        "docker-compose should include /dev/fuse device when bindfs is selected"
    );
}

#[test]
fn docker_socket() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["docker"]), &reg);

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::new(),
        AgentConfig::default(),
    );

    let renderer = Renderer::new().unwrap();
    let output = renderer.render("docker-compose.yml.tmpl", &ctx).unwrap();

    assert!(
        output.contains("docker.sock"),
        "docker-compose should mount Docker socket when docker feature is selected"
    );
}

#[test]
fn no_docker_socket_when_not_selected() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["python"]), &reg);

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::new(),
        AgentConfig::default(),
    );

    let renderer = Renderer::new().unwrap();
    let output = renderer.render("docker-compose.yml.tmpl", &ctx).unwrap();

    assert!(
        !output.contains("docker.sock"),
        "docker-compose should NOT mount Docker socket when docker feature is not selected"
    );
}

#[test]
fn agents_shared_volumes_auto_derived() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["python", "node"]), &reg);

    // Agents config with no SharedVolumes — should auto-derive from features.
    let agents = AgentConfig {
        max: 3,
        username: "agent".into(),
        network: "net".into(),
        image_tag: "latest".into(),
        ..AgentConfig::default()
    };

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::new(),
        agents,
    );

    assert!(
        !ctx.agents.shared_volumes.is_empty(),
        "Agents.SharedVolumes should be auto-derived from feature cache volumes"
    );
    assert_eq!(
        ctx.agents.shared_volumes.len(),
        ctx.cache_volumes.len(),
        "Agents.SharedVolumes length should match CacheVolumes"
    );
}

#[test]
fn agents_shared_volumes_explicit_preserved() {
    let reg = Registry::new();
    let sel = resolve(&make_explicit(&["python", "node"]), &reg);

    // Agents config with explicit SharedVolumes — should NOT be overwritten.
    let agents = AgentConfig {
        max: 3,
        username: "agent".into(),
        network: "net".into(),
        image_tag: "latest".into(),
        shared_volumes: vec!["custom-vol:/custom".into()],
        ..AgentConfig::default()
    };

    let ctx = RenderContext::new(
        ProjectConfig {
            name: "test".into(),
            username: "dev".into(),
            base_image: "debian:trixie-slim".into(),
            ..ProjectConfig::default()
        },
        "containers",
        &sel,
        &reg,
        BTreeMap::new(),
        agents,
    );

    assert_eq!(ctx.agents.shared_volumes, vec!["custom-vol:/custom"]);
}
