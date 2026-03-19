package template

import (
	"strings"
	"text/template"

	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

// BuildArgGroup represents a category of build args with a label header.
type BuildArgGroup struct {
	Label string          // "Languages", "Tools", etc.
	Args  []BuildArgEntry // ordered entries within the group
}

// BuildArgEntry is a single build arg line with an optional inline comment.
type BuildArgEntry struct {
	Line    string // e.g. "INCLUDE_PYTHON_DEV=true"
	Comment string // e.g. "includes Python runtime" (empty if none)
}

// categoryLabel maps feature categories to display labels.
var categoryLabel = map[feature.Category]string{
	feature.CategoryLanguage: "Languages",
	feature.CategoryTool:     "Tools",
	feature.CategoryAI:       "AI/ML",
	feature.CategoryCloud:    "Cloud",
	feature.CategoryDatabase: "Database",
}

// categoryOrder defines the rendering order for categories.
var categoryOrder = []feature.Category{
	feature.CategoryLanguage,
	feature.CategoryTool,
	feature.CategoryAI,
	feature.CategoryCloud,
	feature.CategoryDatabase,
}

// groupedBuildArgs groups enabled features by category, collapses base+dev
// pairs (emitting only the dev line with an annotation), and attaches version
// args after the corresponding feature entry.
func groupedBuildArgs(ctx *RenderContext) []BuildArgGroup {
	// Build a set of enabled feature IDs for quick lookup.
	enabledIDs := make(map[string]bool, len(ctx.EnabledFeatures))
	for _, f := range ctx.EnabledFeatures {
		enabledIDs[f.ID] = true
	}

	// Bucket features by category, preserving registry order.
	buckets := make(map[feature.Category][]*feature.Feature)
	for _, f := range ctx.EnabledFeatures {
		buckets[f.Category] = append(buckets[f.Category], f)
	}

	var groups []BuildArgGroup
	for _, cat := range categoryOrder {
		features := buckets[cat]
		if len(features) == 0 {
			continue
		}

		var entries []BuildArgEntry
		// Track base features that are suppressed because their dev counterpart is present.
		suppressed := make(map[string]bool)
		for _, f := range features {
			if f.IsDev && f.BaseLang != "" && enabledIDs[f.BaseLang] {
				suppressed[f.BaseLang] = true
			}
		}

		for _, f := range features {
			// Skip base feature if its dev counterpart is also enabled.
			if suppressed[f.ID] {
				continue
			}

			entry := BuildArgEntry{Line: f.BuildArg + "=true"}
			if f.IsDev && f.BaseLang != "" {
				// Look up the base feature's display name for the comment.
				for _, base := range features {
					if base.ID == f.BaseLang {
						entry.Comment = "includes " + base.DisplayName + " runtime"
						break
					}
				}
			}
			entries = append(entries, entry)

			// Attach version arg: for dev features, use the base feature's version.
			versionFeature := f
			if f.IsDev && f.BaseLang != "" {
				for _, base := range features {
					if base.ID == f.BaseLang {
						versionFeature = base
						break
					}
				}
			}
			if versionFeature.VersionArg != "" {
				ver := ctx.Versions[versionFeature.VersionArg]
				if ver != "" {
					entries = append(entries, BuildArgEntry{
						Line: versionFeature.VersionArg + "=" + ver,
					})
				}
			}
		}

		if len(entries) > 0 {
			groups = append(groups, BuildArgGroup{
				Label: categoryLabel[cat],
				Args:  entries,
			})
		}
	}

	return groups
}

func funcMap() template.FuncMap {
	return template.FuncMap{
		"hasFeature": func(ctx *RenderContext, id string) bool {
			return ctx.Selection.Has(id)
		},
		"indent": func(n int, s string) string {
			pad := strings.Repeat(" ", n)
			lines := strings.Split(s, "\n")
			for i, line := range lines {
				if line != "" {
					lines[i] = pad + line
				}
			}
			return strings.Join(lines, "\n")
		},
		"joinComma": func(items []string) string {
			return strings.Join(items, ", ")
		},
		"buildArgLines": func(ctx *RenderContext) string {
			var lines []string
			for _, f := range ctx.EnabledFeatures {
				lines = append(lines, "- "+f.BuildArg+"=true")
				if f.VersionArg != "" {
					ver := ctx.Versions[f.VersionArg]
					if ver == "" {
						ver = f.DefaultVersion
					}
					lines = append(lines, "- "+f.VersionArg+"="+ver)
				}
			}
			return strings.Join(lines, "\n")
		},
		"groupedBuildArgs": func(ctx *RenderContext) []BuildArgGroup {
			return groupedBuildArgs(ctx)
		},
		"add": func(a, b int) int {
			return a + b
		},
		"sub": func(a, b int) int {
			return a - b
		},
		"contains": func(s, substr string) bool {
			return strings.Contains(s, substr)
		},
		"split": func(s, sep string) []string {
			return strings.Split(s, sep)
		},
	}
}
