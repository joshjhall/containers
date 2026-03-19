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
	addDev    bool
	addDryRun bool
)

var addCmd = &cobra.Command{
	Use:   "add <feature> [<feature>...]",
	Short: "Add features to the current devcontainer configuration",
	Long: `Add one or more features to .igor.yml, resolve dependencies,
and re-render the generated devcontainer files.

Files that have been modified by the user are skipped (same as 'igor update').`,
	Args: cobra.MinimumNArgs(1),
	RunE: runAdd,
}

func init() {
	addCmd.Flags().BoolVar(&addDev, "dev", false, "also add the _dev companion feature")
	addCmd.Flags().BoolVar(&addDryRun, "dry-run", false, "show what would change without writing")
	rootCmd.AddCommand(addCmd)
}

func runAdd(cmd *cobra.Command, args []string) error {
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

	// 2. Build old explicit set for comparison
	oldExplicit := make(map[string]bool)
	for _, f := range cfg.Features {
		oldExplicit[f] = true
	}
	oldSel := feature.Resolve(oldExplicit, reg)

	// 3. Validate args and build new explicit set
	newExplicit := make(map[string]bool)
	for id := range oldExplicit {
		newExplicit[id] = true
	}

	for _, id := range args {
		if reg.Get(id) == nil {
			return fmt.Errorf("unknown feature %q; run 'igor features' to list available features", id)
		}
		if newExplicit[id] {
			fmt.Fprintf(w, "%s is already enabled\n", id)
		} else {
			newExplicit[id] = true
		}
		if addDev {
			devID := id + "_dev"
			if reg.Get(devID) == nil {
				return fmt.Errorf("no dev companion %q exists for feature %q", devID, id)
			}
			if newExplicit[devID] {
				fmt.Fprintf(w, "%s is already enabled\n", devID)
			} else {
				newExplicit[devID] = true
			}
		}
	}

	// 4. Resolve dependencies
	sel := feature.Resolve(newExplicit, reg)

	// 5. Identify what's new
	addedExplicit := make([]string, 0)
	for id := range newExplicit {
		if !oldExplicit[id] {
			addedExplicit = append(addedExplicit, id)
		}
	}
	sort.Strings(addedExplicit)

	addedAuto := make([]string, 0)
	for id := range sel.Auto {
		if !oldSel.Has(id) {
			addedAuto = append(addedAuto, id)
		}
	}
	sort.Strings(addedAuto)

	if len(addedExplicit) == 0 {
		fmt.Fprintln(w, "Nothing to add.")
		return nil
	}

	// 6. Dry-run path
	if addDryRun {
		fmt.Fprintf(w, "Would add: %s\n", strings.Join(addedExplicit, ", "))
		if len(addedAuto) > 0 {
			fmt.Fprintf(w, "Would auto-resolve: %s\n", strings.Join(addedAuto, ", "))
		}
		return nil
	}

	// 7. Fill default versions for newly added features
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

	// 8. Build render context
	containersDir := cfg.ContainersDir
	if containersDir == "" {
		containersDir = "containers"
	}
	ctx := igortemplate.NewRenderContext(cfg.Project, containersDir, sel, reg, versions, cfg.Agents)

	// 9. Render templates
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

	// 10. Classify each file and build write list
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

	// 11. Write files
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

	// 12. Hash igor.yml template output for tracking
	igorYMLContent, err := renderer.Render("igor.yml.tmpl", ctx)
	if err != nil {
		return fmt.Errorf("rendering igor.yml.tmpl: %w", err)
	}
	newHashes[".igor.yml"] = generate.HashContent(igorYMLContent)

	// 13. Detect containers ref
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

	// 14. Build sorted feature list and save
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

	// 15. Print summary
	filesUpdated := 0
	for _, s := range statuses {
		if s.Action != "unchanged" {
			filesUpdated++
		}
	}

	fmt.Fprintf(w, "Adding %s...\n", strings.Join(addedExplicit, ", "))
	if len(addedAuto) > 0 {
		fmt.Fprintf(w, "  Auto-resolved: %s\n", strings.Join(addedAuto, ", "))
	} else {
		fmt.Fprintf(w, "  Auto-resolved: (none)\n")
	}
	fmt.Fprintf(w, "  Files updated: %d\n", filesUpdated)

	for _, s := range statuses {
		if s.Action == "skipped" {
			fmt.Fprintf(w, "  ~ skipped: %s (user-modified, use 'igor update --force')\n", s.Path)
		}
	}

	return nil
}
