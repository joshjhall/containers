# GitHub Actions Pinning Policy

Third-party GitHub Actions are pinned to full commit SHAs. This is
defense-in-depth against supply-chain tampering: a mutable tag (`@v3`,
`@v0.36.0`, `@stable`) can be force-pushed to point at a different commit —
accidentally, or via an upstream account/repo compromise — so a workflow starts
executing different code **with no diff in this repository**. The
`evidence-run.yml` workflow is the sharpest case, because its runs have access
to `secrets.CONTAINERS_DB_PAT`.

Filed as issue #650, surfaced by the adversarial pre-PR review on #641 (PR #649).

## Policy

| Action owner                        | Class       | Ref requirement                          |
| ----------------------------------- | ----------- | ---------------------------------------- |
| `actions/*`, `github/*`             | First-party | MAY stay on a major tag (`@v4`)          |
| everything else (`docker/*`, `dtolnay/*`, `Swatinem/*`, `aquasecurity/*`, `sigstore/*`, `anchore/*`, `hadolint/*`, `softprops/*`, `gitleaks/*`, `extractions/*`, `lewagon/*`, `pascalgn/*`, …) | Third-party | MUST be a full 40-hex commit SHA + `# version` comment |

Rationale for the split:

- **First-party (`actions/*`, `github/*`)** are operated by GitHub itself and
  share the runner's trust boundary. Pinning them buys little — an attacker who
  can rewrite `actions/checkout` already controls the platform — and their major
  tags churn constantly, so pinning would create ongoing update noise. They are
  left on major tags by deliberate exception.
- **Third-party** actions are the real exposure: independent maintainers,
  independent account security, tags the maintainer (or an attacker who
  compromises them) can move. These are pinned to an immutable commit SHA.

## Format

Pin to the full 40-character commit SHA with a trailing human-readable version
comment:

```yaml
uses: docker/setup-qemu-action@c7c53464625b32c7a7e944ae62b3e17d2b600130 # v3.7.0
```

The comment is not decorative — it is the only human-readable record of which
version the SHA corresponds to, and the CI guard (below) requires it. `dprint`
normalizes the spacing before `#` to a single space, so write it that way.

### Notes on specific pins

- **`dtolnay/rust-toolchain@<sha>  # stable branch`** — this action selects the
  Rust channel from a *branch* (`stable`), not a release tag. The pinned SHA is
  the tip of the `stable` branch at pin time; its `action.yml` keeps
  `default: stable`, so input-less usages still install live stable at runtime.
  Only the action's own code is frozen — the toolchain it installs is not.
- **`pascalgn/automerge-action`** — the workflow previously referenced
  `pascalgn/merge-action`, a GitHub rename that survives only as a redirect. The
  pin uses the canonical `pascalgn/automerge-action` name so the SHA resolves
  without relying on the redirect.
- **Floating majors → real releases** — where a repo's `@v2`/`@v3` major tag
  pointed *ahead* of its latest semver release (e.g. `Swatinem/rust-cache@v2`),
  the pin targets the last tagged release commit (`v2.9.1`), not the moving
  major-tag head.

## Updating a pin

To bump a third-party action:

1. Resolve the new SHA for the desired tag:

   ```bash
   gh api repos/<owner>/<repo>/commits/<tag> --jq '.sha'
   ```

1. Replace the SHA in the `uses:` line and update the `# version` comment to
   match the tag.
1. Run `just test` (the guard test below runs under `./tests/run_unit_tests.sh`).

Dependabot can also be configured to bump SHA pins while preserving the comment;
that is not yet wired up here.

## CI guard

`tests/unit/action-pinning.sh` enforces this policy on every CI run (via
`./tests/run_unit_tests.sh`, invoked from `.github/workflows/ci.yml`). It fails
if any third-party `uses:` is not SHA-pinned, or if a SHA-pinned action is
missing its `# version` comment. A new unpinned third-party action therefore
cannot land silently.
