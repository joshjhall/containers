package cmd

import (
	"fmt"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"
)

var agentConnectTimeout int

var agentConnectCmd = &cobra.Command{
	Use:   "connect <N>",
	Short: "Connect to a running agent container",
	Long: `Wait for the agent container to be ready, then exec into it
with an interactive bash shell.

Readiness is determined by the container running and the
agent-ready marker file existing.`,
	Args: cobra.ExactArgs(1),
	RunE: runAgentConnect,
}

func init() {
	agentConnectCmd.Flags().IntVar(&agentConnectTimeout, "timeout", 60, "readiness timeout in seconds")
	agentCmd.AddCommand(agentConnectCmd)
}

func runAgentConnect(cmd *cobra.Command, args []string) error {
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
	suffix := agentSuffix(n)
	workdir := filepath.Join(ctx.baseDir, ctx.repos[0]+"-"+suffix)
	readyFile := fmt.Sprintf("/home/%s/.local/state/%s/agent-ready", ctx.username, ctx.project)

	// Wait for container to be running.
	fmt.Fprintf(w, "Waiting for %s to be ready ...\n", name)
	deadline := time.Now().Add(time.Duration(agentConnectTimeout) * time.Second)
	for !isContainerRunning(ctx.docker, name) {
		if time.Now().After(deadline) {
			return fmt.Errorf("timeout: container %s is not running after %ds", name, agentConnectTimeout)
		}
		time.Sleep(1 * time.Second)
	}

	// Wait for readiness marker.
	for {
		if time.Now().After(deadline) {
			fmt.Fprintf(w, "Warning: readiness marker not found, connecting anyway\n")
			break
		}
		out, err := ctx.docker.Run("exec", name, "test", "-f", readyFile)
		if err == nil {
			_ = out
			break
		}
		time.Sleep(1 * time.Second)
	}

	// Exec into the container.
	return ctx.docker.Passthrough(
		"exec", "-it",
		"-u", ctx.username,
		"-w", workdir,
		name,
		"bash", "-l",
	)
}
