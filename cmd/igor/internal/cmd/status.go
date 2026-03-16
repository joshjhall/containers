package cmd

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

var errDriftDetected = errors.New("drift detected")

var statusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show enabled features and generated file health",
	Long: `Display the current igor project status including enabled features,
auto-resolved dependencies, and whether generated files have been modified
or deleted since the last init/update.

Exit code 0 means all files are clean. Exit code 1 means drift was detected.`,
	RunE: runStatus,
}

func init() {
	rootCmd.AddCommand(statusCmd)
}

func runStatus(cmd *cobra.Command, args []string) error {
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	w := cmd.OutOrStdout()

	reg := feature.NewRegistry()
	explicit := make(map[string]bool)
	for _, f := range cfg.Features {
		explicit[f] = true
	}
	sel := feature.Resolve(explicit, reg)

	printProjectHeader(w, cfg)
	printFeatureStatus(w, reg, sel, cfg)
	hasDrift := printFileStatus(w, cfg)

	if hasDrift {
		return errDriftDetected
	}
	return nil
}

func printProjectHeader(w io.Writer, cfg *igorconfig.IgorConfig) {
	version := cfg.ContainersRef
	if version == "" {
		version = detectContainersVersion()
	}

	if version != "" {
		fmt.Fprintf(w, "Project: %s (containers %s)\n", cfg.Project.Name, version)
	} else {
		fmt.Fprintf(w, "Project: %s\n", cfg.Project.Name)
	}
	fmt.Fprintf(w, "Base: %s\n", cfg.Project.BaseImage)
	fmt.Fprintf(w, "User: %s\n", cfg.Project.Username)
}

func printFeatureStatus(w io.Writer, reg *feature.Registry, sel *feature.Selection, cfg *igorconfig.IgorConfig) {
	explicitCount := len(sel.Explicit)
	autoCount := len(sel.Auto)

	fmt.Fprintf(w, "\nFeatures (%d explicit + %d auto):\n", explicitCount, autoCount)

	for _, f := range reg.All() {
		if !sel.Has(f.ID) {
			continue
		}

		version := ""
		if f.VersionArg != "" {
			if v, ok := cfg.Versions[f.VersionArg]; ok {
				version = v
			}
		}

		if sel.Explicit[f.ID] {
			if version != "" {
				fmt.Fprintf(w, "  ✓ %s (%s)\n", f.ID, version)
			} else {
				fmt.Fprintf(w, "  ✓ %s\n", f.ID)
			}
		} else {
			implier := findImplier(f, sel, reg)
			if implier != "" {
				fmt.Fprintf(w, "  ~ %s (auto: %s)\n", f.ID, implier)
			} else {
				fmt.Fprintf(w, "  ~ %s (auto)\n", f.ID)
			}
		}
	}
}

// findImplier finds which explicit feature caused an auto feature to be included.
func findImplier(f *feature.Feature, sel *feature.Selection, reg *feature.Registry) string {
	// Check ImpliedBy: does any explicit feature imply this one?
	for _, implierID := range f.ImpliedBy {
		if sel.Has(implierID) {
			return implierID
		}
	}

	// Check Requires: does any explicit feature require this one?
	for _, other := range reg.All() {
		if !sel.Has(other.ID) {
			continue
		}
		for _, req := range other.Requires {
			if req == f.ID {
				return other.ID
			}
		}
	}

	return ""
}

func printFileStatus(w io.Writer, cfg *igorconfig.IgorConfig) bool {
	if len(cfg.Generated) == 0 {
		return false
	}

	// Sort paths for stable output, skip .igor.yml (it's overwritten by
	// state.Save() so its disk hash never matches the template hash).
	paths := make([]string, 0, len(cfg.Generated))
	for p := range cfg.Generated {
		if p == ".igor.yml" {
			continue
		}
		paths = append(paths, p)
	}
	sort.Strings(paths)

	fmt.Fprintf(w, "\nGenerated files:\n")

	hasDrift := false
	for _, path := range paths {
		expectedHash := cfg.Generated[path]
		status := checkFileStatus(path, expectedHash)
		switch status {
		case "unchanged":
			fmt.Fprintf(w, "  ✓ %s (unchanged)\n", path)
		case "modified":
			fmt.Fprintf(w, "  ! %s (modified)\n", path)
			hasDrift = true
		case "missing":
			fmt.Fprintf(w, "  ✗ %s (missing)\n", path)
			hasDrift = true
		}
	}

	return hasDrift
}

func checkFileStatus(path, expectedHash string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return "missing"
	}
	diskHash := fmt.Sprintf("%x", sha256.Sum256(data))
	if diskHash == expectedHash {
		return "unchanged"
	}
	return "modified"
}
