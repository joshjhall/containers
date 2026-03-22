package cmd

import (
	"fmt"
	"strings"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
)

// provisionPerAgentDBs creates per-agent databases for all services with PerAgentDB.
func provisionPerAgentDBs(docker DockerRunner, project string, n int, services map[string]igorconfig.ServiceConfig) error {
	suffix := agentSuffix(n) // "agent01"
	dbName := fmt.Sprintf("%s_%s", project, suffix)

	for svcName, svc := range services {
		if !svc.PerAgentDB {
			continue
		}

		svcContainer := serviceContainerName(project, svcName)

		// Check service container is running.
		if !isContainerRunning(docker, svcContainer) {
			return fmt.Errorf("service %s (%s) is not running; run 'igor services start' first", svcName, svcContainer)
		}

		// Wait for postgres to be ready.
		user, _ := extractPgCredentials(svc.Environment)
		if err := waitForPostgres(docker, svcContainer, user, 30); err != nil {
			return fmt.Errorf("waiting for %s: %w", svcName, err)
		}

		// Check if database exists.
		out, err := docker.Run("exec", svcContainer, "psql", "-U", user, "-tc",
			fmt.Sprintf("SELECT 1 FROM pg_database WHERE datname = '%s'", dbName))
		if err != nil {
			return fmt.Errorf("checking database %s: %w", dbName, err)
		}

		if strings.TrimSpace(out) == "1" {
			// Database already exists.
			return nil
		}

		// Create the database.
		if _, err := docker.Run("exec", svcContainer, "psql", "-U", user, "-c",
			fmt.Sprintf("CREATE DATABASE %s", dbName)); err != nil {
			return fmt.Errorf("creating database %s: %w", dbName, err)
		}
	}

	return nil
}

// waitForPostgres waits for PostgreSQL to accept connections.
func waitForPostgres(docker DockerRunner, container, user string, timeoutSecs int) error {
	checkCmd := fmt.Sprintf("timeout %d sh -c 'until pg_isready -U %s 2>/dev/null; do sleep 1; done'", timeoutSecs, user)
	_, err := docker.Run("exec", container, "sh", "-c", checkCmd)
	return err
}

// extractPgCredentials parses POSTGRES_USER and POSTGRES_PASSWORD from an env list.
func extractPgCredentials(env []string) (user, password string) {
	user = "postgres"
	password = "devpassword"
	for _, e := range env {
		parts := strings.SplitN(e, "=", 2)
		if len(parts) != 2 {
			continue
		}
		switch parts[0] {
		case "POSTGRES_USER":
			user = parts[1]
		case "POSTGRES_PASSWORD":
			password = parts[1]
		}
	}
	return
}

// perAgentDBURL builds the DATABASE_URL for an agent connecting to a per-agent database.
func perAgentDBURL(project string, n int, svcName string, svc igorconfig.ServiceConfig) string {
	suffix := agentSuffix(n)
	dbName := fmt.Sprintf("%s_%s", project, suffix)
	svcHost := serviceContainerName(project, svcName)
	user, password := extractPgCredentials(svc.Environment)
	return fmt.Sprintf("postgres://%s:%s@%s:%d/%s", user, password, svcHost, svc.Port, dbName)
}
