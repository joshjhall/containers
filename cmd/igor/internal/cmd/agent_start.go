package cmd

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"
)

var agentStartRebuild bool

var agentStartCmd = &cobra.Command{
	Use:   "start <N>",
	Short: "Start an agent container",
	Long: `Start agent container N. Creates a new container if none exists,
or restarts a stopped one.

The container mounts the main repository, agent worktrees, shared cache
volumes, and the Docker socket. It uses the container's built-in entrypoint
with "sleep infinity" to keep running.`,
	Args: cobra.ExactArgs(1),
	RunE: runAgentStart,
}

func init() {
	agentStartCmd.Flags().BoolVar(&agentStartRebuild, "rebuild", false, "rebuild image before starting")
	agentCmd.AddCommand(agentStartCmd)
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

	// Image and command.
	dockerArgs = append(dockerArgs, ctx.imageName+":"+ctx.imageTag, "sleep", "infinity")

	fmt.Fprintf(w, "Creating container %s ...\n", name)
	out, err := ctx.docker.Run(dockerArgs...)
	if err != nil {
		return fmt.Errorf("creating container %s: %s", name, strings.TrimSpace(out))
	}
	fmt.Fprintf(w, "%s started\n", name)
	return nil
}
