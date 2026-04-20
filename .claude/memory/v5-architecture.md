---
name: v5 architecture decisions
description: Core architectural decisions for the v5 rewrite — three executables, manifest-driven installs, multi-distro support
type: project
originSessionId: e65cf0dc-40b0-4d1d-8929-b6c2de545141
---

v5 is a major rewrite of the container build system with three compiled Rust executables:

- **stibbons** — host + container CLI/TUI for managing the container
  system (project setup, config generation, worktree/agent management).
  May also have a shorter alias like `cbs`. Installable via Homebrew, apt,
  etc. Replaces the git submodule workflow with `stibbons init` /
  `stibbons update`.
- **igor** — container-only runtime manager. Handles post-create/post-start
  hooks, 1Password env var resolution, Claude Code setup, and other runtime
  needs. Not user-facing in the same way.
- **luggage** — the build engine. Manages feature installation across the
  multi-dimensional space of distro × distro version × feature × feature
  version. Manifest-driven with possible SQLite-backed manifest databases
  downloadable per distro version. Not directly user-facing.

**Why:** Replace fragile bash scripts with compiled solutions for speed,
robustness, security, and enterprise auditability at every step.

**How to apply:** All v5 implementation should target one of these three
binaries. Feature install logic goes in luggage's manifest system, not
bash scripts. Runtime hooks go in igor. User-facing config/setup goes in
stibbons.

Key v5 objectives:

- Multi-distro support: starting with Debian + Alpine + RHEL/UBI + Ubuntu,
  working toward all major distros
- Manifest-driven installs with distro/version compatibility constraints
  (e.g., biome only supports Debian 11 through v2.3.x)
- Coarse dependency conflict detection between tools (not full resolution like apt/npm)
- No git submodule requirement — generate and update via CLI
- Hierarchical config: global → team → project → individual dev levels
- Automated dependency updates with per-env pinning control
- Enterprise audit trail built in from the start
