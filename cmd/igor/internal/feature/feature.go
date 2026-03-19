package feature

// Category groups features in the wizard UI.
type Category string

const (
	CategoryLanguage Category = "language"
	CategoryCloud    Category = "cloud"
	CategoryTool     Category = "tool"
	CategoryDatabase Category = "database"
	CategoryAI       Category = "ai"
)

// Feature describes a single toggleable container feature.
type Feature struct {
	// ID is the canonical lowercase identifier (e.g. "python", "python_dev").
	ID string

	// BuildArg is the Docker build argument name (e.g. "INCLUDE_PYTHON").
	BuildArg string

	// DisplayName is the human-readable name shown in the wizard.
	DisplayName string

	// Description is a short description for the wizard.
	Description string

	// Category groups the feature in wizard steps.
	Category Category

	// VersionArg is the build arg for version selection (e.g. "PYTHON_VERSION"), empty if none.
	VersionArg string

	// DefaultVersion is the default version from the schema.
	DefaultVersion string

	// EnvFile is the env example filename under examples/env/ (e.g. "python.env").
	EnvFile string

	// Requires lists feature IDs that this feature depends on.
	Requires []string

	// ImpliedBy lists feature IDs that auto-enable this feature.
	ImpliedBy []string

	// IsDev indicates this is a *_DEV companion feature.
	IsDev bool

	// BaseLang links a *_DEV feature to its base language feature ID.
	BaseLang string

	// CacheVolumes lists named Docker volumes for caching (e.g. "pip-cache:/cache/pip").
	CacheVolumes []string

	// VSCodeExtensions lists VS Code extension IDs to recommend.
	VSCodeExtensions []string
}

// Selection tracks which features the user explicitly chose vs auto-resolved.
type Selection struct {
	// Explicit features the user selected.
	Explicit map[string]bool

	// Auto features added by dependency resolution.
	Auto map[string]bool
}

// All returns a combined set of all selected feature IDs.
func (s *Selection) All() map[string]bool {
	all := make(map[string]bool, len(s.Explicit)+len(s.Auto))
	for id := range s.Explicit {
		all[id] = true
	}
	for id := range s.Auto {
		all[id] = true
	}
	return all
}

// Has returns true if the feature is in the selection (explicit or auto).
func (s *Selection) Has(id string) bool {
	return s.Explicit[id] || s.Auto[id]
}
