package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
)

// serviceContext holds resolved config for all service subcommands.
type serviceContext struct {
	cfg      *igorconfig.IgorConfig
	project  string
	network  string
	services map[string]igorconfig.ServiceConfig
	docker   DockerRunner
}

// servicesDockerOverride allows tests to inject a mock DockerRunner.
var servicesDockerOverride DockerRunner

var servicesCmd = &cobra.Command{
	Use:   "services",
	Short: "Manage service containers",
	Long: `Start, stop, and manage service containers (e.g., postgres, redis).

Service containers run on the same Docker network as agents, allowing
agents to connect to them by hostname.`,
}

func init() {
	rootCmd.AddCommand(servicesCmd)
}

// loadServiceContext loads .igor.yml and builds a serviceContext.
func loadServiceContext(docker DockerRunner) (*serviceContext, error) {
	cfgPath := ".igor.yml"
	if configFile != "" {
		cfgPath = configFile
	}

	cfg, err := igorconfig.Load(cfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return nil, fmt.Errorf("loading .igor.yml: %w", err)
	}

	if len(cfg.Services) == 0 {
		return nil, fmt.Errorf("no services defined in .igor.yml")
	}

	// Resolve network (shared with agents).
	network := cfg.Agents.Network
	if network == "" {
		network = fmt.Sprintf("%s-network", cfg.Project.Name)
	}

	if docker == nil {
		if servicesDockerOverride != nil {
			docker = servicesDockerOverride
		} else {
			docker = &execDockerRunner{}
		}
	}

	return &serviceContext{
		cfg:      cfg,
		project:  cfg.Project.Name,
		network:  network,
		services: cfg.Services,
		docker:   docker,
	}, nil
}

// serviceContainerName returns the docker container name for a service.
func serviceContainerName(project, svcName string) string {
	return fmt.Sprintf("%s-%s", project, svcName)
}
