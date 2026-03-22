package cmd

import (
	"fmt"
	"io"
	"strings"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/spf13/cobra"
)

var servicesStartCmd = &cobra.Command{
	Use:   "start [name]",
	Short: "Start service containers",
	Long: `Start all service containers, or a specific one by name.

Services are defined in the 'services' section of .igor.yml.
They run on the same Docker network as agent containers.`,
	Args: cobra.MaximumNArgs(1),
	RunE: runServicesStart,
}

func init() {
	servicesCmd.AddCommand(servicesStartCmd)
}

func runServicesStart(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadServiceContext(nil)
	if err != nil {
		return err
	}

	// If a specific service is named, start only that one.
	if len(args) == 1 {
		name := args[0]
		svc, ok := ctx.services[name]
		if !ok {
			return fmt.Errorf("service %q not defined in .igor.yml", name)
		}
		return startService(w, ctx, name, svc)
	}

	// Start all services.
	for name, svc := range ctx.services {
		if err := startService(w, ctx, name, svc); err != nil {
			fmt.Fprintf(w, "  ⚠ %s: %v\n", name, err)
		}
	}
	return nil
}

func startService(w io.Writer, ctx *serviceContext, name string, svc igorconfig.ServiceConfig) error {
	cname := serviceContainerName(ctx.project, name)

	// Check if already running.
	if isContainerRunning(ctx.docker, cname) {
		fmt.Fprintf(w, "%s is already running\n", cname)
		return nil
	}

	// If container exists but is stopped, start it.
	if containerExists(ctx.docker, cname) {
		fmt.Fprintf(w, "Starting stopped container %s ...\n", cname)
		_, err := ctx.docker.Run("start", cname)
		if err != nil {
			return fmt.Errorf("starting container %s: %w", cname, err)
		}
		fmt.Fprintf(w, "%s started\n", cname)
		return nil
	}

	// Create network if it doesn't exist.
	if _, err := ctx.docker.Run("network", "inspect", ctx.network); err != nil {
		if _, err := ctx.docker.Run("network", "create", ctx.network); err != nil {
			return fmt.Errorf("creating network %s: %w", ctx.network, err)
		}
		fmt.Fprintf(w, "Created network %s\n", ctx.network)
	}

	// Build docker run command.
	dockerArgs := []string{
		"run", "-d",
		"--name", cname,
		"--network", ctx.network,
		"--restart", "unless-stopped",
	}

	for _, env := range svc.Environment {
		dockerArgs = append(dockerArgs, "-e", env)
	}
	for _, vol := range svc.Volumes {
		dockerArgs = append(dockerArgs, "-v", vol)
	}

	dockerArgs = append(dockerArgs, svc.Image)

	fmt.Fprintf(w, "Creating container %s ...\n", cname)
	out, err := ctx.docker.Run(dockerArgs...)
	if err != nil {
		return fmt.Errorf("creating container %s: %s", cname, strings.TrimSpace(out))
	}
	fmt.Fprintf(w, "%s started\n", cname)

	// Wait for readiness if port is set.
	if svc.Port > 0 {
		fmt.Fprintf(w, "Waiting for %s to be ready ...\n", name)
		if err := waitForServiceReady(ctx.docker, cname, svc.Port, 30); err != nil {
			fmt.Fprintf(w, "  ⚠ %s may not be ready: %v\n", name, err)
		} else {
			fmt.Fprintf(w, "%s is ready\n", name)
		}
	}

	return nil
}

// waitForServiceReady waits for a service to accept connections on the given port.
func waitForServiceReady(docker DockerRunner, container string, port int, timeoutSecs int) error {
	checkCmd := fmt.Sprintf("timeout %d sh -c 'while ! nc -z localhost %d 2>/dev/null; do sleep 1; done'", timeoutSecs, port)
	_, err := docker.Run("exec", container, "sh", "-c", checkCmd)
	return err
}
