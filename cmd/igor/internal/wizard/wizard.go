package wizard

import (
	"fmt"

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

	// Step 1: Project info
	if err := runProjectStep(result); err != nil {
		return nil, err
	}

	// Step 2: Languages
	if err := runLanguageStep(reg, result); err != nil {
		return nil, err
	}

	// Step 3: Cloud & infra
	if err := runCloudStep(reg, result); err != nil {
		return nil, err
	}

	// Step 4: Tools
	if err := runToolStep(reg, result); err != nil {
		return nil, err
	}

	// Step 5: Review
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

func runProjectStep(result *WizardResult) error {
	form := huh.NewForm(
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
					huh.NewOption("Debian Trixie (13) — latest", "debian:trixie-slim"),
					huh.NewOption("Debian Bookworm (12) — stable", "debian:bookworm-slim"),
					huh.NewOption("Debian Bullseye (11) — legacy", "debian:bullseye-slim"),
				).
				Value(&result.BaseImage),
			huh.NewInput().
				Title("Containers submodule path").
				Description("Relative path from project root to containers/").
				Value(&result.ContainersDir),
		).Title("Project Configuration"),
	)
	return form.Run()
}

func runLanguageStep(reg *feature.Registry, result *WizardResult) error {
	langs := reg.Languages()

	// Filter to just the main language features (no android/kotlin for simplicity in base list)
	var langOptions []huh.Option[string]
	for _, f := range langs {
		langOptions = append(langOptions, huh.NewOption(
			fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
			f.ID,
		))
	}

	var selectedLangs []string
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Languages & Runtimes").
				Description("Select languages to include (dev tools added automatically)").
				Options(langOptions...).
				Value(&selectedLangs),
		).Title("Language Selection"),
	)

	if err := form.Run(); err != nil {
		return err
	}

	// For each selected language, ask about dev tools
	for _, langID := range selectedLangs {
		result.Features[langID] = true

		devID := langID + "_dev"
		devFeature := reg.Get(devID)
		if devFeature != nil {
			var includeDev bool
			devForm := huh.NewForm(
				huh.NewGroup(
					huh.NewConfirm().
						Title(fmt.Sprintf("Include %s?", devFeature.DisplayName)).
						Description(devFeature.Description).
						Value(&includeDev),
				),
			)
			if err := devForm.Run(); err != nil {
				return err
			}
			if includeDev {
				result.DevFeatures[devID] = true
			}
		}
	}

	return nil
}

func runCloudStep(reg *feature.Registry, result *WizardResult) error {
	cloudFeatures := reg.ByCategory(feature.CategoryCloud)
	var cloudOptions []huh.Option[string]
	for _, f := range cloudFeatures {
		cloudOptions = append(cloudOptions, huh.NewOption(
			fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
			f.ID,
		))
	}

	var selectedCloud []string
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Cloud & Infrastructure").
				Description("Select cloud tools to include").
				Options(cloudOptions...).
				Value(&selectedCloud),
		).Title("Cloud & Infrastructure"),
	)

	if err := form.Run(); err != nil {
		return err
	}

	for _, id := range selectedCloud {
		result.Features[id] = true
	}
	return nil
}

func runToolStep(reg *feature.Registry, result *WizardResult) error {
	// Combine tools + database + AI categories
	var toolOptions []huh.Option[string]

	for _, cat := range []feature.Category{feature.CategoryTool, feature.CategoryDatabase, feature.CategoryAI} {
		for _, f := range reg.ByCategory(cat) {
			// Skip internal auto-resolved features
			if f.ID == "cron" || f.ID == "bindfs" {
				continue
			}
			toolOptions = append(toolOptions, huh.NewOption(
				fmt.Sprintf("%s — %s", f.DisplayName, f.Description),
				f.ID,
			))
		}
	}

	var selectedTools []string
	form := huh.NewForm(
		huh.NewGroup(
			huh.NewMultiSelect[string]().
				Title("Tools & Services").
				Description("Select additional tools").
				Options(toolOptions...).
				Value(&selectedTools),
		).Title("Tools & Services"),
	)

	if err := form.Run(); err != nil {
		return err
	}

	for _, id := range selectedTools {
		result.Features[id] = true
	}
	return nil
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
	for id := range sel.Explicit {
		f := reg.Get(id)
		if f != nil {
			review += fmt.Sprintf("  + %s\n", f.DisplayName)
		}
	}
	if len(sel.Auto) > 0 {
		review += "\n" + autoDepStyle.Render("Auto-resolved dependencies:") + "\n"
		for id := range sel.Auto {
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
			huh.NewConfirm().
				Title("Generate these files?").
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
