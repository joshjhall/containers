---
description: Resolve lock file merge conflicts by regenerating from the manifest. Use when merge conflicts occur in package-lock.json, Cargo.lock, go.sum, or similar lock files.
---

# Rebase Lock File

Resolves lock file merge conflicts by accepting one side and regenerating.
Line-by-line merging of lock files is unreliable — always regenerate.

## Supported Lock Files

| Lock File           | Manifest         | Regenerate Command        |
| ------------------- | ---------------- | ------------------------- |
| `package-lock.json` | `package.json`   | `npm install`             |
| `yarn.lock`         | `package.json`   | `yarn install`            |
| `pnpm-lock.yaml`    | `package.json`   | `pnpm install`            |
| `Cargo.lock`        | `Cargo.toml`     | `cargo generate-lockfile` |
| `Gemfile.lock`      | `Gemfile`        | `bundle lock`             |
| `poetry.lock`       | `pyproject.toml` | `poetry lock --no-update` |
| `go.sum`            | `go.mod`         | `go mod tidy`             |
| `composer.lock`     | `composer.json`  | `composer update --lock`  |

## Resolution Steps

1. **Accept ours** (the branch being merged into):

   ```bash
   git checkout --ours <lockfile>
   git add <lockfile>
   ```

1. **Regenerate** using the appropriate command from the table above

1. **Stage the regenerated file**:

   ```bash
   git add <lockfile>
   ```

1. **Verify** the regenerated lock file is valid by checking the package
   manager doesn't report errors

## When to Use

- Any merge conflict in a lock file listed above
- After resolving manifest conflicts (e.g., both sides added dependencies
  to `package.json`)

## When NOT to Use

- Conflicts in the manifest itself (`package.json`, `Cargo.toml`) —
  those require understanding which dependencies to keep
