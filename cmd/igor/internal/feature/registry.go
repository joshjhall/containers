package feature

// Registry holds the full catalog of available features.
type Registry struct {
	features map[string]*Feature
	order    []string // insertion order for deterministic iteration
}

// NewRegistry creates the built-in feature registry populated from
// the containers build-args schema and hand-maintained metadata.
func NewRegistry() *Registry {
	r := &Registry{
		features: make(map[string]*Feature),
	}

	// === Languages ===
	r.add(&Feature{
		ID: "python", BuildArg: "INCLUDE_PYTHON",
		DisplayName: "Python", Description: "Python runtime (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "PYTHON_VERSION", DefaultVersion: "3.14",
		EnvFile:      "python.env",
		CacheVolumes: []string{"pip-cache:/cache/pip", "poetry-cache:/cache/poetry"},
	})
	r.add(&Feature{
		ID: "python_dev", BuildArg: "INCLUDE_PYTHON_DEV",
		DisplayName: "Python Dev", Description: "Python development tools (linters, formatters, LSP)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "python",
		EnvFile:          "python-dev.env",
		Requires:         []string{"python"},
		VSCodeExtensions: []string{"ms-python.python", "ms-python.vscode-pylance", "charliermarsh.ruff"},
	})

	r.add(&Feature{
		ID: "node", BuildArg: "INCLUDE_NODE",
		DisplayName: "Node.js", Description: "Node.js runtime (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "NODE_VERSION", DefaultVersion: "22",
		EnvFile:      "node.env",
		CacheVolumes: []string{"npm-cache:/cache/npm"},
	})
	r.add(&Feature{
		ID: "node_dev", BuildArg: "INCLUDE_NODE_DEV",
		DisplayName: "Node.js Dev", Description: "Node.js development tools (LSP, debug)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "node",
		EnvFile:          "node.env",
		Requires:         []string{"node"},
		VSCodeExtensions: []string{"dbaeumer.vscode-eslint"},
	})

	r.add(&Feature{
		ID: "rust", BuildArg: "INCLUDE_RUST",
		DisplayName: "Rust", Description: "Rust toolchain (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "RUST_VERSION", DefaultVersion: "1.83",
		EnvFile:      "rust.env",
		CacheVolumes: []string{"cargo-cache:/cache/cargo", "rustup-cache:/cache/rustup"},
	})
	r.add(&Feature{
		ID: "rust_dev", BuildArg: "INCLUDE_RUST_DEV",
		DisplayName: "Rust Dev", Description: "Rust development tools (rust-analyzer, clippy)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "rust",
		EnvFile:          "rust-dev.env",
		Requires:         []string{"rust", "cron"},
		VSCodeExtensions: []string{"rust-lang.rust-analyzer"},
	})

	r.add(&Feature{
		ID: "golang", BuildArg: "INCLUDE_GOLANG",
		DisplayName: "Go", Description: "Go toolchain (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "GO_VERSION", DefaultVersion: "1.23",
		EnvFile:      "golang.env",
		CacheVolumes: []string{"go-cache:/cache/go"},
	})
	r.add(&Feature{
		ID: "golang_dev", BuildArg: "INCLUDE_GOLANG_DEV",
		DisplayName: "Go Dev", Description: "Go development tools (gopls, dlv)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "golang",
		EnvFile:          "golang.env",
		Requires:         []string{"golang"},
		VSCodeExtensions: []string{"golang.go"},
	})

	r.add(&Feature{
		ID: "ruby", BuildArg: "INCLUDE_RUBY",
		DisplayName: "Ruby", Description: "Ruby runtime (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "RUBY_VERSION", DefaultVersion: "3.4",
		EnvFile:      "ruby.env",
		CacheVolumes: []string{"bundle-cache:/cache/bundle"},
	})
	r.add(&Feature{
		ID: "ruby_dev", BuildArg: "INCLUDE_RUBY_DEV",
		DisplayName: "Ruby Dev", Description: "Ruby development tools (solargraph, rubocop)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "ruby",
		EnvFile:          "ruby.env",
		Requires:         []string{"ruby"},
		VSCodeExtensions: []string{"shopify.ruby-lsp"},
	})

	r.add(&Feature{
		ID: "java", BuildArg: "INCLUDE_JAVA",
		DisplayName: "Java", Description: "Java JDK",
		Category: CategoryLanguage, VersionArg: "JAVA_VERSION", DefaultVersion: "21",
		EnvFile: "java.env",
	})
	r.add(&Feature{
		ID: "java_dev", BuildArg: "INCLUDE_JAVA_DEV",
		DisplayName: "Java Dev", Description: "Java development tools (jdtls)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "java",
		EnvFile:          "java.env",
		Requires:         []string{"java"},
		VSCodeExtensions: []string{"redhat.java", "vscjava.vscode-java-debug"},
	})

	r.add(&Feature{
		ID: "r", BuildArg: "INCLUDE_R",
		DisplayName: "R", Description: "R statistical computing (auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "R_VERSION", DefaultVersion: "4.4",
		EnvFile: "r.env",
	})
	r.add(&Feature{
		ID: "r_dev", BuildArg: "INCLUDE_R_DEV",
		DisplayName: "R Dev", Description: "R development tools (languageserver)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "r",
		EnvFile:          "r.env",
		Requires:         []string{"r"},
		VSCodeExtensions: []string{"reditorsupport.r"},
	})

	r.add(&Feature{
		ID: "mojo", BuildArg: "INCLUDE_MOJO",
		DisplayName: "Mojo", Description: "Mojo programming language",
		Category: CategoryLanguage, VersionArg: "MOJO_VERSION", DefaultVersion: "25.4",
		EnvFile: "mojo.env",
	})
	r.add(&Feature{
		ID: "mojo_dev", BuildArg: "INCLUDE_MOJO_DEV",
		DisplayName: "Mojo Dev", Description: "Mojo development tools",
		Category: CategoryLanguage, IsDev: true, BaseLang: "mojo",
		EnvFile:  "mojo.env",
		Requires: []string{"mojo"},
	})

	r.add(&Feature{
		ID: "kotlin", BuildArg: "INCLUDE_KOTLIN",
		DisplayName: "Kotlin", Description: "Kotlin programming language (auto-installs Java, auto-resolves to latest patch)",
		Category: CategoryLanguage, VersionArg: "KOTLIN_VERSION", DefaultVersion: "2.3",
		EnvFile:      "kotlin.env",
		Requires:     []string{"java"},
		CacheVolumes: []string{"kotlin-cache:/cache/kotlin"},
	})
	r.add(&Feature{
		ID: "kotlin_dev", BuildArg: "INCLUDE_KOTLIN_DEV",
		DisplayName: "Kotlin Dev", Description: "Kotlin development tools (kotlin-language-server)",
		Category: CategoryLanguage, IsDev: true, BaseLang: "kotlin",
		EnvFile:          "kotlin.env",
		Requires:         []string{"kotlin", "java"},
		VSCodeExtensions: []string{"fwcd.kotlin"},
	})

	r.add(&Feature{
		ID: "android", BuildArg: "INCLUDE_ANDROID",
		DisplayName: "Android", Description: "Android SDK (auto-installs Java)",
		Category:     CategoryLanguage,
		EnvFile:      "android.env",
		Requires:     []string{"java"},
		CacheVolumes: []string{"android-cache:/cache/android-sdk", "gradle-cache:/cache/gradle"},
	})
	r.add(&Feature{
		ID: "android_dev", BuildArg: "INCLUDE_ANDROID_DEV",
		DisplayName: "Android Dev", Description: "Android emulator and system images",
		Category: CategoryLanguage, IsDev: true, BaseLang: "android",
		EnvFile:  "android.env",
		Requires: []string{"android", "java"},
	})

	// === Tools ===
	r.add(&Feature{
		ID: "dev_tools", BuildArg: "INCLUDE_DEV_TOOLS",
		DisplayName: "Dev Tools", Description: "General development tools (git extras, fzf, Claude Code CLI)",
		Category: CategoryTool,
		EnvFile:  "dev-tools.env",
		Requires: []string{"bindfs"},
		VSCodeExtensions: []string{
			"Anthropic.claude-code",
			"streetsidesoftware.code-spell-checker",
			"usernamehw.errorlens",
			"wayou.vscode-todo-highlight",
		},
	})
	r.add(&Feature{
		ID: "docker", BuildArg: "INCLUDE_DOCKER",
		DisplayName: "Docker", Description: "Docker CLI tools",
		Category:         CategoryTool,
		EnvFile:          "docker.env",
		VSCodeExtensions: []string{"ms-azuretools.vscode-docker"},
	})
	r.add(&Feature{
		ID: "op", BuildArg: "INCLUDE_OP",
		DisplayName: "1Password CLI", Description: "1Password CLI for secrets management",
		Category: CategoryTool,
		EnvFile:  "op-cli.env",
	})
	r.add(&Feature{
		ID: "cron", BuildArg: "INCLUDE_CRON",
		DisplayName: "Cron", Description: "Cron daemon (auto-enabled by rust_dev, dev_tools, bindfs)",
		Category:  CategoryTool,
		EnvFile:   "cron.env",
		ImpliedBy: []string{"rust_dev", "dev_tools", "bindfs"},
	})
	r.add(&Feature{
		ID: "bindfs", BuildArg: "INCLUDE_BINDFS",
		DisplayName: "Bindfs", Description: "FUSE permission overlay for macOS VirtioFS",
		Category:  CategoryTool,
		Requires:  []string{"cron"},
		ImpliedBy: []string{"dev_tools"},
	})
	r.add(&Feature{
		ID: "ollama", BuildArg: "INCLUDE_OLLAMA",
		DisplayName: "Ollama", Description: "Local LLM runtime",
		Category:     CategoryAI,
		EnvFile:      "ollama.env",
		CacheVolumes: []string{"ollama-cache:/cache/ollama"},
	})

	// === Cloud & Infrastructure ===
	r.add(&Feature{
		ID: "kubernetes", BuildArg: "INCLUDE_KUBERNETES",
		DisplayName: "Kubernetes", Description: "kubectl, k9s, Helm",
		Category: CategoryCloud,
		EnvFile:  "kubernetes.env",
	})
	r.add(&Feature{
		ID: "terraform", BuildArg: "INCLUDE_TERRAFORM",
		DisplayName: "Terraform", Description: "Terraform and related tools",
		Category:         CategoryCloud,
		EnvFile:          "terraform.env",
		VSCodeExtensions: []string{"hashicorp.terraform"},
	})
	r.add(&Feature{
		ID: "aws", BuildArg: "INCLUDE_AWS",
		DisplayName: "AWS CLI", Description: "AWS command-line interface",
		Category: CategoryCloud,
		EnvFile:  "aws.env",
	})
	r.add(&Feature{
		ID: "gcloud", BuildArg: "INCLUDE_GCLOUD",
		DisplayName: "Google Cloud SDK", Description: "Google Cloud command-line tools",
		Category: CategoryCloud,
		EnvFile:  "gcloud.env",
	})
	r.add(&Feature{
		ID: "cloudflare", BuildArg: "INCLUDE_CLOUDFLARE",
		DisplayName: "Cloudflare", Description: "Cloudflare Wrangler (requires Node.js)",
		Category: CategoryCloud,
		EnvFile:  "cloudflare.env",
		Requires: []string{"node"},
	})

	// === Database Clients ===
	r.add(&Feature{
		ID: "postgres_client", BuildArg: "INCLUDE_POSTGRES_CLIENT",
		DisplayName: "PostgreSQL Client", Description: "PostgreSQL client tools (psql)",
		Category: CategoryDatabase,
		EnvFile:  "database-clients.env",
	})
	r.add(&Feature{
		ID: "redis_client", BuildArg: "INCLUDE_REDIS_CLIENT",
		DisplayName: "Redis Client", Description: "Redis client tools (redis-cli)",
		Category: CategoryDatabase,
		EnvFile:  "database-clients.env",
	})
	r.add(&Feature{
		ID: "sqlite_client", BuildArg: "INCLUDE_SQLITE_CLIENT",
		DisplayName: "SQLite Client", Description: "SQLite client tools",
		Category: CategoryDatabase,
		EnvFile:  "database-clients.env",
	})

	return r
}

func (r *Registry) add(f *Feature) {
	r.features[f.ID] = f
	r.order = append(r.order, f.ID)
}

// Get returns a feature by ID, or nil if not found.
func (r *Registry) Get(id string) *Feature {
	return r.features[id]
}

// All returns all features in registration order.
func (r *Registry) All() []*Feature {
	result := make([]*Feature, 0, len(r.order))
	for _, id := range r.order {
		result = append(result, r.features[id])
	}
	return result
}

// ByCategory returns features matching the given category.
func (r *Registry) ByCategory(cat Category) []*Feature {
	var result []*Feature
	for _, id := range r.order {
		if r.features[id].Category == cat {
			result = append(result, r.features[id])
		}
	}
	return result
}

// Languages returns non-dev language features for the wizard language step.
func (r *Registry) Languages() []*Feature {
	var result []*Feature
	for _, f := range r.ByCategory(CategoryLanguage) {
		if !f.IsDev {
			result = append(result, f)
		}
	}
	return result
}
