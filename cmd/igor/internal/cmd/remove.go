package cmd

import (
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

var (
	removeCascade bool
	removeDevOnly bool
	removeDryRun  bool
)

var removeCmd = &cobra.Command{
	Use:   "remove <feature> [<feature>...]",
	Short: "Remove features from the current devcontainer configuration",
	Long: `Remove one or more features from .igor.yml, check dependencies,
and re-render the generated devcontainer files.

Files that have been modified by the user are skipped (same as 'igor update').`,
	Args: cobra.MinimumNArgs(1),
	RunE: runRemove,
}

func init() {
	removeCmd.Flags().BoolVar(&removeCascade, "cascade", false, "also remove features that depend on the target")
	removeCmd.Flags().BoolVar(&removeDevOnly, "dev-only", false, "only remove the _dev companion, keep the runtime feature")
	removeCmd.Flags().BoolVar(&removeDryRun, "dry-run", false, "show what would change without writing")
	rootCmd.AddCommand(removeCmd)
}

// dependentsOf returns explicit features that transitively require targetID.
func dependentsOf(targetID string, explicit map[string]bool, reg *feature.Registry) []string {
	var deps []string
	for id := range explicit {
		if id == targetID {
			continue
		}
		if requiresTransitive(id, targetID, reg, make(map[string]bool)) {
			deps = append(deps, id)
		}
	}
	sort.Strings(deps)
	return deps
}

// requiresTransitive checks if featureID transitively requires targetID.
func requiresTransitive(featureID, targetID string, reg *feature.Registry, visited map[string]bool) bool {
	if visited[featureID] {
		return false
	}
	visited[featureID] = true

	f := reg.Get(featureID)
	if f == nil {
		return false
	}
	for _, req := range f.Requires {
		if req == targetID {
			return true
		}
		if requiresTransitive(req, targetID, reg, visited) {
			return true
		}
	}
	return false
}

func runRemove(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	// 1. Load existing config
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	reg := feature.NewRegistry()

	// 2. Build old explicit set
	oldExplicit := make(map[string]bool)
	for _, f := range cfg.Features {
		oldExplicit[f] = true
	}
	oldSel := feature.Resolve(oldExplicit, reg)

	// 3. Validate args and build removal set
	removalSet := make(map[string]bool)
	for _, id := range args {
		if reg.Get(id) == nil {
			return fmt.Errorf("unknown feature %q; run 'igor features' to list available features", id)
		}

		if removeDevOnly {
			devID := id + "_dev"
			if reg.Get(devID) == nil {
				return fmt.Errorf("no dev companion %q exists for feature %q", devID, id)
			}
			if !oldExplicit[devID] {
				return fmt.Errorf("feature %q is not currently enabled", devID)
			}
			removalSet[devID] = true
		} else {
			if !oldExplicit[id] && !oldSel.Has(id) {
				return fmt.Errorf("feature %q is not currently enabled", id)
			}
			if !oldExplicit[id] {
				return fmt.Errorf("feature %q is auto-resolved, not explicitly enabled; remove the feature that depends on it instead", id)
			}
			removalSet[id] = true
		}
	}

	// 4. Dependency check: for each feature being removed, find dependents
	// Build prospective explicit set without the removal set
	prospective := make(map[string]bool)
	for id := range oldExplicit {
		if !removalSet[id] {
			prospective[id] = true
		}
	}

	for id := range removalSet {
		deps := dependentsOf(id, prospective, reg)
		if len(deps) > 0 {
			if removeCascade {
				for _, dep := range deps {
					removalSet[dep] = true
					delete(prospective, dep)
				}
			} else {
				return fmt.Errorf("cannot remove %q: required by %s (use --cascade to remove them too)", id, strings.Join(deps, ", "))
			}
		}
	}

	// 5. Build new explicit set
	newExplicit := make(map[string]bool)
	for id := range oldExplicit {
		if !removalSet[id] {
			newExplicit[id] = true
		}
	}

	// 6. Resolve dependencies on new set
	newSel := feature.Resolve(newExplicit, reg)

	// 7. Identify removed explicit and dropped auto-deps
	removedExplicit := make([]string, 0)
	for id := range removalSet {
		if oldExplicit[id] {
			removedExplicit = append(removedExplicit, id)
		}
	}
	sort.Strings(removedExplicit)

	droppedAuto := make([]string, 0)
	for id := range oldSel.Auto {
		if !newSel.Has(id) {
			droppedAuto = append(droppedAuto, id)
		}
	}
	sort.Strings(droppedAuto)

	// 8. Dry-run path
	if removeDryRun {
		fmt.Fprintf(w, "Would remove: %s\n", strings.Join(removedExplicit, ", "))
		if len(droppedAuto) > 0 {
			fmt.Fprintf(w, "Would drop auto-resolved: %s\n", strings.Join(droppedAuto, ", "))
		}
		return nil
	}

	// 9. Clean up versions: remove entries for features no longer in selection
	versions := cfg.Versions
	if versions == nil {
		versions = make(map[string]string)
	}
	for _, f := range reg.All() {
		if f.VersionArg != "" && !newSel.Has(f.ID) {
			delete(versions, f.VersionArg)
		}
	}

	// 10. Build render context
	containersDir := cfg.ContainersDir
	if containersDir == "" {
		containersDir = "containers"
	}
	ctx := igortemplate.NewRenderContext(cfg.Project, containersDir, newSel, reg, versions)

	// 11. Render templates
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

	oldHashes := cfg.Generated
	if oldHashes == nil {
		oldHashes = make(map[string]string)
	}

	// 12. Classify each file and build write list
	var statuses []fileStatus
	var toWrite []generate.FileEntry
	newHashes := make(map[string]string)

	for _, f := range files {
		content, err := renderer.Render(f.template, ctx)
		if err != nil {
			return fmt.Errorf("rendering %s: %w", f.template, err)
		}

		action, shouldWrite := classifyFile(f.path, content, oldHashes, false)
		statuses = append(statuses, fileStatus{Path: f.path, Action: action})

		if shouldWrite {
			toWrite = append(toWrite, generate.FileEntry{
				Path:         f.path,
				TemplateName: f.template,
				Content:      content,
			})
		} else if action == "skipped" {
			if h, ok := oldHashes[f.path]; ok {
				newHashes[f.path] = h
			}
		}
	}

	// 13. Write files
	writtenHashes, err := generate.WriteFiles(toWrite)
	if err != nil {
		return fmt.Errorf("writing files: %w", err)
	}
	for path, hash := range writtenHashes {
		newHashes[path] = hash
	}

	// For unchanged files, compute hash from rendered content
	for _, s := range statuses {
		if s.Action == "unchanged" {
			if _, ok := newHashes[s.Path]; !ok {
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

	// 14. Hash igor.yml template output for tracking
	igorYMLContent, err := renderer.Render("igor.yml.tmpl", ctx)
	if err != nil {
		return fmt.Errorf("rendering igor.yml.tmpl: %w", err)
	}
	newHashes[".igor.yml"] = generate.HashContent(igorYMLContent)

	// 15. Detect containers ref
	newRef := cfg.ContainersRef
	if newRef == "" {
		versionFile := filepath.Join(containersDir, "VERSION")
		if data, err := os.ReadFile(versionFile); err == nil {
			newRef = strings.TrimSpace(string(data))
		}
		if newRef == "" {
			newRef = detectContainersVersion()
		}
	}

	// 16. Build sorted feature list and save
	featureList := make([]string, 0, len(newExplicit))
	for id := range newExplicit {
		featureList = append(featureList, id)
	}
	sort.Strings(featureList)

	state := &igorconfig.IgorConfig{
		SchemaVersion: cfg.SchemaVersion,
		ContainersRef: newRef,
		ContainersDir: containersDir,
		Project:       cfg.Project,
		Features:      featureList,
		Versions:      versions,
		Generated:     newHashes,
	}

	if err := state.Save(".igor.yml"); err != nil {
		return fmt.Errorf("saving .igor.yml: %w", err)
	}

	// 17. Print summary
	filesUpdated := 0
	for _, s := range statuses {
		if s.Action != "unchanged" {
			filesUpdated++
		}
	}

	fmt.Fprintf(w, "Removing %s...\n", strings.Join(removedExplicit, ", "))
	if len(droppedAuto) > 0 {
		fmt.Fprintf(w, "  Dropped auto-resolved: %s\n", strings.Join(droppedAuto, ", "))
	}
	fmt.Fprintf(w, "  Files updated: %d\n", filesUpdated)

	for _, s := range statuses {
		if s.Action == "skipped" {
			fmt.Fprintf(w, "  ~ skipped: %s (user-modified, use 'igor update --force')\n", s.Path)
		}
	}

	return nil
}
