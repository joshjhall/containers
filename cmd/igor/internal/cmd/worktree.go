package cmd

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
	igortmpl "github.com/joshjhall/containers/cmd/igor/internal/template"
)

var worktreeDryRun bool

var worktreeCmd = &cobra.Command{
	Use:   "worktree",
	Short: "Manage git worktrees for agent containers",
}

var worktreeCreateCmd = &cobra.Command{
	Use:   "create <N>",
	Short: "Create git worktrees for agent N",
	Long: `Create git worktrees for the given agent number.

For each repository listed in .igor.yml agents.repos (or the project name
if repos is not set), creates a worktree at /workspace/<repo>-agentNN with
a branch named agentNN.

The .git pointers are rewritten to use container paths so that git works
correctly inside the container. The docker-compose file is updated to mount
the new worktrees into the main devcontainer.`,
	Args: cobra.ExactArgs(1),
	RunE: runWorktreeCreate,
}

var worktreeRemoveCmd = &cobra.Command{
	Use:   "remove <N>",
	Short: "Remove git worktrees for agent N",
	Long: `Remove git worktrees for the given agent number and update the
docker-compose file to remove the corresponding volume mounts.`,
	Args: cobra.ExactArgs(1),
	RunE: runWorktreeRemove,
}

func init() {
	worktreeCreateCmd.Flags().BoolVar(&worktreeDryRun, "dry-run", false, "show what would happen without creating worktrees")
	worktreeCmd.AddCommand(worktreeCreateCmd)
	worktreeCmd.AddCommand(worktreeRemoveCmd)
	rootCmd.AddCommand(worktreeCmd)
}

func runWorktreeCreate(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	n, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid agent number %q: must be an integer", args[0])
	}

	maxAgents := cfg.Agents.Max
	if maxAgents == 0 {
		maxAgents = 5
	}

	if n < 1 || n > maxAgents {
		return fmt.Errorf("agent number must be between 1 and %d", maxAgents)
	}

	agentSuffix := fmt.Sprintf("agent%02d", n)

	repos := cfg.Agents.Repos
	if len(repos) == 0 {
		repos = []string{cfg.Project.Name}
	}

	base := "/workspace"
	if cfg.Project.WorkingDir != "" {
		base = filepath.Dir(cfg.Project.WorkingDir)
	}

	for _, repo := range repos {
		mainRepo := filepath.Join(base, repo)
		worktreeDir := filepath.Join(base, repo+"-"+agentSuffix)

		if worktreeDryRun {
			fmt.Fprintf(w, "Would create worktree %s (branch %s) from %s\n", worktreeDir, agentSuffix, mainRepo)
			continue
		}

		err := createWorktree(w, mainRepo, worktreeDir, repo, agentSuffix)
		if err != nil {
			return err
		}
	}

	// Update compose file with new worktree mounts.
	if !worktreeDryRun {
		if err := updateComposeWorktreeMounts(w, cfg); err != nil {
			fmt.Fprintf(w, "  ⚠ compose update: %v\n", err)
		}
	}

	return nil
}

func runWorktreeRemove(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	n, err := strconv.Atoi(args[0])
	if err != nil {
		return fmt.Errorf("invalid agent number %q: must be an integer", args[0])
	}

	maxAgents := cfg.Agents.Max
	if maxAgents == 0 {
		maxAgents = 5
	}

	if n < 1 || n > maxAgents {
		return fmt.Errorf("agent number must be between 1 and %d", maxAgents)
	}

	agentSuffix := fmt.Sprintf("agent%02d", n)

	repos := cfg.Agents.Repos
	if len(repos) == 0 {
		repos = []string{cfg.Project.Name}
	}

	base := "/workspace"
	if cfg.Project.WorkingDir != "" {
		base = filepath.Dir(cfg.Project.WorkingDir)
	}

	for _, repo := range repos {
		mainRepo := filepath.Join(base, repo)
		worktreeDir := filepath.Join(base, repo+"-"+agentSuffix)

		if _, err := os.Stat(worktreeDir); os.IsNotExist(err) {
			fmt.Fprintf(w, "%s-%s: worktree does not exist\n", repo, agentSuffix)
			continue
		}

		// Remove via git worktree remove.
		if _, err := runGit(mainRepo, "worktree", "remove", "--force", worktreeDir); err != nil {
			// If git worktree remove fails, try manual cleanup.
			if rmErr := os.RemoveAll(worktreeDir); rmErr != nil {
				return fmt.Errorf("removing worktree %s: %w", worktreeDir, rmErr)
			}
		}
		fmt.Fprintf(w, "%s-%s: removed\n", repo, agentSuffix)
	}

	// Update compose file to remove worktree mounts.
	if err := updateComposeWorktreeMounts(w, cfg); err != nil {
		fmt.Fprintf(w, "  ⚠ compose update: %v\n", err)
	}

	return nil
}

// detectWorktreeMounts scans for existing worktree directories and returns
// volume mount specs for the compose file.
func detectWorktreeMounts(repos []string, maxAgents int, baseDir string) []string {
	var mounts []string
	for n := 1; n <= maxAgents; n++ {
		suffix := fmt.Sprintf("agent%02d", n)
		for _, repo := range repos {
			worktreeDir := filepath.Join(baseDir, repo+"-"+suffix)
			if _, err := os.Stat(worktreeDir); err == nil {
				// Compose paths are relative to .devcontainer/
				relPath := "../" + repo + "-" + suffix
				containerPath := "/workspace/" + repo + "-" + suffix
				mounts = append(mounts, relPath+":"+containerPath)
			}
		}
	}
	sort.Strings(mounts)
	return mounts
}

// updateComposeWorktreeMounts re-renders the docker-compose file with current worktree mounts.
func updateComposeWorktreeMounts(w io.Writer, cfg *igorconfig.IgorConfig) error {
	repos := cfg.Agents.Repos
	if len(repos) == 0 {
		repos = []string{cfg.Project.Name}
	}
	maxAgents := cfg.Agents.Max
	if maxAgents == 0 {
		maxAgents = 5
	}
	base := "/workspace"
	if cfg.Project.WorkingDir != "" {
		base = filepath.Dir(cfg.Project.WorkingDir)
	}

	mounts := detectWorktreeMounts(repos, maxAgents, base)

	// Build render context.
	reg := feature.NewRegistry()
	explicit := make(map[string]bool, len(cfg.Features))
	for _, id := range cfg.Features {
		explicit[id] = true
	}
	sel := feature.Resolve(explicit, reg)

	ctx := igortmpl.NewRenderContext(cfg.Project, cfg.ContainersDir, sel, reg, cfg.Versions, cfg.Agents)
	ctx.WorktreeMounts = mounts

	// Render compose template.
	renderer, err := igortmpl.NewRenderer()
	if err != nil {
		return fmt.Errorf("creating renderer: %w", err)
	}
	content, err := renderer.Render("docker-compose.yml.tmpl", ctx)
	if err != nil {
		return fmt.Errorf("rendering compose: %w", err)
	}

	// Write to .devcontainer/docker-compose.yml
	composePath := filepath.Join(".devcontainer", "docker-compose.yml")
	if err := os.MkdirAll(filepath.Dir(composePath), 0755); err != nil {
		return fmt.Errorf("creating directory: %w", err)
	}
	if err := os.WriteFile(composePath, []byte(content), 0644); err != nil {
		return fmt.Errorf("writing compose file: %w", err)
	}

	if len(mounts) > 0 {
		fmt.Fprintf(w, "Updated %s with %d worktree mount(s)\n", composePath, len(mounts))
	} else {
		fmt.Fprintf(w, "Updated %s (no worktree mounts)\n", composePath)
	}

	return nil
}

func createWorktree(w io.Writer, mainRepo, worktreeDir, repoName, agentSuffix string) error {
	if _, err := os.Stat(worktreeDir); err == nil {
		fmt.Fprintf(w, "%s-%s: worktree already exists\n", repoName, agentSuffix)
		return nil
	}

	gitDir, err := resolveGitDir(mainRepo)
	if err != nil {
		fmt.Fprintf(w, "%s: main repo not found at %s, skipping\n", repoName, mainRepo)
		return nil
	}

	branch := agentSuffix
	if _, err := runGit(mainRepo, "rev-parse", "--verify", branch); err != nil {
		if _, err := runGit(mainRepo, "branch", branch); err != nil {
			return fmt.Errorf("creating branch %s in %s: %w", branch, mainRepo, err)
		}
	}

	if _, err := runGit(mainRepo, "worktree", "add", worktreeDir, branch); err != nil {
		return fmt.Errorf("creating worktree at %s: %w", worktreeDir, err)
	}

	worktreeGitFile := filepath.Join(worktreeDir, ".git")
	worktreeGitContent := fmt.Sprintf("gitdir: %s/worktrees/%s-%s\n", gitDir, repoName, agentSuffix)
	if err := overwriteFile(worktreeGitFile, []byte(worktreeGitContent)); err != nil {
		return fmt.Errorf("rewriting worktree .git: %w", err)
	}

	worktreeLink := filepath.Join(gitDir, "worktrees", repoName+"-"+agentSuffix, "gitdir")
	base := filepath.Dir(mainRepo)
	newGitdir := filepath.Join(base, repoName+"-"+agentSuffix, ".git") + "\n"
	if err := overwriteFile(worktreeLink, []byte(newGitdir)); err != nil {
		return fmt.Errorf("rewriting gitdir in %s: %w", worktreeLink, err)
	}

	fmt.Fprintf(w, "%s-%s: created at %s\n", repoName, agentSuffix, worktreeDir)
	return nil
}

func runGit(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func overwriteFile(path string, data []byte) error {
	os.Remove(path)
	return os.WriteFile(path, data, 0644)
}

func resolveGitDir(repoPath string) (string, error) {
	gitPath := filepath.Join(repoPath, ".git")
	info, err := os.Stat(gitPath)
	if err != nil {
		return "", err
	}

	if info.IsDir() {
		return gitPath, nil
	}

	data, err := os.ReadFile(gitPath)
	if err != nil {
		return "", err
	}

	content := strings.TrimSpace(string(data))
	if !strings.HasPrefix(content, "gitdir: ") {
		return "", fmt.Errorf("unexpected .git file content: %s", content)
	}

	gitdir := strings.TrimPrefix(content, "gitdir: ")
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(repoPath, gitdir)
	}

	return gitdir, nil
}
