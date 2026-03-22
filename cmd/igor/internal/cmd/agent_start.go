package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/joshjhall/containers/cmd/igor/internal/cmd/scripts"
	"github.com/spf13/cobra"
)

var agentStartRebuild bool

var agentStartCmd = &cobra.Command{
	Use:   "start <N>",
	Short: "Start an agent container",
	Long: `Start agent container N. Creates a new container if none exists,
or restarts a stopped one.

The container runs the embedded agent entrypoint which handles init/start
lifecycle and readiness signaling.`,
	Args: cobra.ExactArgs(1),
	RunE: runAgentStart,
}

func init() {
	agentStartCmd.Flags().BoolVar(&agentStartRebuild, "rebuild", false, "rebuild image before starting")
	agentCmd.AddCommand(agentStartCmd)
}

// extractAgentScripts writes embedded agent scripts to a temporary directory
// and returns the path. The caller should not remove this directory — it must
// persist for the container's lifetime.
func extractAgentScripts() (string, error) {
	dir, err := os.MkdirTemp("", "igor-agent-scripts-*")
	if err != nil {
		return "", fmt.Errorf("creating temp dir: %w", err)
	}

	entries, err := scripts.AgentScripts.ReadDir(".")
	if err != nil {
		return "", fmt.Errorf("reading embedded scripts: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, err := scripts.AgentScripts.ReadFile(entry.Name())
		if err != nil {
			return "", fmt.Errorf("reading %s: %w", entry.Name(), err)
		}
		path := filepath.Join(dir, entry.Name())
		if err := os.WriteFile(path, data, 0755); err != nil {
			return "", fmt.Errorf("writing %s: %w", entry.Name(), err)
		}
	}

	return dir, nil
}

func runAgentStart(cmd *cobra.Command, args []string) error {
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

	// Rebuild if requested.
	if agentStartRebuild {
		if err := runAgentBuild(cmd, nil); err != nil {
			return fmt.Errorf("rebuild failed: %w", err)
		}
	}

	// Check if already running.
	if isContainerRunning(ctx.docker, name) {
		fmt.Fprintf(w, "%s is already running\n", name)
		return nil
	}

	// If container exists but is stopped, start it.
	if containerExists(ctx.docker, name) {
		fmt.Fprintf(w, "Starting stopped container %s ...\n", name)
		_, err := ctx.docker.Run("start", name)
		if err != nil {
			return fmt.Errorf("starting container %s: %w", name, err)
		}
		fmt.Fprintf(w, "%s started\n", name)
		return nil
	}

	// Verify image exists.
	if !imageExists(ctx.docker, ctx.imageName, ctx.imageTag) {
		return fmt.Errorf("image %s:%s not found; run 'igor agent build' first", ctx.imageName, ctx.imageTag)
	}

	// Verify worktrees exist for at least the first repo.
	firstWorktree := filepath.Join(ctx.baseDir, ctx.repos[0]+"-"+suffix)
	if _, err := ctx.docker.Run("run", "--rm", "-v", ctx.baseDir+":"+ctx.baseDir+":ro",
		"alpine", "test", "-d", firstWorktree); err != nil {
		// Fall back to local filesystem check.
		// Worktrees are on the host, so just check locally if possible.
	}

	// Extract embedded agent scripts to a host directory for mounting.
	scriptsDir, err := extractAgentScripts()
	if err != nil {
		return fmt.Errorf("extracting agent scripts: %w", err)
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
		"--name", name,
		"--hostname", "agent-" + fmt.Sprintf("%d", n),
		"--network", ctx.network,
		"--restart", "unless-stopped",
		"--init",
	}

	// Mount Docker socket.
	dockerArgs = append(dockerArgs, "-v", "/var/run/docker.sock:/var/run/docker.sock")

	// Mount agent scripts.
	dockerArgs = append(dockerArgs, "-v", scriptsDir+":/opt/agent-scripts:ro")

	// Mount main repos.
	for _, repo := range ctx.repos {
		mainRepo := filepath.Join(ctx.baseDir, repo)
		dockerArgs = append(dockerArgs, "-v", mainRepo+":"+mainRepo)
	}

	// Mount agent worktrees.
	for _, repo := range ctx.repos {
		worktreeDir := filepath.Join(ctx.baseDir, repo+"-"+suffix)
		dockerArgs = append(dockerArgs, "-v", worktreeDir+":"+worktreeDir)
	}

	// Mount shared cache volumes.
	for _, vol := range ctx.sharedVolumes {
		dockerArgs = append(dockerArgs, "-v", vol)
	}

	// Inject agent environment variables.
	dockerArgs = append(dockerArgs, "-e", "PROJECT_NAME="+ctx.project)
	dockerArgs = append(dockerArgs, "-e", "AGENT_REPOS="+strings.Join(ctx.repos, ","))

	// Inject per-agent database environment variables.
	for svcName, svc := range ctx.cfg.Services {
		if svc.PerAgentDB && svc.Port > 0 {
			dbURL := perAgentDBURL(ctx.project, n, svcName, svc)
			dockerArgs = append(dockerArgs, "-e", "DATABASE_URL="+dbURL)
		}
	}

	// Image and entrypoint command.
	dockerArgs = append(dockerArgs, ctx.imageName+":"+ctx.imageTag, "/opt/agent-scripts/agent-entrypoint.sh")

	fmt.Fprintf(w, "Creating container %s ...\n", name)
	out, err := ctx.docker.Run(dockerArgs...)
	if err != nil {
		return fmt.Errorf("creating container %s: %s", name, strings.TrimSpace(out))
	}
	fmt.Fprintf(w, "%s started\n", name)

	// Provision per-agent databases (best-effort — service may not be running).
	if len(ctx.cfg.Services) > 0 {
		if dbErr := provisionPerAgentDBs(ctx.docker, ctx.project, n, ctx.cfg.Services); dbErr != nil {
			fmt.Fprintf(w, "  ⚠ database provisioning: %v\n", dbErr)
		}
	}

	return nil
}
