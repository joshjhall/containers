//! Integration tests for [`luggage`]'s activity-policy gating.
//!
//! Each test spawns the CLI against `testdata/policy_catalog/`, which has
//! one tool per activity tier plus a `tool_below_min` tool whose only
//! version sits below `minimum_recommended`. Hermetic — no dependency on a
//! sibling containers-db checkout.

use std::path::PathBuf;
use std::process::{Command, Output};

const fn binary() -> &'static str {
    env!("CARGO_BIN_EXE_luggage")
}

fn catalog_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("testdata/policy_catalog")
}

fn run(args: &[&str]) -> Output {
    Command::new(binary())
        .args(args)
        .args(["--os", "debian", "--os-version", "13", "--arch", "amd64"])
        .arg("--catalog")
        .arg(catalog_dir())
        .output()
        .expect("spawn luggage")
}

fn assert_exit(out: &Output, expected: i32) {
    let actual = out.status.code().unwrap_or(-1);
    assert_eq!(
        actual,
        expected,
        "expected exit {expected}, got {actual}\nstdout: {}\nstderr: {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr),
    );
}

#[test]
fn default_policy_accepts_very_active() {
    let out = run(&["resolve", "tool_very_active", "--json"]);
    assert_exit(&out, 0);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("parse JSON");
    assert!(
        v.get("warnings").is_none(),
        "very-active tool should serialize without a warnings field, got: {v}",
    );
}

#[test]
fn default_policy_accepts_active_and_maintained() {
    for tier in ["tool_active", "tool_maintained"] {
        let out = run(&["resolve", tier]);
        assert_exit(&out, 0);
    }
}

#[test]
fn default_policy_refuses_slow_and_stale() {
    for tier in ["tool_slow", "tool_stale"] {
        let out = run(&["resolve", tier]);
        assert_exit(&out, 1);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("activity"),
            "stderr should explain activity threshold for {tier}: {stderr}",
        );
    }
}

#[test]
fn default_policy_refuses_dormant_and_abandoned() {
    for tier in ["tool_dormant", "tool_abandoned"] {
        let out = run(&["resolve", tier]);
        assert_exit(&out, 1);
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("below the policy threshold"),
            "stderr should explain threshold for {tier}: {stderr}",
        );
    }
}

#[test]
fn permissive_policy_accepts_every_tier() {
    for tier in [
        "tool_very_active",
        "tool_active",
        "tool_maintained",
        "tool_slow",
        "tool_stale",
        "tool_dormant",
        "tool_abandoned",
    ] {
        let out = run(&["resolve", tier, "--policy", "permissive"]);
        assert_exit(&out, 0);
    }
}

#[test]
fn igor_policy_accepts_down_to_stale() {
    for tier in ["tool_maintained", "tool_slow", "tool_stale"] {
        let out = run(&["resolve", tier, "--policy", "igor"]);
        assert_exit(&out, 0);
    }
    // igor still refuses dormant.
    let out = run(&["resolve", "tool_dormant", "--policy", "igor"]);
    assert_exit(&out, 1);
}

#[test]
fn allow_abandoned_overrides_default_policy() {
    let out = run(&["resolve", "tool_abandoned", "--allow-abandoned"]);
    assert_exit(&out, 0);
}

#[test]
fn slow_warning_serialized_when_admitted() {
    // Use --policy stibbons + --allow-abandoned to admit a Slow tool while
    // keeping warn_on_slow_or_stale = true.
    let out = run(&["resolve", "tool_slow", "--allow-abandoned", "--json"]);
    assert_exit(&out, 0);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("parse JSON");
    let warnings = v["warnings"].as_array().expect("warnings array");
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0]["kind"], "slow_or_stale_activity");
    assert_eq!(warnings[0]["score"], "slow");
}

#[test]
fn permissive_policy_suppresses_warnings() {
    let out = run(&["resolve", "tool_slow", "--policy", "permissive", "--json"]);
    assert_exit(&out, 0);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("parse JSON");
    assert!(v.get("warnings").is_none(), "permissive policy should suppress warnings, got: {v}");
}

#[test]
fn below_minimum_recommended_refused_by_default() {
    let out = run(&["resolve", "tool_below_min"]);
    assert_exit(&out, 1);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("minimum_recommended"),
        "stderr should mention minimum_recommended: {stderr}",
    );
}

#[test]
fn below_minimum_recommended_warns_when_allowed() {
    let out = run(&["resolve", "tool_below_min", "--allow-below-min-recommended", "--json"]);
    assert_exit(&out, 0);
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).expect("parse JSON");
    let warnings = v["warnings"].as_array().expect("warnings array");
    assert_eq!(warnings.len(), 1);
    assert_eq!(warnings[0]["kind"], "below_minimum_recommended");
    assert_eq!(warnings[0]["version"], "1.0.0");
    assert_eq!(warnings[0]["minimum"], "2.0.0");
}
