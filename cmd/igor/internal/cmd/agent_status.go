package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"text/tabwriter"

	"github.com/spf13/cobra"
)

var agentStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show status of agent containers",
	RunE:  runAgentStatus,
}

func init() {
	agentCmd.AddCommand(agentStatusCmd)
}

func runAgentStatus(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadAgentContext(nil)
	if err != nil {
		return err
	}

	// Check image.
	imageStatus := "not built"
	if imageExists(ctx.docker, ctx.imageName, ctx.imageTag) {
		imageStatus = "built"
	}
	fmt.Fprintf(w, "Image: %s:%s (%s)\n", ctx.imageName, ctx.imageTag, imageStatus)
	fmt.Fprintf(w, "Network: %s\n\n", ctx.network)

	// Status table.
	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', 0)
	fmt.Fprintln(tw, "AGENT\tCONTAINER\tSTATUS\tWORKTREES")

	for i := 1; i <= ctx.maxAgents; i++ {
		name := containerName(ctx.project, i)
		suffix := agentSuffix(i)

		// Container status.
		status := "not created"
		if isContainerRunning(ctx.docker, name) {
			status = "running"
		} else if containerExists(ctx.docker, name) {
			status = "stopped"
		}

		// Worktree status.
		wtStatus := "none"
		existCount := 0
		for _, repo := range ctx.repos {
			wtDir := filepath.Join(ctx.baseDir, repo+"-"+suffix)
			if _, err := os.Stat(wtDir); err == nil {
				existCount++
			}
		}
		if existCount == len(ctx.repos) {
			wtStatus = "ready"
		} else if existCount > 0 {
			wtStatus = fmt.Sprintf("%d/%d", existCount, len(ctx.repos))
		}

		fmt.Fprintf(tw, "%d\t%s\t%s\t%s\n", i, name, status, wtStatus)
	}

	return tw.Flush()
}
