package cmd

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
	"github.com/joshjhall/containers/cmd/igor/internal/generate"
	igortemplate "github.com/joshjhall/containers/cmd/igor/internal/template"
)

var forceUpdate bool

var updateCmd = &cobra.Command{
	Use:   "update",
	Short: "Re-generate devcontainer files from .igor.yml after a containers submodule update",
	Long: `Re-renders all generated files using the current templates and the
selections stored in .igor.yml. Files that have been modified by the user
are skipped unless --force is specified.

Run this after updating the containers submodule to pick up template changes.`,
	RunE: runUpdate,
}

func init() {
	updateCmd.Flags().BoolVar(&forceUpdate, "force", false, "overwrite user-modified files")
	rootCmd.AddCommand(updateCmd)
}

type fileStatus struct {
	Path   string
	Action string // "created", "updated", "unchanged", "skipped", "forced"
}

// classifyFile determines what action to take for a generated file.
// It returns the action label and whether the file should be written.
func classifyFile(path, newContent string, oldHashes map[string]string, force bool) (action string, shouldWrite bool) {
	newHash := generate.HashContent(newContent)
	oldHash, hasOldHash := oldHashes[path]

	// Read the file currently on disk
	diskData, err := os.ReadFile(path)
	if err != nil {
		// File doesn't exist on disk → create it
		return "created", true
	}
	diskHash := fmt.Sprintf("%x", sha256.Sum256(diskData))

	// No old hash → conservative: treat as user-modified
	if !hasOldHash {
		if force {
			return "forced", true
		}
		return "skipped", false
	}

	// Disk matches new content → nothing to do
	if diskHash == newHash {
		return "unchanged", false
	}

	// Disk matches old hash → safe to update (user hasn't touched it)
	if diskHash == oldHash {
		return "updated", true
	}

	// Disk differs from old hash → user modified the file
	if force {
		return "forced", true
	}
	return "skipped", false
}

func runUpdate(cmd *cobra.Command, args []string) error {
	// 1. Load existing config
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	oldRef := cfg.ContainersRef
	oldHashes := cfg.Generated
	if oldHashes == nil {
		oldHashes = make(map[string]string)
	}

	// 2. Detect containers version
	containersDir := cfg.ContainersDir
	if containersDir == "" {
		containersDir = "containers"
	}

	newRef := ""
	versionFile := filepath.Join(containersDir, "VERSION")
	if data, err := os.ReadFile(versionFile); err == nil {
		newRef = strings.TrimSpace(string(data))
	}
	if newRef == "" {
		newRef = detectContainersVersion()
	}

	// 3. Resolve features
	reg := feature.NewRegistry()
	explicit := make(map[string]bool)
	for _, f := range cfg.Features {
		explicit[f] = true
	}
	sel := feature.Resolve(explicit, reg)

	// 4. Fill default versions
	versions := cfg.Versions
	if versions == nil {
		versions = make(map[string]string)
	}
	for _, f := range reg.All() {
		if sel.Has(f.ID) && f.VersionArg != "" {
			if _, ok := versions[f.VersionArg]; !ok {
				versions[f.VersionArg] = f.DefaultVersion
			}
		}
	}

	// 5. Build render context
	ctx := igortemplate.NewRenderContext(cfg.Project, containersDir, sel, reg, versions)

	// 6. Render templates
	renderer, err := igortemplate.NewRenderer()
	if err != nil {
		return fmt.Errorf("initializing templates: %w", err)
	}

	type fileSpec struct {
		path     string
		template string
	}

	files := []fileSpec{
		{".devcontainer/docker-compose.yml", "docker-compose.yml.tmpl"},
		{".devcontainer/devcontainer.json", "devcontainer.json.tmpl"},
		{".devcontainer/.env", "env.tmpl"},
		{".env.example", "env-example.tmpl"},
	}

	// 7. Classify each file and build write list
	var statuses []fileStatus
	var toWrite []generate.FileEntry
	newHashes := make(map[string]string)

	for _, f := range files {
		content, err := renderer.Render(f.template, ctx)
		if err != nil {
			return fmt.Errorf("rendering %s: %w", f.template, err)
		}

		action, shouldWrite := classifyFile(f.path, content, oldHashes, forceUpdate)
		statuses = append(statuses, fileStatus{Path: f.path, Action: action})

		if shouldWrite {
			toWrite = append(toWrite, generate.FileEntry{
				Path:         f.path,
				TemplateName: f.template,
				Content:      content,
			})
		} else if action == "skipped" {
			// 8. Preserve old hash for skipped files
			if h, ok := oldHashes[f.path]; ok {
				newHashes[f.path] = h
			}
		}
	}

	// 9. Write files
	writtenHashes, err := generate.WriteFiles(toWrite)
	if err != nil {
		return fmt.Errorf("writing files: %w", err)
	}
	for path, hash := range writtenHashes {
		newHashes[path] = hash
	}

	// For unchanged files, use the new content hash (same as old)
	for _, s := range statuses {
		if s.Action == "unchanged" {
			if _, ok := newHashes[s.Path]; !ok {
				// Find the rendered content for this file
				for _, f := range files {
					if f.path == s.Path {
						content, _ := renderer.Render(f.template, ctx)
						newHashes[s.Path] = generate.HashContent(content)
						break
					}
				}
			}
		}
	}

	// 10. Render igor.yml template for hash tracking
	igorYMLContent, err := renderer.Render("igor.yml.tmpl", ctx)
	if err != nil {
		return fmt.Errorf("rendering igor.yml.tmpl: %w", err)
	}

	// 11. Hash the template output for .igor.yml tracking
	newHashes[".igor.yml"] = generate.HashContent(igorYMLContent)

	// 12. Build updated config preserving original features/project/versions
	state := &igorconfig.IgorConfig{
		SchemaVersion: cfg.SchemaVersion,
		ContainersRef: newRef,
		ContainersDir: containersDir,
		Project:       cfg.Project,
		Features:      cfg.Features,
		Versions:      versions,
		Generated:     newHashes,
	}

	// 13. Save state
	if err := state.Save(".igor.yml"); err != nil {
		return fmt.Errorf("saving .igor.yml: %w", err)
	}

	// 14. Print summary
	newFeatures := detectNewFeatures(reg, sel)
	printUpdateSummary(oldRef, newRef, statuses, newFeatures)

	return nil
}

func printUpdateSummary(oldRef, newRef string, statuses []fileStatus, newFeatures []string) {
	// Version line
	if oldRef != "" || newRef != "" {
		if oldRef != "" && newRef != "" && oldRef != newRef {
			fmt.Printf("containers: %s → %s\n", oldRef, newRef)
		} else if newRef != "" {
			fmt.Printf("containers: %s\n", newRef)
		}
	}

	// Check if anything changed
	hasChanges := false
	for _, s := range statuses {
		if s.Action != "unchanged" {
			hasChanges = true
			break
		}
	}

	if !hasChanges {
		fmt.Println("All files up to date.")
		return
	}

	fmt.Println("\nFiles:")
	for _, s := range statuses {
		switch s.Action {
		case "created":
			fmt.Printf("  + created:   %s\n", s.Path)
		case "updated":
			fmt.Printf("  ✓ updated:   %s\n", s.Path)
		case "unchanged":
			fmt.Printf("  - unchanged: %s\n", s.Path)
		case "skipped":
			fmt.Printf("  ~ skipped:   %s (user-modified, use --force to overwrite)\n", s.Path)
		case "forced":
			fmt.Printf("  ! forced:    %s\n", s.Path)
		}
	}

	if len(newFeatures) > 0 {
		fmt.Printf("\nNew features available:\n")
		fmt.Printf("  + %s (run 'igor init' to reconfigure)\n", strings.Join(newFeatures, ", "))
	}
}

// detectNewFeatures returns feature IDs from the registry that are not in the
// current selection, excluding internal/auto-implied features.
func detectNewFeatures(reg *feature.Registry, sel *feature.Selection) []string {
	allSelected := sel.All()
	internalFeatures := map[string]bool{
		"cron":   true,
		"bindfs": true,
	}

	var newFeats []string
	for _, f := range reg.All() {
		if !allSelected[f.ID] && !internalFeatures[f.ID] && !f.IsDev {
			newFeats = append(newFeats, f.ID)
		}
	}
	sort.Strings(newFeats)
	return newFeats
}
