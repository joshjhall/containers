//! Feature registry — the canonical ordered catalog of all container features.

use indexmap::IndexMap;

use super::{Category, Feature};

/// Holds the full catalog of available features in registration order.
#[derive(Debug, Clone)]
pub struct Registry {
    features: IndexMap<String, Feature>,
}

impl Registry {
    /// Creates the built-in feature registry populated from the containers
    /// build-args schema and hand-maintained metadata.
    #[must_use]
    #[expect(clippy::too_many_lines)]
    pub fn new() -> Self {
        let mut r = Self { features: IndexMap::new() };

        // === Languages ===

        r.add(Feature {
            id: "python".into(),
            build_arg: "INCLUDE_PYTHON".into(),
            display_name: "Python".into(),
            description: "Python runtime (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("PYTHON_VERSION".into()),
            default_version: Some("3.14".into()),
            env_file: Some("python.env".into()),
            cache_volumes: vec!["pip-cache:/cache/pip".into(), "poetry-cache:/cache/poetry".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "python_dev".into(),
            build_arg: "INCLUDE_PYTHON_DEV".into(),
            display_name: "Python Dev".into(),
            description: "Python development tools (linters, formatters, LSP)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("python".into()),
            env_file: Some("python-dev.env".into()),
            requires: vec!["python".into()],
            vscode_extensions: vec![
                "ms-python.python".into(),
                "ms-python.vscode-pylance".into(),
                "charliermarsh.ruff".into(),
            ],
            ..Feature::default()
        });

        r.add(Feature {
            id: "node".into(),
            build_arg: "INCLUDE_NODE".into(),
            display_name: "Node.js".into(),
            description: "Node.js runtime (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("NODE_VERSION".into()),
            default_version: Some("22".into()),
            env_file: Some("node.env".into()),
            cache_volumes: vec!["npm-cache:/cache/npm".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "node_dev".into(),
            build_arg: "INCLUDE_NODE_DEV".into(),
            display_name: "Node.js Dev".into(),
            description: "Node.js development tools (LSP, debug)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("node".into()),
            env_file: Some("node.env".into()),
            requires: vec!["node".into()],
            vscode_extensions: vec!["dbaeumer.vscode-eslint".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "rust".into(),
            build_arg: "INCLUDE_RUST".into(),
            display_name: "Rust".into(),
            description: "Rust toolchain (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("RUST_VERSION".into()),
            default_version: Some("1.83".into()),
            env_file: Some("rust.env".into()),
            cache_volumes: vec![
                "cargo-cache:/cache/cargo".into(),
                "rustup-cache:/cache/rustup".into(),
            ],
            ..Feature::default()
        });
        r.add(Feature {
            id: "rust_dev".into(),
            build_arg: "INCLUDE_RUST_DEV".into(),
            display_name: "Rust Dev".into(),
            description: "Rust development tools (rust-analyzer, clippy)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("rust".into()),
            env_file: Some("rust-dev.env".into()),
            requires: vec!["rust".into(), "cron".into()],
            vscode_extensions: vec!["rust-lang.rust-analyzer".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "golang".into(),
            build_arg: "INCLUDE_GOLANG".into(),
            display_name: "Go".into(),
            description: "Go toolchain (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("GO_VERSION".into()),
            default_version: Some("1.23".into()),
            env_file: Some("golang.env".into()),
            cache_volumes: vec!["go-cache:/cache/go".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "golang_dev".into(),
            build_arg: "INCLUDE_GOLANG_DEV".into(),
            display_name: "Go Dev".into(),
            description: "Go development tools (gopls, dlv)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("golang".into()),
            env_file: Some("golang.env".into()),
            requires: vec!["golang".into()],
            vscode_extensions: vec!["golang.go".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "ruby".into(),
            build_arg: "INCLUDE_RUBY".into(),
            display_name: "Ruby".into(),
            description: "Ruby runtime (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("RUBY_VERSION".into()),
            default_version: Some("3.4".into()),
            env_file: Some("ruby.env".into()),
            cache_volumes: vec!["bundle-cache:/cache/bundle".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "ruby_dev".into(),
            build_arg: "INCLUDE_RUBY_DEV".into(),
            display_name: "Ruby Dev".into(),
            description: "Ruby development tools (solargraph, rubocop)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("ruby".into()),
            env_file: Some("ruby.env".into()),
            requires: vec!["ruby".into()],
            vscode_extensions: vec!["shopify.ruby-lsp".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "java".into(),
            build_arg: "INCLUDE_JAVA".into(),
            display_name: "Java".into(),
            description: "Java JDK".into(),
            category: Category::Language,
            version_arg: Some("JAVA_VERSION".into()),
            default_version: Some("21".into()),
            env_file: Some("java.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "java_dev".into(),
            build_arg: "INCLUDE_JAVA_DEV".into(),
            display_name: "Java Dev".into(),
            description: "Java development tools (jdtls)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("java".into()),
            env_file: Some("java.env".into()),
            requires: vec!["java".into()],
            vscode_extensions: vec!["redhat.java".into(), "vscjava.vscode-java-debug".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "r".into(),
            build_arg: "INCLUDE_R".into(),
            display_name: "R".into(),
            description: "R statistical computing (auto-resolves to latest patch)".into(),
            category: Category::Language,
            version_arg: Some("R_VERSION".into()),
            default_version: Some("4.4".into()),
            env_file: Some("r.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "r_dev".into(),
            build_arg: "INCLUDE_R_DEV".into(),
            display_name: "R Dev".into(),
            description: "R development tools (languageserver)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("r".into()),
            env_file: Some("r.env".into()),
            requires: vec!["r".into()],
            vscode_extensions: vec!["reditorsupport.r".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "mojo".into(),
            build_arg: "INCLUDE_MOJO".into(),
            display_name: "Mojo".into(),
            description: "Mojo programming language".into(),
            category: Category::Language,
            version_arg: Some("MOJO_VERSION".into()),
            default_version: Some("25.4".into()),
            env_file: Some("mojo.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "mojo_dev".into(),
            build_arg: "INCLUDE_MOJO_DEV".into(),
            display_name: "Mojo Dev".into(),
            description: "Mojo development tools".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("mojo".into()),
            env_file: Some("mojo.env".into()),
            requires: vec!["mojo".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "kotlin".into(),
            build_arg: "INCLUDE_KOTLIN".into(),
            display_name: "Kotlin".into(),
            description:
                "Kotlin programming language (auto-installs Java, auto-resolves to latest patch)"
                    .into(),
            category: Category::Language,
            version_arg: Some("KOTLIN_VERSION".into()),
            default_version: Some("2.3".into()),
            env_file: Some("kotlin.env".into()),
            requires: vec!["java".into()],
            cache_volumes: vec!["kotlin-cache:/cache/kotlin".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "kotlin_dev".into(),
            build_arg: "INCLUDE_KOTLIN_DEV".into(),
            display_name: "Kotlin Dev".into(),
            description: "Kotlin development tools (kotlin-language-server)".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("kotlin".into()),
            env_file: Some("kotlin.env".into()),
            requires: vec!["kotlin".into(), "java".into()],
            vscode_extensions: vec!["fwcd.kotlin".into()],
            ..Feature::default()
        });

        r.add(Feature {
            id: "android".into(),
            build_arg: "INCLUDE_ANDROID".into(),
            display_name: "Android".into(),
            description: "Android SDK (auto-installs Java)".into(),
            category: Category::Language,
            env_file: Some("android.env".into()),
            requires: vec!["java".into()],
            cache_volumes: vec![
                "android-cache:/cache/android-sdk".into(),
                "gradle-cache:/cache/gradle".into(),
            ],
            ..Feature::default()
        });
        r.add(Feature {
            id: "android_dev".into(),
            build_arg: "INCLUDE_ANDROID_DEV".into(),
            display_name: "Android Dev".into(),
            description: "Android emulator and system images".into(),
            category: Category::Language,
            is_dev: true,
            base_lang: Some("android".into()),
            env_file: Some("android.env".into()),
            requires: vec!["android".into(), "java".into()],
            ..Feature::default()
        });

        // === Tools ===

        r.add(Feature {
            id: "dev_tools".into(),
            build_arg: "INCLUDE_DEV_TOOLS".into(),
            display_name: "Dev Tools".into(),
            description: "General development tools (git extras, fzf, Claude Code CLI)".into(),
            category: Category::Tool,
            env_file: Some("dev-tools.env".into()),
            requires: vec!["bindfs".into()],
            vscode_extensions: vec![
                "Anthropic.claude-code".into(),
                "streetsidesoftware.code-spell-checker".into(),
                "usernamehw.errorlens".into(),
                "wayou.vscode-todo-highlight".into(),
            ],
            ..Feature::default()
        });
        r.add(Feature {
            id: "docker".into(),
            build_arg: "INCLUDE_DOCKER".into(),
            display_name: "Docker".into(),
            description: "Docker CLI tools".into(),
            category: Category::Tool,
            env_file: Some("docker.env".into()),
            vscode_extensions: vec!["ms-azuretools.vscode-docker".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "op".into(),
            build_arg: "INCLUDE_OP".into(),
            display_name: "1Password CLI".into(),
            description: "1Password CLI for secrets management".into(),
            category: Category::Tool,
            env_file: Some("op-cli.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "cron".into(),
            build_arg: "INCLUDE_CRON".into(),
            display_name: "Cron".into(),
            description: "Cron daemon (auto-enabled by rust_dev, dev_tools, bindfs)".into(),
            category: Category::Tool,
            env_file: Some("cron.env".into()),
            implied_by: vec!["rust_dev".into(), "dev_tools".into(), "bindfs".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "bindfs".into(),
            build_arg: "INCLUDE_BINDFS".into(),
            display_name: "Bindfs".into(),
            description: "FUSE permission overlay for macOS VirtioFS".into(),
            category: Category::Tool,
            requires: vec!["cron".into()],
            implied_by: vec!["dev_tools".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "ollama".into(),
            build_arg: "INCLUDE_OLLAMA".into(),
            display_name: "Ollama".into(),
            description: "Local LLM runtime".into(),
            category: Category::Ai,
            env_file: Some("ollama.env".into()),
            cache_volumes: vec!["ollama-cache:/cache/ollama".into()],
            ..Feature::default()
        });

        // === Cloud & Infrastructure ===

        r.add(Feature {
            id: "kubernetes".into(),
            build_arg: "INCLUDE_KUBERNETES".into(),
            display_name: "Kubernetes".into(),
            description: "kubectl, k9s, Helm".into(),
            category: Category::Cloud,
            env_file: Some("kubernetes.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "terraform".into(),
            build_arg: "INCLUDE_TERRAFORM".into(),
            display_name: "Terraform".into(),
            description: "Terraform and related tools".into(),
            category: Category::Cloud,
            env_file: Some("terraform.env".into()),
            vscode_extensions: vec!["hashicorp.terraform".into()],
            ..Feature::default()
        });
        r.add(Feature {
            id: "aws".into(),
            build_arg: "INCLUDE_AWS".into(),
            display_name: "AWS CLI".into(),
            description: "AWS command-line interface".into(),
            category: Category::Cloud,
            env_file: Some("aws.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "gcloud".into(),
            build_arg: "INCLUDE_GCLOUD".into(),
            display_name: "Google Cloud SDK".into(),
            description: "Google Cloud command-line tools".into(),
            category: Category::Cloud,
            env_file: Some("gcloud.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "cloudflare".into(),
            build_arg: "INCLUDE_CLOUDFLARE".into(),
            display_name: "Cloudflare".into(),
            description: "Cloudflare Wrangler (requires Node.js)".into(),
            category: Category::Cloud,
            env_file: Some("cloudflare.env".into()),
            requires: vec!["node".into()],
            ..Feature::default()
        });

        // === Database Clients ===

        r.add(Feature {
            id: "postgres_client".into(),
            build_arg: "INCLUDE_POSTGRES_CLIENT".into(),
            display_name: "PostgreSQL Client".into(),
            description: "PostgreSQL client tools (psql)".into(),
            category: Category::Database,
            env_file: Some("database-clients.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "redis_client".into(),
            build_arg: "INCLUDE_REDIS_CLIENT".into(),
            display_name: "Redis Client".into(),
            description: "Redis client tools (redis-cli)".into(),
            category: Category::Database,
            env_file: Some("database-clients.env".into()),
            ..Feature::default()
        });
        r.add(Feature {
            id: "sqlite_client".into(),
            build_arg: "INCLUDE_SQLITE_CLIENT".into(),
            display_name: "SQLite Client".into(),
            description: "SQLite client tools".into(),
            category: Category::Database,
            env_file: Some("database-clients.env".into()),
            ..Feature::default()
        });

        r
    }

    fn add(&mut self, feature: Feature) {
        self.features.insert(feature.id.clone(), feature);
    }

    /// Returns a feature by ID, or `None` if not found.
    #[must_use]
    pub fn get(&self, id: &str) -> Option<&Feature> {
        self.features.get(id)
    }

    /// Returns all features in registration order.
    pub fn all(&self) -> impl Iterator<Item = &Feature> {
        self.features.values()
    }

    /// Returns features matching the given category, in registration order.
    pub fn by_category(&self, cat: Category) -> impl Iterator<Item = &Feature> {
        self.features.values().filter(move |f| f.category == cat)
    }

    /// Returns non-dev language features for the wizard language step.
    pub fn languages(&self) -> impl Iterator<Item = &Feature> {
        self.by_category(Category::Language).filter(|f| !f.is_dev)
    }
}

impl Default for Registry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_has_34_features() {
        let reg = Registry::new();
        assert_eq!(reg.features.len(), 34);
    }

    #[test]
    fn all_features_have_build_arg() {
        let reg = Registry::new();
        for f in reg.all() {
            assert!(!f.build_arg.is_empty(), "feature {} has empty build_arg", f.id);
        }
    }

    #[test]
    fn languages_excludes_dev() {
        let reg = Registry::new();
        for f in reg.languages() {
            assert!(!f.is_dev, "{} is a dev feature but appeared in languages()", f.id);
        }
    }

    #[test]
    fn dev_features_have_base_lang() {
        let reg = Registry::new();
        for f in reg.all() {
            if f.is_dev {
                assert!(f.base_lang.is_some(), "dev feature {} is missing base_lang", f.id);
            }
        }
    }

    #[test]
    fn requires_reference_valid_features() {
        let reg = Registry::new();
        for f in reg.all() {
            for req in &f.requires {
                assert!(
                    reg.get(req).is_some(),
                    "feature {} requires unknown feature {}",
                    f.id,
                    req
                );
            }
        }
    }

    #[test]
    fn implied_by_references_valid_features() {
        let reg = Registry::new();
        for f in reg.all() {
            for imp in &f.implied_by {
                assert!(reg.get(imp).is_some(), "feature {} has unknown implied_by {}", f.id, imp);
            }
        }
    }
}
