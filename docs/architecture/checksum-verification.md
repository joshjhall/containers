# Checksum Verification System

## Overview

The 4-tier checksum verification system provides progressive security for all
binary downloads during container builds. Every language runtime and tool
download passes through this pipeline, falling through tiers until one succeeds
or the build fails.

```text
verify_download()
│
├─ TIER 1: Signature Verification (GPG / Sigstore)
│  └─ Cryptographic proof of publisher authenticity
│
├─ TIER 2: Pinned Checksums (lib/checksums.json)
│  └─ Git-tracked, auditable, weekly auto-updated
│
├─ TIER 3: Published Checksums (official source)
│  └─ Fetched from publisher at build time
│
└─ TIER 4: Calculated Checksum (TOFU fallback)
   └─ Self-calculated — no external verification
       Blocked when REQUIRE_VERIFIED_DOWNLOADS=true
```

## Module Hierarchy

```text
checksum-verification.sh          ← Main orchestrator, verify_download()
├── checksum-tier4.sh             ← Tier 4 TOFU fallback + build summary
├── checksum-fetch.sh             ← Tier 3 fetcher helpers (curl wrappers)
│   ├── checksum-fetch-go.sh      ← Go-specific checksum fetching
│   ├── checksum-fetch-ruby.sh    ← Ruby-specific checksum fetching
│   └── checksum-fetch-maven.sh   ← Maven/Java checksum fetching
├── signature-verify.sh           ← Tier 1 dispatcher (Sigstore + GPG)
│   ├── sigstore-verify.sh        ← Cosign-based Sigstore verification
│   └── gpg-verify.sh             ← GPG verification orchestrator
│       ├── gpg-verify-golang.sh  ← Go .asc signature verification
│       ├── gpg-verify-nodejs.sh  ← Node.js SHASUMS GPG verification
│       └── gpg-verify-terraform.sh ← Terraform SHA256SUMS GPG verification
└── lib/checksums.json            ← Tier 2 pinned checksum database
```

**Loading strategy**: `checksum-verification.sh` eagerly sources
`checksum-tier4.sh` and `checksum-fetch.sh`. `signature-verify.sh` is
lazy-loaded on the first Tier 1 call (`verify_signature_tier`), which in turn
loads `sigstore-verify.sh` and `gpg-verify.sh`.

## Tier Details

### Tier 1 — Signature Verification

Cryptographic proof using the publisher's signing key. Highest security.

| Language      | Method                              | Tooling Required |
| ------------- | ----------------------------------- | ---------------- |
| Python 3.11+  | Sigstore (preferred) + GPG fallback | cosign + gpg     |
| Python \<3.11 | GPG only                            | gpg              |
| Node.js       | GPG (SHASUMS256.txt.sig)            | gpg              |
| Go            | GPG (.asc signatures)               | gpg              |
| Terraform     | GPG (SHA256SUMS.sig)                | gpg              |
| kubectl       | Sigstore                            | cosign           |

### Tier 2 — Pinned Checksums

SHA256 checksums stored in `lib/checksums.json`, tracked in git. Updated weekly
by the `auto-patch` workflow. Lookup uses `jq` when available.

### Tier 3 — Published Checksums

Fetched from official publisher URLs at build time (e.g., `python.org/SHA256SUMS`,
`go.dev/dl/`). For tools (non-languages), a registry pattern is used: feature
scripts call `register_tool_checksum_fetcher` to register a fetcher function.

### Tier 4 — Calculated Checksum (TOFU)

Calculates SHA256 of the downloaded file with no external reference. Logs a
prominent security warning. Returns exit code 2 (not 0) so callers can
distinguish "verified" from "unverified". Blocked entirely when
`REQUIRE_VERIFIED_DOWNLOADS=true` or `PRODUCTION_MODE=true`.

## Fan-In Analysis

`checksum-verification.sh` is sourced by every feature that downloads binaries:

| Category            | Dependents                                                                           |
| ------------------- | ------------------------------------------------------------------------------------ |
| Language features   | `python.sh`, `node.sh`, `golang.sh`, `rust.sh`, `ruby.sh`, `kotlin.sh`, `mojo.sh`    |
| Cloud/tool features | `kubernetes.sh`, `docker.sh`, `aws.sh`, `cloudflare.sh`, `ollama.sh`, `terraform.sh` |
| Shared libraries    | `install-github-release.sh`, `install-binary-tools.sh`, `install-jdtls.sh`           |
| Build entry         | `Dockerfile` (sources for end-of-build TOFU summary)                                 |

Total: ~20 direct dependents.

## Public API Contract

### checksum-verification.sh

| Function                         | Parameters                             | Returns | Description                             |
| -------------------------------- | -------------------------------------- | ------- | --------------------------------------- |
| `verify_download`                | category, name, version, file [, arch] | 0/1/2   | Main entry — tries all tiers in order   |
| `verify_signature_tier`          | language, version, file                | 0/1     | Tier 1: signature verification          |
| `verify_pinned_checksum`         | type, name, version, file [, arch]     | 0/1     | Tier 2: pinned checksum lookup + verify |
| `lookup_pinned_checksum`         | type, name, version [, arch]           | 0/1     | Tier 2: lookup only (echoes checksum)   |
| `verify_published_checksum`      | name, version, file [, arch]           | 0/1     | Tier 3: language published checksums    |
| `verify_tool_published_checksum` | name, version, file [, arch]           | 0/1/2   | Tier 3: tool registered fetcher         |
| `register_tool_checksum_fetcher` | name, fetcher_fn                       | 0       | Register a Tier 3 fetcher for a tool    |

### checksum-tier4.sh

| Function                     | Parameters | Returns | Description                                 |
| ---------------------------- | ---------- | ------- | ------------------------------------------- |
| `verify_calculated_checksum` | file       | 2       | Tier 4: calculate + warn (always returns 2) |
| `print_tofu_summary`         | (none)     | 0       | Print end-of-build TOFU report              |

### Return Code Convention

| Code | Meaning                                        |
| ---- | ---------------------------------------------- |
| `0`  | Verification passed                            |
| `1`  | Verification failed (mismatch or policy block) |
| `2`  | No verification available (TOFU)               |

This 3-way return code lets callers distinguish "verified clean" from "failed
verification" from "no verification was possible", enabling policy decisions
like blocking TOFU in production.

## Change Protocol

1. Any change to `verify_download` parameters or return codes is a **breaking
   change** — all ~20 dependents must be checked
1. Run `./tests/run_unit_tests.sh` — all checksum verification tests must pass
1. Run at least 2 integration tests that exercise different tiers (e.g.,
   `./tests/run_integration_tests.sh python_dev rust_golang`)
1. If adding a new tier or changing tier precedence, update this document
1. If adding a new language to Tier 1 or Tier 3, add the corresponding
   `gpg-verify-*.sh` or `checksum-fetch-*.sh` module

## Related Documentation

- [Security Checksums Reference](../reference/security-checksums.md) —
  per-language checksum details and production recommendations
- [God Modules](god-modules.md) — high fan-in module patterns
  (`feature-header.sh`, `logging.sh`)
