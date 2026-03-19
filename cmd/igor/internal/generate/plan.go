package generate

import (
	"os"
)

// FileEntry describes a file to be generated.
type FileEntry struct {
	// Path is the relative path from project root.
	Path string

	// TemplateName is the embedded template filename.
	TemplateName string

	// Content is the rendered content to write.
	Content string
}

// GenerationPlan groups files into creates and skips based on existing files.
type GenerationPlan struct {
	Creates []FileEntry
	Skips   []FileEntry
}

// NewPlan checks which files already exist and groups them.
func NewPlan(entries []FileEntry) *GenerationPlan {
	plan := &GenerationPlan{}
	for _, e := range entries {
		if _, err := os.Stat(e.Path); err == nil {
			plan.Skips = append(plan.Skips, e)
		} else {
			plan.Creates = append(plan.Creates, e)
		}
	}
	return plan
}
