package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var servicesStopCmd = &cobra.Command{
	Use:   "stop [name]",
	Short: "Stop service containers",
	Long:  `Stop all service containers, or a specific one by name.`,
	Args:  cobra.MaximumNArgs(1),
	RunE:  runServicesStop,
}

func init() {
	servicesCmd.AddCommand(servicesStopCmd)
}

func runServicesStop(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadServiceContext(nil)
	if err != nil {
		return err
	}

	if len(args) == 1 {
		name := args[0]
		if _, ok := ctx.services[name]; !ok {
			return fmt.Errorf("service %q not defined in .igor.yml", name)
		}
		return stopService(w, ctx, name)
	}

	for name := range ctx.services {
		if err := stopService(w, ctx, name); err != nil {
			fmt.Fprintf(w, "  ⚠ %s: %v\n", name, err)
		}
	}
	return nil
}

func stopService(w interface{ Write([]byte) (int, error) }, ctx *serviceContext, name string) error {
	cname := serviceContainerName(ctx.project, name)

	if !isContainerRunning(ctx.docker, cname) {
		fmt.Fprintf(w, "%s is not running\n", cname)
		return nil
	}

	fmt.Fprintf(w, "Stopping %s ...\n", cname)
	if _, err := ctx.docker.Run("stop", cname); err != nil {
		return fmt.Errorf("stopping %s: %w", cname, err)
	}
	fmt.Fprintf(w, "%s stopped\n", cname)
	return nil
}
