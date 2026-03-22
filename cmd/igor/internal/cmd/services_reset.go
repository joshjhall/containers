package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var servicesResetCmd = &cobra.Command{
	Use:   "reset <name>",
	Short: "Reset a service (drop and recreate per-agent databases)",
	Long: `Reset a service container. For services with per_agent_db: true,
this drops and recreates all per-agent databases. For other services,
this stops and removes the container so it can be started fresh.`,
	Args: cobra.ExactArgs(1),
	RunE: runServicesReset,
}

func init() {
	servicesCmd.AddCommand(servicesResetCmd)
}

func runServicesReset(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadServiceContext(nil)
	if err != nil {
		return err
	}

	name := args[0]
	svc, ok := ctx.services[name]
	if !ok {
		return fmt.Errorf("service %q not defined in .igor.yml", name)
	}

	cname := serviceContainerName(ctx.project, name)

	if !svc.PerAgentDB {
		// Non-database service: stop and remove container.
		if isContainerRunning(ctx.docker, cname) {
			fmt.Fprintf(w, "Stopping %s ...\n", cname)
			if _, err := ctx.docker.Run("stop", cname); err != nil {
				return fmt.Errorf("stopping %s: %w", cname, err)
			}
		}
		if containerExists(ctx.docker, cname) {
			fmt.Fprintf(w, "Removing %s ...\n", cname)
			if _, err := ctx.docker.Run("rm", cname); err != nil {
				return fmt.Errorf("removing %s: %w", cname, err)
			}
		}
		fmt.Fprintf(w, "%s reset (container removed, run 'igor services start %s' to recreate)\n", name, name)
		return nil
	}

	// Per-agent database reset: drop and recreate all agent databases.
	if !isContainerRunning(ctx.docker, cname) {
		return fmt.Errorf("service %s (%s) is not running; start it first", name, cname)
	}

	user, _ := extractPgCredentials(svc.Environment)

	if err := waitForPostgres(ctx.docker, cname, user, 30); err != nil {
		return fmt.Errorf("waiting for %s: %w", name, err)
	}

	// Resolve max agents.
	maxAgents := ctx.cfg.Agents.Max
	if maxAgents == 0 {
		maxAgents = 5
	}

	fmt.Fprintf(w, "Resetting per-agent databases for %s ...\n", name)
	for i := 1; i <= maxAgents; i++ {
		suffix := agentSuffix(i)
		dbName := fmt.Sprintf("%s_%s", ctx.project, suffix)

		sql := fmt.Sprintf("DROP DATABASE IF EXISTS %s", dbName)
		if _, err := ctx.docker.Run("exec", cname, "psql", "-U", user, "-c", sql); err != nil {
			fmt.Fprintf(w, "  ⚠ failed to drop %s: %v\n", dbName, err)
			continue
		}

		sql = fmt.Sprintf("CREATE DATABASE %s", dbName)
		if _, err := ctx.docker.Run("exec", cname, "psql", "-U", user, "-c", sql); err != nil {
			fmt.Fprintf(w, "  ⚠ failed to create %s: %v\n", dbName, err)
			continue
		}

		fmt.Fprintf(w, "  ✓ %s reset\n", dbName)
	}

	fmt.Fprintf(w, "All per-agent databases reset for %s\n", name)
	return nil
}
