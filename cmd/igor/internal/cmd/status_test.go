package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func executeStatus(t *testing.T) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	rootCmd.SetArgs([]string{"status"})
	err := rootCmd.Execute()
	return buf.String(), err
}

func TestStatus_NoIgorYML(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	_, err = executeStatus(t)
	if err == nil {
		t.Error("expected error when no .igor.yml exists")
	}
}

func TestStatus_CleanProject(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	executeInit(t, "--non-interactive", "--config", cfgPath)

	out, err := executeStatus(t)
	if err != nil {
		t.Fatalf("status returned error on clean project: %v", err)
	}

	if strings.Contains(out, "modified") {
		t.Error("clean project should not show modified files")
	}
	if strings.Contains(out, "missing") {
		t.Error("clean project should not show missing files")
	}
}

func TestStatus_ModifiedFile(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Modify a generated file
	envPath := filepath.Join(tmpDir, ".devcontainer/.env")
	if err := os.WriteFile(envPath, []byte("# user edit\n"), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	out, err := executeStatus(t)
	if err == nil {
		t.Error("expected error when drift detected")
	}
	if !strings.Contains(out, "modified") {
		t.Error("output should show 'modified' for changed file")
	}
}

func TestStatus_MissingFile(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Delete a generated file
	envPath := filepath.Join(tmpDir, ".devcontainer/.env")
	if err := os.Remove(envPath); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	out, err := executeStatus(t)
	if err == nil {
		t.Error("expected error when drift detected")
	}
	if !strings.Contains(out, "missing") {
		t.Error("output should show 'missing' for deleted file")
	}
}

func TestStatus_ShowsFeatures(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	executeInit(t, "--non-interactive", "--config", cfgPath)

	out, err := executeStatus(t)
	if err != nil {
		t.Fatalf("status: %v", err)
	}

	// minimal config has python and python_dev
	if !strings.Contains(out, "python") {
		t.Error("output should contain 'python'")
	}
	if !strings.Contains(out, "python_dev") {
		t.Error("output should contain 'python_dev'")
	}
	// Should show version for python
	if !strings.Contains(out, "3.14.0") {
		t.Error("output should show python version")
	}
}

func TestStatus_ShowsAutoFeatures(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	executeInit(t, "--non-interactive", "--config", cfgPath)

	out, err := executeStatus(t)
	if err != nil {
		t.Fatalf("status: %v", err)
	}

	// python_dev requires python, both are explicit in minimal config
	// Check the features header shows counts
	if !strings.Contains(out, "Features (") {
		t.Error("output should contain features summary line")
	}
	if !strings.Contains(out, "explicit") {
		t.Error("output should mention 'explicit' in features summary")
	}
}

func TestStatus_ProjectHeader(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	executeInit(t, "--non-interactive", "--config", cfgPath)

	out, err := executeStatus(t)
	if err != nil {
		t.Fatalf("status: %v", err)
	}

	if !strings.Contains(out, "myapp") {
		t.Error("output should contain project name 'myapp'")
	}
	if !strings.Contains(out, "developer") {
		t.Error("output should contain username 'developer'")
	}
	if !strings.Contains(out, "debian:trixie-slim") {
		t.Error("output should contain base image")
	}
}
