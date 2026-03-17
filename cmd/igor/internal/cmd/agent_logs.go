package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var agentLogsFollow bool

var agentLogsCmd = &cobra.Command{
	Use:   "logs <N>",
	Short: "Show logs for an agent container",
	Args:  cobra.ExactArgs(1),
	RunE:  runAgentLogs,
}

func init() {
	agentLogsCmd.Flags().BoolVarP(&agentLogsFollow, "follow", "f", false, "follow log output")
	agentCmd.AddCommand(agentLogsCmd)
}

func runAgentLogs(cmd *cobra.Command, args []string) error {
	ctx, err := loadAgentContext(nil)
	if err != nil {
		return err
	}

	n, err := validateAgentNum(args[0], ctx.maxAgents)
	if err != nil {
		return err
	}

	name := containerName(ctx.project, n)

	if !containerExists(ctx.docker, name) {
		return fmt.Errorf("container %s does not exist", name)
	}

	dockerArgs := []string{"logs"}
	if agentLogsFollow {
		dockerArgs = append(dockerArgs, "-f")
	}
	dockerArgs = append(dockerArgs, name)

	return ctx.docker.Passthrough(dockerArgs...)
}
