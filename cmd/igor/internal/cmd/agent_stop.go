package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var agentStopCmd = &cobra.Command{
	Use:   "stop <N>",
	Short: "Stop an agent container",
	Args:  cobra.ExactArgs(1),
	RunE:  runAgentStop,
}

func init() {
	agentCmd.AddCommand(agentStopCmd)
}

func runAgentStop(cmd *cobra.Command, args []string) error {
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

	if !isContainerRunning(ctx.docker, name) {
		fmt.Fprintf(w, "%s is not running\n", name)
		return nil
	}

	fmt.Fprintf(w, "Stopping %s ...\n", name)
	if _, err := ctx.docker.Run("stop", name); err != nil {
		return fmt.Errorf("stopping %s: %w", name, err)
	}
	fmt.Fprintf(w, "%s stopped\n", name)
	return nil
}
