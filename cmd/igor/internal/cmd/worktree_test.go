package cmd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"gopkg.in/yaml.v3"
)

// executeWorktreeCreate runs "igor worktree create" with the given args.
func executeWorktreeCreate(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	// Reset flags
	worktreeDryRun = false

	rootCmd.SetArgs(append([]string{"worktree", "create"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}

// initBareRepo creates a git repo at dir with an initial commit.
func initBareRepo(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	cmds := [][]string{
		{"git", "init"},
		{"git", "config", "user.email", "test@test.com"},
		{"git", "config", "user.name", "Test"},
		{"git", "commit", "--allow-empty", "-m", "init"},
	}
	for _, c := range cmds {
		cmd := exec.Command(c[0], c[1:]...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git command %v failed: %v\n%s", c, err, out)
		}
	}
}

// setupWorktreeTest creates a temp base dir with a git repo and .igor.yml,
// then chdir into the repo. Returns the base dir.
func setupWorktreeTest(t *testing.T, cfg *igorconfig.IgorConfig) string {
	t.Helper()

	baseDir := t.TempDir()
	repoDir := filepath.Join(baseDir, cfg.Project.Name)
	initBareRepo(t, repoDir)

	// Override WorkingDir to point to our temp base
	cfg.Project.WorkingDir = filepath.Join(baseDir, cfg.Project.Name)

	// Write .igor.yml into the repo
	data, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(repoDir, ".igor.yml"), data, 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(repoDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { os.Chdir(origDir) })

	return baseDir
}

func TestWorktreeCreate_Basic(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	baseDir := setupWorktreeTest(t, cfg)

	out, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "myproject-agent01: created") {
		t.Errorf("expected creation message, got: %s", out)
	}

	worktreeDir := filepath.Join(baseDir, "myproject-agent01")

	// Verify directory exists
	if _, err := os.Stat(worktreeDir); os.IsNotExist(err) {
		t.Fatal("worktree directory should exist")
	}

	// Verify .git file content
	gitContent, err := os.ReadFile(filepath.Join(worktreeDir, ".git"))
	if err != nil {
		t.Fatalf("ReadFile .git: %v", err)
	}
	gitStr := strings.TrimSpace(string(gitContent))
	if !strings.Contains(gitStr, "gitdir:") {
		t.Errorf(".git file should contain gitdir pointer, got: %s", gitStr)
	}
	mainGitDir := filepath.Join(baseDir, "myproject", ".git")
	expectedGitdir := "gitdir: " + mainGitDir + "/worktrees/myproject-agent01"
	if gitStr != expectedGitdir {
		t.Errorf(".git content = %q, want %q", gitStr, expectedGitdir)
	}

	// Verify gitdir file in main repo points back
	gitdirPath := filepath.Join(mainGitDir, "worktrees", "myproject-agent01", "gitdir")
	gitdirContent, err := os.ReadFile(gitdirPath)
	if err != nil {
		t.Fatalf("ReadFile gitdir: %v", err)
	}
	expectedPath := filepath.Join(baseDir, "myproject-agent01", ".git")
	if strings.TrimSpace(string(gitdirContent)) != expectedPath {
		t.Errorf("gitdir content = %q, want %q", strings.TrimSpace(string(gitdirContent)), expectedPath)
	}

	// Verify branch was created
	gitOut, gitErr := runGit(filepath.Join(baseDir, "myproject"), "rev-parse", "--verify", "agent01")
	if gitErr != nil {
		t.Errorf("branch agent01 should exist, got error: %v (%s)", gitErr, gitOut)
	}
}

func TestWorktreeCreate_Idempotent(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	setupWorktreeTest(t, cfg)

	// First create
	_, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("first create failed: %v", err)
	}

	// Second create should say "already exists"
	out, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("second create failed: %v", err)
	}
	if !strings.Contains(out, "already exists") {
		t.Errorf("expected 'already exists', got: %s", out)
	}
}

func TestWorktreeCreate_InvalidN(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	setupWorktreeTest(t, cfg)

	tests := []struct {
		arg     string
		wantErr string
	}{
		{"0", "between 1 and 5"},
		{"abc", "must be an integer"},
		{"6", "between 1 and 5"},
	}

	for _, tt := range tests {
		t.Run(tt.arg, func(t *testing.T) {
			_, err := executeWorktreeCreate(t, tt.arg)
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error %q should contain %q", err.Error(), tt.wantErr)
			}
		})
	}
}

func TestWorktreeCreate_NoIgorYML(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeWorktreeCreate(t, "1")
	if err == nil {
		t.Fatal("expected error when no .igor.yml exists")
	}
	if !strings.Contains(err.Error(), "igor init") {
		t.Errorf("error should mention 'igor init', got: %v", err)
	}
}

func TestWorktreeCreate_ExistingBranch(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	baseDir := setupWorktreeTest(t, cfg)

	// Pre-create the branch
	repoDir := filepath.Join(baseDir, "myproject")
	if _, err := runGit(repoDir, "branch", "agent01"); err != nil {
		t.Fatalf("pre-creating branch: %v", err)
	}

	out, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "created") {
		t.Errorf("expected creation message, got: %s", out)
	}
}

func TestWorktreeCreate_CustomMax(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Max: 3},
	}
	setupWorktreeTest(t, cfg)

	// N=3 should work
	_, err := executeWorktreeCreate(t, "3")
	if err != nil {
		t.Fatalf("N=3 should succeed with max=3: %v", err)
	}

	// N=4 should fail
	_, err = executeWorktreeCreate(t, "4")
	if err == nil {
		t.Fatal("N=4 should fail with max=3")
	}
	if !strings.Contains(err.Error(), "between 1 and 3") {
		t.Errorf("error should mention max 3, got: %v", err)
	}
}

func TestWorktreeCreate_DryRun(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	baseDir := setupWorktreeTest(t, cfg)

	out, err := executeWorktreeCreate(t, "1", "--dry-run")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "Would create") {
		t.Errorf("expected dry-run message, got: %s", out)
	}

	// Verify no directory was created
	worktreeDir := filepath.Join(baseDir, "myproject-agent01")
	if _, err := os.Stat(worktreeDir); !os.IsNotExist(err) {
		t.Error("worktree directory should not exist in dry-run mode")
	}
}

func TestWorktreeCreate_MultiRepo(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "primary", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Repos: []string{"primary", "secondary"}},
	}
	baseDir := setupWorktreeTest(t, cfg)

	// Create the secondary repo too
	initBareRepo(t, filepath.Join(baseDir, "secondary"))

	out, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "primary-agent01: created") {
		t.Errorf("expected primary worktree creation, got: %s", out)
	}
	if !strings.Contains(out, "secondary-agent01: created") {
		t.Errorf("expected secondary worktree creation, got: %s", out)
	}

	// Verify both directories exist
	for _, repo := range []string{"primary", "secondary"} {
		dir := filepath.Join(baseDir, repo+"-agent01")
		if _, err := os.Stat(dir); os.IsNotExist(err) {
			t.Errorf("worktree directory %s should exist", dir)
		}
	}
}

func TestWorktreeCreate_MissingSiblingRepo(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		Project:       igorconfig.ProjectConfig{Name: "primary", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Repos: []string{"primary", "missing"}},
	}
	baseDir := setupWorktreeTest(t, cfg)

	out, err := executeWorktreeCreate(t, "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should warn about missing repo
	if !strings.Contains(out, "missing: main repo not found") {
		t.Errorf("expected warning about missing repo, got: %s", out)
	}

	// Primary should still be created
	if !strings.Contains(out, "primary-agent01: created") {
		t.Errorf("primary worktree should still be created, got: %s", out)
	}

	// Verify primary directory exists
	dir := filepath.Join(baseDir, "primary-agent01")
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		t.Error("primary worktree directory should exist")
	}
}

// --- detectWorktreeMounts tests ---

func TestDetectWorktreeMounts(t *testing.T) {
	baseDir := t.TempDir()

	// Create some fake worktree directories.
	os.MkdirAll(filepath.Join(baseDir, "myapp-agent01"), 0755)
	os.MkdirAll(filepath.Join(baseDir, "myapp-agent03"), 0755)

	mounts := detectWorktreeMounts([]string{"myapp"}, 5, baseDir)

	if len(mounts) != 2 {
		t.Fatalf("expected 2 mounts, got %d: %v", len(mounts), mounts)
	}
	if !strings.Contains(mounts[0], "myapp-agent01") {
		t.Errorf("expected agent01 mount, got: %s", mounts[0])
	}
	if !strings.Contains(mounts[1], "myapp-agent03") {
		t.Errorf("expected agent03 mount, got: %s", mounts[1])
	}
}

func TestDetectWorktreeMounts_NoWorktrees(t *testing.T) {
	baseDir := t.TempDir()
	mounts := detectWorktreeMounts([]string{"myapp"}, 5, baseDir)
	if len(mounts) != 0 {
		t.Errorf("expected 0 mounts, got %d: %v", len(mounts), mounts)
	}
}

func TestDetectWorktreeMounts_MultiRepo(t *testing.T) {
	baseDir := t.TempDir()

	os.MkdirAll(filepath.Join(baseDir, "app-agent01"), 0755)
	os.MkdirAll(filepath.Join(baseDir, "lib-agent01"), 0755)

	mounts := detectWorktreeMounts([]string{"app", "lib"}, 3, baseDir)

	if len(mounts) != 2 {
		t.Fatalf("expected 2 mounts, got %d: %v", len(mounts), mounts)
	}
}

// --- worktree remove tests ---

func executeWorktreeRemove(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	rootCmd.SetArgs(append([]string{"worktree", "remove"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}
