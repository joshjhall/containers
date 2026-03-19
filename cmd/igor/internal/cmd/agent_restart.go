package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var agentRestartCmd = &cobra.Command{
	Use:   "restart <N>",
	Short: "Restart an agent container (stop + remove + start)",
	Args:  cobra.ExactArgs(1),
	RunE:  runAgentRestart,
}

func init() {
	agentCmd.AddCommand(agentRestartCmd)
}

func runAgentRestart(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadAgentContext(nil)
	if err != nil {
		return err
	}

	n, err := validateAgentNum(args[0], ctx.maxAgents)
	if err != nil {
		return err
	}

	name := containerName(ctx.project, n)

	// Stop if running.
	if isContainerRunning(ctx.docker, name) {
		fmt.Fprintf(w, "Stopping %s ...\n", name)
		if _, err := ctx.docker.Run("stop", name); err != nil {
			return fmt.Errorf("stopping %s: %w", name, err)
		}
	}

	// Remove if exists.
	if containerExists(ctx.docker, name) {
		fmt.Fprintf(w, "Removing %s ...\n", name)
		if _, err := ctx.docker.Run("rm", name); err != nil {
			return fmt.Errorf("removing %s: %w", name, err)
		}
	}

	// Start fresh.
	return runAgentStart(cmd, args)
}
