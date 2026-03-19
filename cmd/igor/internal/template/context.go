package template

import (
	"sort"

	"github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

// RenderContext assembles all data needed to render templates.
type RenderContext struct {
	// Project configuration.
	Project config.ProjectConfig

	// ContainersDir relative path.
	ContainersDir string

	// Selection tracks explicit vs auto-resolved features.
	Selection *feature.Selection

	// EnabledFeatures in deterministic order (for build args).
	EnabledFeatures []*feature.Feature

	// Versions maps version arg name to chosen version.
	Versions map[string]string

	// CacheVolumes is the deduplicated list of cache volume specs.
	CacheVolumes []string

	// VSCodeExtensions is the deduplicated list of extension IDs.
	VSCodeExtensions []string

	// NeedsBindfs is true when bindfs is selected (needs cap_add + device).
	NeedsBindfs bool

	// NeedsDocker is true when docker feature is selected.
	NeedsDocker bool

	// Agents holds optional agent/worktree settings.
	Agents config.AgentConfig
}

// HasAgents returns true when agents config has been explicitly set.
func (rc *RenderContext) HasAgents() bool {
	return !rc.Agents.IsZero()
}

// NewRenderContext builds a RenderContext from resolved selection and config.
func NewRenderContext(
	proj config.ProjectConfig,
	containersDir string,
	sel *feature.Selection,
	reg *feature.Registry,
	versions map[string]string,
	agents config.AgentConfig,
) *RenderContext {
	ctx := &RenderContext{
		Project:       proj,
		ContainersDir: containersDir,
		Selection:     sel,
		Versions:      versions,
		NeedsBindfs:   sel.Has("bindfs"),
		NeedsDocker:   sel.Has("docker"),
		Agents:        agents,
	}

	// Collect enabled features in registry order.
	allIDs := sel.All()
	for _, f := range reg.All() {
		if allIDs[f.ID] {
			ctx.EnabledFeatures = append(ctx.EnabledFeatures, f)
		}
	}

	// Collect cache volumes (deduplicated).
	volSet := make(map[string]bool)
	for _, f := range ctx.EnabledFeatures {
		for _, v := range f.CacheVolumes {
			if !volSet[v] {
				volSet[v] = true
				ctx.CacheVolumes = append(ctx.CacheVolumes, v)
			}
		}
	}

	// Auto-derive agent shared volumes from enabled features when not explicitly set.
	if !agents.IsZero() && len(agents.SharedVolumes) == 0 && len(ctx.CacheVolumes) > 0 {
		ctx.Agents.SharedVolumes = make([]string, len(ctx.CacheVolumes))
		copy(ctx.Agents.SharedVolumes, ctx.CacheVolumes)
	}

	// Collect VS Code extensions (deduplicated, sorted).
	extSet := make(map[string]bool)
	for _, f := range ctx.EnabledFeatures {
		for _, e := range f.VSCodeExtensions {
			extSet[e] = true
		}
	}
	for e := range extSet {
		ctx.VSCodeExtensions = append(ctx.VSCodeExtensions, e)
	}
	sort.Strings(ctx.VSCodeExtensions)

	return ctx
}
