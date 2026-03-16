package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
)

// executeAdd runs the add command with the given args in the current directory.
func executeAdd(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	// Reset flags
	addDev = false
	addDryRun = false

	rootCmd.SetArgs(append([]string{"add"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}

// setupAddTest creates a temp dir, runs igor init from a config, and returns the dir.
func setupAddTest(t *testing.T, configName string) string {
	t.Helper()
	tmpDir := executeInit(t, "--non-interactive", "--config", filepath.Join(testdataDir(), configName))
	return tmpDir
}

func TestAdd_NoIgorYML(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeAdd(t, "kubernetes")
	if err == nil {
		t.Fatal("expected error when no .igor.yml exists")
	}
	if !strings.Contains(err.Error(), "igor init") {
		t.Errorf("error should mention 'igor init', got: %v", err)
	}
}

func TestAdd_NoArgs(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeAdd(t)
	if err == nil {
		t.Fatal("expected error when no args given")
	}
}

func TestAdd_InvalidFeature(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	_, err := executeAdd(t, "nonexistent_feature")
	if err == nil {
		t.Fatal("expected error for unknown feature")
	}
	if !strings.Contains(err.Error(), "unknown feature") {
		t.Errorf("error should mention 'unknown feature', got: %v", err)
	}
}

func TestAdd_SingleFeature(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	out, err := executeAdd(t, "kubernetes")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "kubernetes") {
		t.Errorf("output should mention kubernetes, got: %s", out)
	}

	// Verify .igor.yml contains kubernetes
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if !featureSet["kubernetes"] {
		t.Error("kubernetes should be in .igor.yml features")
	}
	// Original features should still be present
	if !featureSet["python"] {
		t.Error("python should still be in .igor.yml features")
	}
	if !featureSet["python_dev"] {
		t.Error("python_dev should still be in .igor.yml features")
	}
}

func TestAdd_WithDev(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	out, err := executeAdd(t, "rust", "--dev")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "rust") {
		t.Errorf("output should mention rust, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if !featureSet["rust"] {
		t.Error("rust should be in .igor.yml features")
	}
	if !featureSet["rust_dev"] {
		t.Error("rust_dev should be in .igor.yml features")
	}
}

func TestAdd_DependencyResolution(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	out, err := executeAdd(t, "kotlin")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// kotlin requires java, so java should be auto-resolved
	if !strings.Contains(out, "java") {
		t.Errorf("output should mention java as auto-resolved, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if !featureSet["kotlin"] {
		t.Error("kotlin should be in .igor.yml features")
	}

	// java should be in versions (auto-resolved gets default version)
	if cfg.Versions == nil {
		t.Fatal("expected versions to be populated")
	}
	if _, ok := cfg.Versions["KOTLIN_VERSION"]; !ok {
		t.Error("KOTLIN_VERSION should be set")
	}
}

func TestAdd_AlreadyEnabled(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	out, err := executeAdd(t, "python")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "already enabled") {
		t.Errorf("output should say already enabled, got: %s", out)
	}
	if !strings.Contains(out, "Nothing to add") {
		t.Errorf("output should say nothing to add, got: %s", out)
	}
}

func TestAdd_DryRun(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	// Read .igor.yml before dry-run
	beforeData, err := os.ReadFile(".igor.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	out, err := executeAdd(t, "kubernetes", "--dry-run")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "Would add") {
		t.Errorf("dry-run output should say 'Would add', got: %s", out)
	}

	// Verify .igor.yml is unchanged
	afterData, err := os.ReadFile(".igor.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(beforeData) != string(afterData) {
		t.Error(".igor.yml should not be modified during dry-run")
	}
}

func TestAdd_MultipleFeatures(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	out, err := executeAdd(t, "kubernetes", "docker")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "kubernetes") || !strings.Contains(out, "docker") {
		t.Errorf("output should mention both features, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if !featureSet["kubernetes"] {
		t.Error("kubernetes should be in .igor.yml features")
	}
	if !featureSet["docker"] {
		t.Error("docker should be in .igor.yml features")
	}
}

func TestAdd_FilesRegenerated(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	// Read docker-compose before add
	composeBefore, err := os.ReadFile(".devcontainer/docker-compose.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	_, err = executeAdd(t, "docker")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	composeAfter, err := os.ReadFile(".devcontainer/docker-compose.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	// docker-compose.yml should have changed to include docker build arg
	if string(composeBefore) == string(composeAfter) {
		t.Error("docker-compose.yml should have changed after adding docker feature")
	}
	if !strings.Contains(string(composeAfter), "INCLUDE_DOCKER") {
		t.Error("docker-compose.yml should contain INCLUDE_DOCKER after adding docker")
	}
}

func TestAdd_DevFlagNoDevCompanion(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	// kubernetes has no _dev companion
	_, err := executeAdd(t, "kubernetes", "--dev")
	if err == nil {
		t.Fatal("expected error for --dev with feature that has no dev companion")
	}
	if !strings.Contains(err.Error(), "no dev companion") {
		t.Errorf("error should mention 'no dev companion', got: %v", err)
	}
}

func TestAdd_PreservesExistingVersions(t *testing.T) {
	setupAddTest(t, "minimal.igor.yml")

	// Load original config to get python version
	cfgBefore, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	pythonVersion := cfgBefore.Versions["PYTHON_VERSION"]

	_, err = executeAdd(t, "kubernetes")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	cfgAfter, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfgAfter.Versions["PYTHON_VERSION"] != pythonVersion {
		t.Errorf("PYTHON_VERSION changed from %q to %q", pythonVersion, cfgAfter.Versions["PYTHON_VERSION"])
	}
}
