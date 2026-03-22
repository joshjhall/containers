package cmd

import (
	"fmt"
	"sort"

	"github.com/spf13/cobra"
)

var servicesStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show service container status",
	Args:  cobra.NoArgs,
	RunE:  runServicesStatus,
}

func init() {
	servicesCmd.AddCommand(servicesStatusCmd)
}

func runServicesStatus(cmd *cobra.Command, _ []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadServiceContext(nil)
	if err != nil {
		return err
	}

	fmt.Fprintf(w, "Network: %s\n\n", ctx.network)
	fmt.Fprintf(w, "%-20s %-25s %-15s %s\n", "SERVICE", "CONTAINER", "STATUS", "IMAGE")
	fmt.Fprintf(w, "%-20s %-25s %-15s %s\n", "-------", "---------", "------", "-----")

	// Sort service names for stable output.
	names := make([]string, 0, len(ctx.services))
	for name := range ctx.services {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		svc := ctx.services[name]
		cname := serviceContainerName(ctx.project, name)

		status := "not created"
		if isContainerRunning(ctx.docker, cname) {
			status = "running"
		} else if containerExists(ctx.docker, cname) {
			status = "stopped"
		}

		fmt.Fprintf(w, "%-20s %-25s %-15s %s\n", name, cname, status, svc.Image)
	}

	return nil
}
