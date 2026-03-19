package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags.
var Version = "dev"

// BuildTime is set at build time via -ldflags. Falls back to runtime detection.
var BuildTime = ""

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print igor and containers version",
	RunE: func(cmd *cobra.Command, args []string) error {
		if BuildTime != "" {
			fmt.Printf("igor %s (built %s)\n", Version, BuildTime)
		} else {
			fmt.Printf("igor %s\n", Version)
		}

		// Try to read containers VERSION file
		containersVersion := detectContainersVersion()
		if containersVersion != "" {
			fmt.Printf("containers %s\n", containersVersion)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}

func detectContainersVersion() string {
	// Walk up from cwd looking for VERSION in a containers submodule
	paths := []string{
		"VERSION",
		"containers/VERSION",
		"../VERSION",
	}

	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}

	for _, p := range paths {
		full := filepath.Join(cwd, p)
		data, err := os.ReadFile(full)
		if err == nil {
			return strings.TrimSpace(string(data))
		}
	}
	return ""
}
