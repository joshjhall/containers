package cmd

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
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
correctly inside the container.`,
	Args: cobra.ExactArgs(1),
	RunE: runWorktreeCreate,
}

func init() {
	worktreeCreateCmd.Flags().BoolVar(&worktreeDryRun, "dry-run", false, "show what would happen without creating worktrees")
	worktreeCmd.AddCommand(worktreeCreateCmd)
	rootCmd.AddCommand(worktreeCmd)
}

func runWorktreeCreate(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	// 1. Load .igor.yml
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return fmt.Errorf("loading .igor.yml: %w", err)
	}

	// 2. Parse and validate N
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

	// 3. Compute agent suffix
	agentSuffix := fmt.Sprintf("agent%02d", n)

	// 4. Determine repos
	repos := cfg.Agents.Repos
	if len(repos) == 0 {
		repos = []string{cfg.Project.Name}
	}

	// 5. Determine base directory
	base := "/workspace"
	if cfg.Project.WorkingDir != "" {
		base = filepath.Dir(cfg.Project.WorkingDir)
	}

	// 6. Create worktrees
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

	return nil
}

func createWorktree(w io.Writer, mainRepo, worktreeDir, repoName, agentSuffix string) error {
	// Check if worktree already exists
	if _, err := os.Stat(worktreeDir); err == nil {
		fmt.Fprintf(w, "%s-%s: worktree already exists\n", repoName, agentSuffix)
		return nil
	}

	// Verify main repo .git exists
	gitDir, err := resolveGitDir(mainRepo)
	if err != nil {
		fmt.Fprintf(w, "%s: main repo not found at %s, skipping\n", repoName, mainRepo)
		return nil
	}

	// Check if branch exists; create from HEAD if not
	branch := agentSuffix
	if _, err := runGit(mainRepo, "rev-parse", "--verify", branch); err != nil {
		if _, err := runGit(mainRepo, "branch", branch); err != nil {
			return fmt.Errorf("creating branch %s in %s: %w", branch, mainRepo, err)
		}
	}

	// Create worktree
	if _, err := runGit(mainRepo, "worktree", "add", worktreeDir, branch); err != nil {
		return fmt.Errorf("creating worktree at %s: %w", worktreeDir, err)
	}

	// Rewrite worktree .git file for container paths
	worktreeGitContent := fmt.Sprintf("gitdir: %s/worktrees/%s-%s\n", gitDir, repoName, agentSuffix)
	if err := os.WriteFile(filepath.Join(worktreeDir, ".git"), []byte(worktreeGitContent), 0644); err != nil {
		return fmt.Errorf("rewriting worktree .git: %w", err)
	}

	// Rewrite main repo's worktree gitdir pointer
	worktreeLink := filepath.Join(gitDir, "worktrees", repoName+"-"+agentSuffix, "gitdir")
	base := filepath.Dir(mainRepo)
	newGitdir := filepath.Join(base, repoName+"-"+agentSuffix, ".git") + "\n"
	if err := os.WriteFile(worktreeLink, []byte(newGitdir), 0644); err != nil {
		return fmt.Errorf("rewriting gitdir in %s: %w", worktreeLink, err)
	}

	fmt.Fprintf(w, "%s-%s: created at %s\n", repoName, agentSuffix, worktreeDir)
	return nil
}

// runGit executes a git command in the given directory and returns combined output.
func runGit(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// resolveGitDir returns the path to the .git directory for a repo.
// Handles both regular repos (.git is a directory) and worktrees (.git is a file).
func resolveGitDir(repoPath string) (string, error) {
	gitPath := filepath.Join(repoPath, ".git")
	info, err := os.Stat(gitPath)
	if err != nil {
		return "", err
	}

	if info.IsDir() {
		return gitPath, nil
	}

	// .git is a file (worktree) — read the gitdir pointer
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
