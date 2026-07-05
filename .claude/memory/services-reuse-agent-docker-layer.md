---
name: services-reuse-agent-docker-layer
description: "stibbons services commands (#311) reuse agent module's Docker layer, not a fresh port"
metadata:
  node_type: memory
  type: project
  originSessionId: 2cdb4e20-ccf0-4b17-8187-681c5f771c83
---

Issue #311 (port `igor services` → `stibbons services`) was largely an
**assembly job on top of #310's shared layer**, not a from-scratch port. The Go
source was already retired from the repo, so porting is spec-driven + patterned
on the agent module.

**Key:** `crates/stibbons/src/agent/{context,db,docker}.rs` already shipped every
shared piece the services commands needed — `ServiceConfig` + `IgorConfig.services`
(in containers-common), `service_container_name`, `wait_for_postgres`,
`extract_pg_credentials`, `sql_ident`, `DockerRunner`+`MockDocker`, and the
network-create idiom. #311 exposed those (`pub` submodules — note clippy's
`redundant_pub_crate` wants `pub`, not `pub(crate)`, inside a private module),
extracted `ensure_network` (shared by `agent start` + `services start`, output
must stay byte-identical or agent tests break), added `agent::db::reset_per_agent_dbs`,
and built `crates/stibbons/src/services/{mod,commands}.rs`.

Readiness polling runs *inside* the container via `docker exec … sh -c` so it's
`MockDocker`-testable with no daemon (`pg_isready` for per_agent_db, `nc -z`
otherwise). Same approach should apply to the remaining #285-decomposed ports.

Related: [[stibbons-binary-distribution]], [[v5-architecture]].
