package wizard

import (
	"fmt"
	"sort"

	"github.com/charmbracelet/huh"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

// WizardResult holds the user's selections from the interactive wizard.
type WizardResult struct {
	ProjectName   string
	Username      string
	BaseImage     string
	ContainersDir string
	Features      map[string]bool
	DevFeatures   map[string]bool
	Versions      map[string]string
}

// RunWizard runs the interactive TUI wizard and returns the user's selections.
func RunWizard(reg *feature.Registry, defaults WizardDefaults) (*WizardResult, error) {
	result := &WizardResult{
		ProjectName:   defaults.ProjectName,
		Username:      defaults.Username,
		BaseImage:     defaults.BaseImage,
		ContainersDir: defaults.ContainersDir,
		Features:      make(map[string]bool),
		DevFeatures:   make(map[string]bool),
		Versions:      make(map[string]string),
	}

	// Build option lists upfront
	langOptions := buildLangOptions(reg)
	devToolOptions := buildDevToolOptions(reg)
	cloudOptions := buildCloudOptions(reg)
	toolOptions := buildToolOptions(reg)

	var selectedLangs []string
	var selectedDev []string
	var selectedCloud []string
	var selectedTools []string

	// Single form — all groups enable back navigation between steps
	mainForm := huh.NewForm(
		huh.NewGroup(
			huh.NewInput().
				Title("Project name").
				Description("Used for workspace directory and compose project").
				Value(&result.ProjectName).
				Validate(func(s string) error {
					if s == "" {
						return fmt.Errorf("project name is required")
					}
					return nil
				}),
			huh.NewInput().
				Title("Container username").
				Description("Non-root user inside the container").
				Value(&result.Username),
			huh.NewSelect[string]().
				Title("Base image").
				Options(
					huh.NewOption("Debian Trixie (13) — stable", "debian:trixie-slim"),
					huh.NewOption("Debian Bookworm (12) — oldstable", "debian:bookworm-slim"),
					huh.NewOption("Debian Bullseye (11) — EOL", "debian:bullseye-slim"),
				).
				Value(&result.BaseImage),
			huh.NewInput().
				Title("Containers submodule path").
				Description("Relative path from project root to containers/").
				Value(&result.ContainersDir),
		).Title("Project Configuration"),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Languages & Runtimes").
				Description("Select base language runtimes to include").
				Options(langOptions...).
				Value(&selectedLangs),
		).Title("Language Selection"),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Dev Tools").
				Description("LSP, formatters, linters — each includes its base language runtime automatically").
				Options(devToolOptions...).
				Value(&selectedDev),
		).Title("Dev Tools"),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Cloud & Infrastructure").
				Description("Select cloud tools to include").
				Options(cloudOptions...).
				Value(&selectedCloud),
		).Title("Cloud & Infrastructure"),

		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Tools & Services").
				Description("Select additional tools").
				Options(toolOptions...).
				Value(&selectedTools),
		).Title("Tools & Services"),
	)

	if err := mainForm.Run(); err != nil {
		return nil, err
	}

	// Record selections
	for _, id := range selectedLangs {
		result.Features[id] = true
	}
	for _, id := range selectedDev {
		result.DevFeatures[id] = true
	}
	for _, id := range selectedCloud {
		result.Features[id] = true
	}
	for _, id := range selectedTools {
		result.Features[id] = true
	}

	// Review step
	if err := runReviewStep(reg, result); err != nil {
		return nil, err
	}

	return result, nil
}

// WizardDefaults provides pre-filled values for the wizard.
type WizardDefaults struct {
	ProjectName   string
	Username      string
	BaseImage     string
	ContainersDir string
}

func buildLangOptions(reg *feature.Registry) []huh.Option[string] {
	var opts []huh.Option[string]
	for _, f := range reg.Languages() {
		opts = append(opts, huh.NewOption(
			fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
			f.ID,
		))
	}
	return opts
}

func buildDevToolOptions(reg *feature.Registry) []huh.Option[string] {
	var opts []huh.Option[string]
	for _, f := range reg.ByCategory(feature.CategoryLanguage) {
		if f.IsDev {
			opts = append(opts, huh.NewOption(
				fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
				f.ID,
			))
		}
	}
	return opts
}

func buildCloudOptions(reg *feature.Registry) []huh.Option[string] {
	var opts []huh.Option[string]
	for _, f := range reg.ByCategory(feature.CategoryCloud) {
		opts = append(opts, huh.NewOption(
			fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
			f.ID,
		))
	}
	return opts
}

func buildToolOptions(reg *feature.Registry) []huh.Option[string] {
	var opts []huh.Option[string]
	for _, cat := range []feature.Category{feature.CategoryTool, feature.CategoryDatabase, feature.CategoryAI} {
		for _, f := range reg.ByCategory(cat) {
			if f.ID == "cron" || f.ID == "bindfs" {
				continue
			}
			opts = append(opts, huh.NewOption(
				fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
				f.ID,
			))
		}
	}
	return opts
}

func runReviewStep(reg *feature.Registry, result *WizardResult) error {
	// Merge all selections
	allExplicit := make(map[string]bool)
	for id := range result.Features {
		allExplicit[id] = true
	}
	for id := range result.DevFeatures {
		allExplicit[id] = true
	}

	sel := feature.Resolve(allExplicit, reg)

	// Build review text
	review := titleStyle.Render("Configuration Review") + "\n\n"
	review += fmt.Sprintf("  Project: %s\n", result.ProjectName)
	review += fmt.Sprintf("  User:    %s\n", result.Username)
	review += fmt.Sprintf("  Base:    %s\n", result.BaseImage)
	review += fmt.Sprintf("  Path:    %s\n\n", result.ContainersDir)

	review += subtitleStyle.Render("Selected features:") + "\n"
	explicitIDs := sortedKeys(sel.Explicit)
	for _, id := range explicitIDs {
		f := reg.Get(id)
		if f != nil {
			review += fmt.Sprintf("  + %s\n", f.DisplayName)
		}
	}
	if len(sel.Auto) > 0 {
		review += "\n" + autoDepStyle.Render("Auto-resolved dependencies:") + "\n"
		autoIDs := sortedKeys(sel.Auto)
		for _, id := range autoIDs {
			f := reg.Get(id)
			if f != nil {
				review += fmt.Sprintf("  ~ %s\n", f.DisplayName)
			}
		}
	}

	review += "\n" + subtitleStyle.Render("Files to generate:") + "\n"
	review += "  .devcontainer/docker-compose.yml\n"
	review += "  .devcontainer/devcontainer.json\n"
	review += "  .devcontainer/.env\n"
	review += "  .env.example\n"
	review += "  .igor.yml\n"

	fmt.Println(review)

	var confirmed bool
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewSelect[bool]().
				Title("Generate these files?").
				Options(
					huh.NewOption("Yes, generate files", true),
					huh.NewOption("No, cancel", false),
				).
				Value(&confirmed),
		),
	)

	if err := form.Run(); err != nil {
		return err
	}

	if !confirmed {
		return fmt.Errorf("cancelled by user")
	}

	return nil
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
