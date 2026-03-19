package cmd

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/generate"
)

// setupAndUpdate runs init with the given config fixture, then runs update
// with the given args. Returns the temp directory.
func setupAndUpdate(t *testing.T, configFixture string, updateArgs ...string) string {
	t.Helper()

	// First run init
	tmpDir := executeInit(t, "--non-interactive", "--config", configFixture)

	// Reset flags before update
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	// Run update
	rootCmd.SetArgs(append([]string{"update"}, updateArgs...))
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update Execute: %v", err)
	}

	return tmpDir
}

func TestUpdate_NoIgorYML(t *testing.T) {
	tmpDir := t.TempDir()
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	defer os.Chdir(origDir)

	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	err = rootCmd.Execute()
	if err == nil {
		t.Error("expected error when no .igor.yml exists")
	}
}

func TestUpdate_Idempotent(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Load hashes after init
	initCfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load after init: %v", err)
	}
	initHashes := initCfg.Generated

	// Reset and run update
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	// Load hashes after update
	updateCfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load after update: %v", err)
	}
	updateHashes := updateCfg.Generated

	// Hashes should be identical
	if len(initHashes) != len(updateHashes) {
		t.Errorf("hash count changed: %d → %d", len(initHashes), len(updateHashes))
	}
	for path, initHash := range initHashes {
		if updateHash, ok := updateHashes[path]; !ok {
			t.Errorf("missing hash for %s after update", path)
		} else if initHash != updateHash {
			t.Errorf("hash changed for %s: %s → %s", path, initHash, updateHash)
		}
	}
}

func TestUpdate_PreservesConfig(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := setupAndUpdate(t, cfgPath)

	cfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.Project.Name != "myapp" {
		t.Errorf("Project.Name = %q, want %q", cfg.Project.Name, "myapp")
	}
	if cfg.Project.Username != "developer" {
		t.Errorf("Project.Username = %q, want %q", cfg.Project.Username, "developer")
	}
	if cfg.ContainersDir != "containers" {
		t.Errorf("ContainersDir = %q, want %q", cfg.ContainersDir, "containers")
	}

	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	if !featureSet["python"] {
		t.Error("missing feature 'python'")
	}
	if !featureSet["python_dev"] {
		t.Error("missing feature 'python_dev'")
	}
}

func TestUpdate_SkipsModifiedFiles(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Modify docker-compose.yml
	composePath := filepath.Join(tmpDir, ".devcontainer/docker-compose.yml")
	original, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	modified := string(original) + "\n# user edit\n"
	if err := os.WriteFile(composePath, []byte(modified), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	// Reset and run update
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	// File should NOT be overwritten
	afterUpdate, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("ReadFile after update: %v", err)
	}
	if string(afterUpdate) != modified {
		t.Error("modified docker-compose.yml was overwritten without --force")
	}
}

func TestUpdate_ForceOverwritesModified(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Modify docker-compose.yml
	composePath := filepath.Join(tmpDir, ".devcontainer/docker-compose.yml")
	original, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	modified := string(original) + "\n# user edit\n"
	if err := os.WriteFile(composePath, []byte(modified), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	// Reset and run update with --force
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update", "--force"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update --force: %v", err)
	}

	// File SHOULD be overwritten (back to original template output)
	afterUpdate, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("ReadFile after force update: %v", err)
	}
	if string(afterUpdate) == modified {
		t.Error("--force did not overwrite user-modified file")
	}
}

func TestUpdate_UpdatesContainersRef(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Create a fake containers/VERSION file
	containersDir := filepath.Join(tmpDir, "containers")
	if err := os.MkdirAll(containersDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(containersDir, "VERSION"), []byte("v4.15.8\n"), 0644); err != nil {
		t.Fatalf("WriteFile VERSION: %v", err)
	}

	// Reset and run update
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	cfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.ContainersRef != "v4.15.8" {
		t.Errorf("ContainersRef = %q, want %q", cfg.ContainersRef, "v4.15.8")
	}
}

func TestUpdate_HashesMatchDisk(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := setupAndUpdate(t, cfgPath)

	cfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Check every non-.igor.yml generated file
	for path, expectedHash := range cfg.Generated {
		if path == ".igor.yml" {
			continue // .igor.yml is overwritten by state.Save()
		}
		fullPath := filepath.Join(tmpDir, path)
		data, err := os.ReadFile(fullPath)
		if err != nil {
			t.Errorf("ReadFile(%s): %v", path, err)
			continue
		}
		diskHash := fmt.Sprintf("%x", sha256.Sum256(data))
		if diskHash != expectedHash {
			t.Errorf("hash mismatch for %s: disk=%s, recorded=%s", path, diskHash, expectedHash)
		}
	}
}

func TestUpdate_SkippedFileHashPreserved(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Get the original hash for docker-compose.yml
	initCfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load after init: %v", err)
	}
	origHash := initCfg.Generated[".devcontainer/docker-compose.yml"]

	// Modify docker-compose.yml
	composePath := filepath.Join(tmpDir, ".devcontainer/docker-compose.yml")
	original, err := os.ReadFile(composePath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if err := os.WriteFile(composePath, []byte(string(original)+"\n# user edit\n"), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	// Reset and run update (no --force)
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	// The old hash should be preserved for the skipped file
	updateCfg, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load after update: %v", err)
	}

	preservedHash := updateCfg.Generated[".devcontainer/docker-compose.yml"]
	if preservedHash != origHash {
		t.Errorf("skipped file hash changed: %s → %s (should be preserved)", origHash, preservedHash)
	}
}

func TestUpdate_CreatesDeletedFile(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")

	// Run init
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Delete a generated file
	envPath := filepath.Join(tmpDir, ".devcontainer/.env")
	if err := os.Remove(envPath); err != nil {
		t.Fatalf("Remove: %v", err)
	}

	// Reset and run update
	nonInteractive = false
	configFile = ""
	forceUpdate = false

	rootCmd.SetArgs([]string{"update"})
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("update: %v", err)
	}

	// File should be re-created
	if _, err := os.Stat(envPath); err != nil {
		t.Errorf("deleted file was not re-created: %v", err)
	}
}

func TestUpdate_ForceFlag(t *testing.T) {
	// Verify --force is a valid flag and defaults to false
	flag := updateCmd.Flags().Lookup("force")
	if flag == nil {
		t.Fatal("--force flag not registered")
	}
	if flag.DefValue != "false" {
		t.Errorf("--force default = %q, want %q", flag.DefValue, "false")
	}
}

func TestHashContent_MatchesWriteFiles(t *testing.T) {
	tmpDir := t.TempDir()
	content := "test content for hashing"

	// Hash via HashContent
	hashDirect := generate.HashContent(content)

	// Hash via WriteFiles
	entries := []generate.FileEntry{
		{Path: filepath.Join(tmpDir, "test.txt"), Content: content},
	}
	hashes, err := generate.WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles: %v", err)
	}

	hashFromWrite := hashes[entries[0].Path]
	if hashDirect != hashFromWrite {
		t.Errorf("HashContent = %q, WriteFiles hash = %q", hashDirect, hashFromWrite)
	}
}
