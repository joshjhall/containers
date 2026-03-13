package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
	"github.com/joshjhall/containers/cmd/igor/internal/generate"
	igortemplate "github.com/joshjhall/containers/cmd/igor/internal/template"
	"github.com/joshjhall/containers/cmd/igor/internal/wizard"
)

var initCmd = &cobra.Command{
	Use:   "init",
	Short: "Initialize devcontainer configuration with an interactive wizard",
	Long: `Run an interactive wizard to select languages, tools, and cloud providers,
then generate .devcontainer/ configuration files.

Generated files:
  .devcontainer/docker-compose.yml  Build definition with selected features
  .devcontainer/devcontainer.json   VS Code devcontainer config
  .devcontainer/.env                Runtime environment variables
  .env.example                      Documented env template
  .igor.yml                         State file tracking selections`,
	RunE: runInit,
}

func init() {
	rootCmd.AddCommand(initCmd)
}

func runInit(cmd *cobra.Command, args []string) error {
	reg := feature.NewRegistry()

	// Detect defaults
	defaults := detectDefaults()

	var sel *feature.Selection
	var proj igorconfig.ProjectConfig
	var containersDir string
	var versions map[string]string

	if nonInteractive {
		// Load from config file
		if configFile == "" {
			return fmt.Errorf("--config is required with --non-interactive")
		}
		cfg, err := igorconfig.Load(configFile)
		if err != nil {
			return fmt.Errorf("loading config: %w", err)
		}

		explicit := make(map[string]bool)
		for _, f := range cfg.Features {
			explicit[f] = true
		}
		sel = feature.Resolve(explicit, reg)
		proj = cfg.Project
		containersDir = cfg.ContainersDir
		versions = cfg.Versions
	} else {
		// Interactive wizard
		result, err := wizard.RunWizard(reg, wizard.WizardDefaults{
			ProjectName:   defaults.projectName,
			Username:      defaults.username,
			BaseImage:     defaults.baseImage,
			ContainersDir: defaults.containersDir,
		})
		if err != nil {
			return err
		}

		// Merge features
		explicit := make(map[string]bool)
		for id := range result.Features {
			explicit[id] = true
		}
		for id := range result.DevFeatures {
			explicit[id] = true
		}

		sel = feature.Resolve(explicit, reg)
		proj = igorconfig.ProjectConfig{
			Name:      result.ProjectName,
			Username:  result.Username,
			BaseImage: result.BaseImage,
		}
		containersDir = result.ContainersDir
		versions = result.Versions
	}

	// Fill in default versions for features that have them
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

	// Build render context
	ctx := igortemplate.NewRenderContext(proj, containersDir, sel, reg, versions)

	// Render templates
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
		{".igor.yml", "igor.yml.tmpl"},
	}

	var entries []generate.FileEntry
	for _, f := range files {
		content, err := renderer.Render(f.template, ctx)
		if err != nil {
			return fmt.Errorf("rendering %s: %w", f.template, err)
		}
		entries = append(entries, generate.FileEntry{
			Path:         f.path,
			TemplateName: f.template,
			Content:      content,
		})
	}

	// Check for existing files
	plan := generate.NewPlan(entries)

	if len(plan.Skips) > 0 && !nonInteractive {
		fmt.Println("\nExisting files will be overwritten:")
		for _, s := range plan.Skips {
			fmt.Printf("  ! %s\n", s.Path)
		}
		fmt.Println()
	}

	// Write all files (creates + overwrites)
	allEntries := append(plan.Creates, plan.Skips...)
	hashes, err := generate.WriteFiles(allEntries)
	if err != nil {
		return fmt.Errorf("writing files: %w", err)
	}

	// Save state to .igor.yml
	explicitList := make([]string, 0, len(sel.Explicit))
	for id := range sel.Explicit {
		explicitList = append(explicitList, id)
	}

	state := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: containersDir,
		Project:       proj,
		Features:      explicitList,
		Versions:      versions,
		Generated:     hashes,
	}

	if err := state.Save(".igor.yml"); err != nil {
		return fmt.Errorf("saving state: %w", err)
	}

	fmt.Println("\nFiles generated successfully:")
	for _, e := range allEntries {
		fmt.Printf("  %s\n", e.Path)
	}
	fmt.Println("\nNext steps:")
	fmt.Println("  1. Review the generated files")
	fmt.Println("  2. Commit .igor.yml and .devcontainer/ to your repo")
	fmt.Println("  3. Open in VS Code with Remote-Containers, or run:")
	fmt.Printf("     docker compose -f .devcontainer/docker-compose.yml up -d\n")

	return nil
}

type initDefaults struct {
	projectName   string
	username      string
	baseImage     string
	containersDir string
}

func detectDefaults() initDefaults {
	d := initDefaults{
		username:      "developer",
		baseImage:     "debian:trixie-slim",
		containersDir: "containers",
	}

	// Try to detect project name from directory
	cwd, err := os.Getwd()
	if err == nil {
		d.projectName = filepath.Base(cwd)
	}

	// Try to detect containers submodule path
	for _, candidate := range []string{"containers", "docker/containers", ".containers"} {
		if info, err := os.Stat(filepath.Join(candidate, "Dockerfile")); err == nil && !info.IsDir() {
			d.containersDir = candidate
			break
		}
	}

	return d
}
