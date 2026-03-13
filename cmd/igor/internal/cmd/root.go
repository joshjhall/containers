package cmd

import (
	"github.com/spf13/cobra"
)

var (
	verbose        bool
	nonInteractive bool
	configFile     string
)

var rootCmd = &cobra.Command{
	Use:   "igor",
	Short: "Scaffold devcontainer configurations from the containers submodule",
	Long: `Igor is a TUI wizard that generates devcontainer configurations
(.devcontainer/docker-compose.yml, devcontainer.json, .env) from an
interactive feature selection wizard.

It reads available features from the containers submodule and produces
working development container setups.`,
	SilenceUsage: true,
}

func init() {
	rootCmd.PersistentFlags().BoolVarP(&verbose, "verbose", "v", false, "verbose output")
	rootCmd.PersistentFlags().BoolVar(&nonInteractive, "non-interactive", false, "run without interactive prompts (requires --config)")
	rootCmd.PersistentFlags().StringVar(&configFile, "config", "", "path to .igor.yml config file (for non-interactive mode)")
}

func Execute() error {
	return rootCmd.Execute()
}
