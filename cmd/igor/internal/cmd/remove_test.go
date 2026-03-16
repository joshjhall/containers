package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
)

// executeRemove runs the remove command with the given args in the current directory.
func executeRemove(t *testing.T, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	// Reset flags
	removeCascade = false
	removeDevOnly = false
	removeDryRun = false

	rootCmd.SetArgs(append([]string{"remove"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}

// setupRemoveTest creates a temp dir, runs igor init from a config, and returns the dir.
func setupRemoveTest(t *testing.T, configName string) string {
	t.Helper()
	tmpDir := executeInit(t, "--non-interactive", "--config", filepath.Join(testdataDir(), configName))
	return tmpDir
}

func TestRemove_NoIgorYML(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeRemove(t, "kubernetes")
	if err == nil {
		t.Fatal("expected error when no .igor.yml exists")
	}
	if !strings.Contains(err.Error(), "igor init") {
		t.Errorf("error should mention 'igor init', got: %v", err)
	}
}

func TestRemove_NoArgs(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeRemove(t)
	if err == nil {
		t.Fatal("expected error when no args given")
	}
}

func TestRemove_InvalidFeature(t *testing.T) {
	setupRemoveTest(t, "minimal.igor.yml")

	_, err := executeRemove(t, "nonexistent_feature")
	if err == nil {
		t.Fatal("expected error for unknown feature")
	}
	if !strings.Contains(err.Error(), "unknown feature") {
		t.Errorf("error should mention 'unknown feature', got: %v", err)
	}
}

func TestRemove_NotEnabled(t *testing.T) {
	setupRemoveTest(t, "minimal.igor.yml")

	_, err := executeRemove(t, "kubernetes")
	if err == nil {
		t.Fatal("expected error when feature is not enabled")
	}
	if !strings.Contains(err.Error(), "not currently enabled") {
		t.Errorf("error should mention 'not currently enabled', got: %v", err)
	}
}

func TestRemove_SingleFeature(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	out, err := executeRemove(t, "kubernetes")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "kubernetes") {
		t.Errorf("output should mention kubernetes, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if featureSet["kubernetes"] {
		t.Error("kubernetes should not be in .igor.yml features after removal")
	}
	// Other features should still be present
	if !featureSet["python"] {
		t.Error("python should still be in .igor.yml features")
	}
	if !featureSet["docker"] {
		t.Error("docker should still be in .igor.yml features")
	}
}

func TestRemove_DevOnly(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	out, err := executeRemove(t, "python", "--dev-only")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "python_dev") {
		t.Errorf("output should mention python_dev, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if featureSet["python_dev"] {
		t.Error("python_dev should not be in .igor.yml features after --dev-only removal")
	}
	if !featureSet["python"] {
		t.Error("python should still be in .igor.yml features after --dev-only removal")
	}
}

func TestRemove_DevOnlyNoDevCompanion(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	_, err := executeRemove(t, "kubernetes", "--dev-only")
	if err == nil {
		t.Fatal("expected error for --dev-only on feature with no dev companion")
	}
	if !strings.Contains(err.Error(), "no dev companion") {
		t.Errorf("error should mention 'no dev companion', got: %v", err)
	}
}

func TestRemove_BlockedByDependency(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// python is required by python_dev; should be blocked
	_, err := executeRemove(t, "python")
	if err == nil {
		t.Fatal("expected error when dependent exists")
	}
	if !strings.Contains(err.Error(), "required by") {
		t.Errorf("error should mention 'required by', got: %v", err)
	}
	if !strings.Contains(err.Error(), "--cascade") {
		t.Errorf("error should mention '--cascade', got: %v", err)
	}
}

func TestRemove_Cascade(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// Removing python with --cascade should also remove python_dev
	out, err := executeRemove(t, "python", "--cascade")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "python") {
		t.Errorf("output should mention python, got: %s", out)
	}

	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load .igor.yml: %v", err)
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if featureSet["python"] {
		t.Error("python should not be in .igor.yml features")
	}
	if featureSet["python_dev"] {
		t.Error("python_dev should not be in .igor.yml features")
	}
	// Other features should remain
	if !featureSet["node"] {
		t.Error("node should still be in .igor.yml features")
	}
}

func TestRemove_AutoDepsCleanup(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// First add kotlin (which auto-resolves java)
	_, err := executeAdd(t, "kotlin")
	if err != nil {
		t.Fatalf("failed to add kotlin: %v", err)
	}

	// Verify java is auto-resolved (not explicit)
	cfg, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	// java is in fullstack config explicitly, so let's use a different approach:
	// Remove kotlin — java should remain since it's explicit in fullstack

	// Actually test with a minimal config: add kotlin, then remove it
	// Reset: use minimal config
	setupRemoveTest(t, "minimal.igor.yml")

	_, err = executeAdd(t, "kotlin")
	if err != nil {
		t.Fatalf("failed to add kotlin: %v", err)
	}

	// Now remove kotlin — auto-resolved java should drop
	out, err := executeRemove(t, "kotlin")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "java") {
		t.Errorf("output should mention dropped auto-resolved java, got: %s", out)
	}

	cfg, err = igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	featureSet = make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if featureSet["kotlin"] {
		t.Error("kotlin should not be in features")
	}
	if featureSet["java"] {
		t.Error("java should not be in features (was auto-resolved)")
	}
}

func TestRemove_DryRun(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// Read .igor.yml before dry-run
	beforeData, err := os.ReadFile(".igor.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	out, err := executeRemove(t, "kubernetes", "--dry-run")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "Would remove") {
		t.Errorf("dry-run output should say 'Would remove', got: %s", out)
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

func TestRemove_FilesRegenerated(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// Read docker-compose before remove
	composeBefore, err := os.ReadFile(".devcontainer/docker-compose.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	_, err = executeRemove(t, "docker")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	composeAfter, err := os.ReadFile(".devcontainer/docker-compose.yml")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	if string(composeBefore) == string(composeAfter) {
		t.Error("docker-compose.yml should have changed after removing docker feature")
	}
	if strings.Contains(string(composeAfter), "INCLUDE_DOCKER") {
		t.Error("docker-compose.yml should not contain INCLUDE_DOCKER after removing docker")
	}
}

func TestRemove_VersionCleanup(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	// Verify rust version exists before removal
	cfgBefore, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if _, ok := cfgBefore.Versions["RUST_VERSION"]; !ok {
		t.Fatal("RUST_VERSION should exist before removal")
	}

	// Remove rust (which also removes rust_dev via dev companion auto-removal)
	_, err = executeRemove(t, "rust", "--cascade")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	cfgAfter, err := igorconfig.Load(".igor.yml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if _, ok := cfgAfter.Versions["RUST_VERSION"]; ok {
		t.Error("RUST_VERSION should be removed after removing rust")
	}
	// Python version should still exist
	if _, ok := cfgAfter.Versions["PYTHON_VERSION"]; !ok {
		t.Error("PYTHON_VERSION should still exist")
	}
}

func TestRemove_MultipleFeatures(t *testing.T) {
	setupRemoveTest(t, "fullstack.igor.yml")

	out, err := executeRemove(t, "kubernetes", "docker")
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
	if featureSet["kubernetes"] {
		t.Error("kubernetes should not be in .igor.yml features")
	}
	if featureSet["docker"] {
		t.Error("docker should not be in .igor.yml features")
	}
}
