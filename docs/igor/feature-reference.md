# Igor Feature Reference

<!-- Generated from cmd/igor/internal/feature/registry.go — regenerate with:
     cd cmd/igor && go run ./tools/gen-feature-docs (future)
     For now, keep in sync manually when registry changes. -->

Complete reference for all features available in the igor feature registry.
Each feature maps to a Docker build argument (`INCLUDE_<FEATURE>=true`) in the
containers build system.

## Languages

| ID            | Build Arg             | Display Name | Description                                         | Version Arg      | Default | Cache Volumes               | VS Code Extensions                                             | Requires      |
| ------------- | --------------------- | ------------ | --------------------------------------------------- | ---------------- | ------- | --------------------------- | -------------------------------------------------------------- | ------------- |
| `python`      | `INCLUDE_PYTHON`      | Python       | Python runtime                                      | `PYTHON_VERSION` | 3.14.0  | pip-cache, poetry-cache     | —                                                              | —             |
| `python_dev`  | `INCLUDE_PYTHON_DEV`  | Python Dev   | Python development tools (linters, formatters, LSP) | —                | —       | —                           | ms-python.python, ms-python.vscode-pylance, charliermarsh.ruff | python        |
| `node`        | `INCLUDE_NODE`        | Node.js      | Node.js runtime                                     | `NODE_VERSION`   | 22.12.0 | npm-cache                   | —                                                              | —             |
| `node_dev`    | `INCLUDE_NODE_DEV`    | Node.js Dev  | Node.js development tools (LSP, debug)              | —                | —       | —                           | dbaeumer.vscode-eslint                                         | node          |
| `rust`        | `INCLUDE_RUST`        | Rust         | Rust toolchain                                      | `RUST_VERSION`   | 1.83.0  | cargo-cache, rustup-cache   | —                                                              | —             |
| `rust_dev`    | `INCLUDE_RUST_DEV`    | Rust Dev     | Rust development tools (rust-analyzer, clippy)      | —                | —       | —                           | rust-lang.rust-analyzer                                        | rust, cron    |
| `golang`      | `INCLUDE_GOLANG`      | Go           | Go toolchain                                        | `GO_VERSION`     | 1.23.4  | go-cache                    | —                                                              | —             |
| `golang_dev`  | `INCLUDE_GOLANG_DEV`  | Go Dev       | Go development tools (gopls, dlv)                   | —                | —       | —                           | golang.go                                                      | golang        |
| `ruby`        | `INCLUDE_RUBY`        | Ruby         | Ruby runtime                                        | `RUBY_VERSION`   | 3.4.1   | bundle-cache                | —                                                              | —             |
| `ruby_dev`    | `INCLUDE_RUBY_DEV`    | Ruby Dev     | Ruby development tools (solargraph, rubocop)        | —                | —       | —                           | shopify.ruby-lsp                                               | ruby          |
| `java`        | `INCLUDE_JAVA`        | Java         | Java JDK                                            | `JAVA_VERSION`   | 21      | —                           | —                                                              | —             |
| `java_dev`    | `INCLUDE_JAVA_DEV`    | Java Dev     | Java development tools (jdtls)                      | —                | —       | —                           | redhat.java, vscjava.vscode-java-debug                         | java          |
| `r`           | `INCLUDE_R`           | R            | R statistical computing                             | `R_VERSION`      | 4.4.2   | —                           | —                                                              | —             |
| `r_dev`       | `INCLUDE_R_DEV`       | R Dev        | R development tools (languageserver)                | —                | —       | —                           | reditorsupport.r                                               | r             |
| `mojo`        | `INCLUDE_MOJO`        | Mojo         | Mojo programming language                           | `MOJO_VERSION`   | 25.4    | —                           | —                                                              | —             |
| `mojo_dev`    | `INCLUDE_MOJO_DEV`    | Mojo Dev     | Mojo development tools                              | —                | —       | —                           | —                                                              | mojo          |
| `kotlin`      | `INCLUDE_KOTLIN`      | Kotlin       | Kotlin programming language (auto-installs Java)    | `KOTLIN_VERSION` | 2.3.0   | kotlin-cache                | —                                                              | java          |
| `kotlin_dev`  | `INCLUDE_KOTLIN_DEV`  | Kotlin Dev   | Kotlin development tools (kotlin-language-server)   | —                | —       | —                           | fwcd.kotlin                                                    | kotlin, java  |
| `android`     | `INCLUDE_ANDROID`     | Android      | Android SDK (auto-installs Java)                    | —                | —       | android-cache, gradle-cache | —                                                              | java          |
| `android_dev` | `INCLUDE_ANDROID_DEV` | Android Dev  | Android emulator and system images                  | —                | —       | —                           | —                                                              | android, java |

## Tools

| ID          | Build Arg           | Display Name  | Description                                                  | VS Code Extensions                                                                                              | Requires | Implied By                  |
| ----------- | ------------------- | ------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------- | -------- | --------------------------- |
| `dev_tools` | `INCLUDE_DEV_TOOLS` | Dev Tools     | General development tools (git extras, fzf, Claude Code CLI) | Anthropic.claude-code, streetsidesoftware.code-spell-checker, usernamehw.errorlens, wayou.vscode-todo-highlight | bindfs   | —                           |
| `docker`    | `INCLUDE_DOCKER`    | Docker        | Docker CLI tools                                             | ms-azuretools.vscode-docker                                                                                     | —        | —                           |
| `op`        | `INCLUDE_OP`        | 1Password CLI | 1Password CLI for secrets management                         | —                                                                                                               | —        | —                           |
| `cron`      | `INCLUDE_CRON`      | Cron          | Cron daemon (auto-enabled by rust_dev, dev_tools, bindfs)    | —                                                                                                               | —        | rust_dev, dev_tools, bindfs |
| `bindfs`    | `INCLUDE_BINDFS`    | Bindfs        | FUSE permission overlay for macOS VirtioFS                   | —                                                                                                               | cron     | dev_tools                   |

## Cloud & Infrastructure

| ID           | Build Arg            | Display Name     | Description                            | VS Code Extensions  | Requires |
| ------------ | -------------------- | ---------------- | -------------------------------------- | ------------------- | -------- |
| `kubernetes` | `INCLUDE_KUBERNETES` | Kubernetes       | kubectl, k9s, Helm                     | —                   | —        |
| `terraform`  | `INCLUDE_TERRAFORM`  | Terraform        | Terraform and related tools            | hashicorp.terraform | —        |
| `aws`        | `INCLUDE_AWS`        | AWS CLI          | AWS command-line interface             | —                   | —        |
| `gcloud`     | `INCLUDE_GCLOUD`     | Google Cloud SDK | Google Cloud command-line tools        | —                   | —        |
| `cloudflare` | `INCLUDE_CLOUDFLARE` | Cloudflare       | Cloudflare Wrangler (requires Node.js) | —                   | node     |

## Database Clients

| ID                | Build Arg                 | Display Name      | Description                    |
| ----------------- | ------------------------- | ----------------- | ------------------------------ |
| `postgres_client` | `INCLUDE_POSTGRES_CLIENT` | PostgreSQL Client | PostgreSQL client tools (psql) |
| `redis_client`    | `INCLUDE_REDIS_CLIENT`    | Redis Client      | Redis client tools (redis-cli) |
| `sqlite_client`   | `INCLUDE_SQLITE_CLIENT`   | SQLite Client     | SQLite client tools            |

## AI/ML

| ID       | Build Arg        | Display Name | Description       | Cache Volumes |
| -------- | ---------------- | ------------ | ----------------- | ------------- |
| `ollama` | `INCLUDE_OLLAMA` | Ollama       | Local LLM runtime | ollama-cache  |

## Dependency Resolution

Igor automatically resolves dependencies using two mechanisms:

### Requires

When you select a feature, all features in its `Requires` list are
automatically added. This is transitive — if A requires B and B requires C,
selecting A adds both B and C.

### Implied By

Some features declare an `ImpliedBy` list. When any feature in that list is
selected, the declaring feature is auto-added. This is used for features like
`cron` that should be present whenever certain other features are active.

### Resolution Algorithm

The resolver iterates until no new dependencies are added:

1. For every selected feature, add all its `Requires`
1. For every unselected feature, check if any of its `ImpliedBy` are selected
1. Repeat until stable

Auto-resolved features are tracked separately from explicit selections in the
`.igor.yml` state file.

### Common Dependency Chains

| You Select   | Auto-Added       | Reason                                                                                |
| ------------ | ---------------- | ------------------------------------------------------------------------------------- |
| `dev_tools`  | `bindfs`, `cron` | dev_tools requires bindfs; bindfs requires cron; cron implied by dev_tools and bindfs |
| `rust_dev`   | `rust`, `cron`   | rust_dev requires rust and cron                                                       |
| `kotlin`     | `java`           | kotlin requires java                                                                  |
| `kotlin_dev` | `kotlin`, `java` | kotlin_dev requires kotlin and java                                                   |
| `android`    | `java`           | android requires java                                                                 |
| `cloudflare` | `node`           | cloudflare requires node                                                              |

## Version Resolution

Features with a `VersionArg` support version configuration. Default versions
come from the registry and can be overridden in `.igor.yml`:

```yaml
versions:
  PYTHON_VERSION: "3.12" # Partial version — resolves to latest 3.12.x
  NODE_VERSION: "22.12.0" # Exact version
```

The containers build system supports partial version formats for languages.
See the main [README.md](../../README.md#version-specification-strategy) for
details on partial version resolution.
