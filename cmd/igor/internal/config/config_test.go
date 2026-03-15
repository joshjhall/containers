package config

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func testdataDir() string {
	_, filename, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(filename), "..", "..", "testdata")
}

func TestLoad_Minimal(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "minimal.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.SchemaVersion != 1 {
		t.Errorf("SchemaVersion = %d, want 1", cfg.SchemaVersion)
	}
	if cfg.ContainersDir != "containers" {
		t.Errorf("ContainersDir = %q, want %q", cfg.ContainersDir, "containers")
	}
	if cfg.Project.Name != "myapp" {
		t.Errorf("Project.Name = %q, want %q", cfg.Project.Name, "myapp")
	}
	if cfg.Project.Username != "developer" {
		t.Errorf("Project.Username = %q, want %q", cfg.Project.Username, "developer")
	}
	if cfg.Project.BaseImage != "debian:trixie-slim" {
		t.Errorf("Project.BaseImage = %q, want %q", cfg.Project.BaseImage, "debian:trixie-slim")
	}

	wantFeatures := []string{"python", "python_dev"}
	if len(cfg.Features) != len(wantFeatures) {
		t.Fatalf("Features length = %d, want %d", len(cfg.Features), len(wantFeatures))
	}
	for i, f := range wantFeatures {
		if cfg.Features[i] != f {
			t.Errorf("Features[%d] = %q, want %q", i, cfg.Features[i], f)
		}
	}
}

func TestLoad_Fullstack(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "fullstack.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.Project.Name != "fullstack" {
		t.Errorf("Project.Name = %q, want %q", cfg.Project.Name, "fullstack")
	}
	if cfg.Project.Username != "dev" {
		t.Errorf("Project.Username = %q, want %q", cfg.Project.Username, "dev")
	}
	if cfg.Project.BaseImage != "debian:bookworm-slim" {
		t.Errorf("Project.BaseImage = %q, want %q", cfg.Project.BaseImage, "debian:bookworm-slim")
	}

	// Should have 17 explicit features
	if len(cfg.Features) != 17 {
		t.Errorf("Features length = %d, want 17", len(cfg.Features))
	}

	// Spot-check a few features
	featureSet := make(map[string]bool)
	for _, f := range cfg.Features {
		featureSet[f] = true
	}
	for _, want := range []string{"python", "node", "rust", "golang", "dev_tools", "docker", "kubernetes", "ollama"} {
		if !featureSet[want] {
			t.Errorf("missing feature %q", want)
		}
	}
}

func TestSave_Roundtrip(t *testing.T) {
	original := &IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project: ProjectConfig{
			Name:      "roundtrip-test",
			Username:  "testuser",
			BaseImage: "debian:trixie-slim",
		},
		Features: []string{"python", "python_dev", "node"},
		Versions: map[string]string{
			"PYTHON_VERSION": "3.14.0",
			"NODE_VERSION":   "22.12.0",
		},
		Generated: map[string]string{
			".devcontainer/docker-compose.yml": "abc123",
			".igor.yml":                        "def456",
		},
	}

	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, ".igor.yml")

	if err := original.Save(path); err != nil {
		t.Fatalf("Save: %v", err)
	}

	reloaded, err := Load(path)
	if err != nil {
		t.Fatalf("Load after Save: %v", err)
	}

	if reloaded.SchemaVersion != original.SchemaVersion {
		t.Errorf("SchemaVersion = %d, want %d", reloaded.SchemaVersion, original.SchemaVersion)
	}
	if reloaded.ContainersDir != original.ContainersDir {
		t.Errorf("ContainersDir = %q, want %q", reloaded.ContainersDir, original.ContainersDir)
	}
	if reloaded.Project.Name != original.Project.Name {
		t.Errorf("Project.Name = %q, want %q", reloaded.Project.Name, original.Project.Name)
	}
	if reloaded.Project.Username != original.Project.Username {
		t.Errorf("Project.Username = %q, want %q", reloaded.Project.Username, original.Project.Username)
	}
	if reloaded.Project.BaseImage != original.Project.BaseImage {
		t.Errorf("Project.BaseImage = %q, want %q", reloaded.Project.BaseImage, original.Project.BaseImage)
	}

	if len(reloaded.Features) != len(original.Features) {
		t.Fatalf("Features length = %d, want %d", len(reloaded.Features), len(original.Features))
	}
	for i, f := range original.Features {
		if reloaded.Features[i] != f {
			t.Errorf("Features[%d] = %q, want %q", i, reloaded.Features[i], f)
		}
	}

	for k, v := range original.Versions {
		if reloaded.Versions[k] != v {
			t.Errorf("Versions[%q] = %q, want %q", k, reloaded.Versions[k], v)
		}
	}

	for k, v := range original.Generated {
		if reloaded.Generated[k] != v {
			t.Errorf("Generated[%q] = %q, want %q", k, reloaded.Generated[k], v)
		}
	}
}

func TestLoad_NonexistentFile(t *testing.T) {
	_, err := Load("/nonexistent/path/to/.igor.yml")
	if err == nil {
		t.Error("expected error loading nonexistent file, got nil")
	}
}

func TestLoad_MalformedYAML(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "bad.yml")
	if err := os.WriteFile(path, []byte(":\n  :\n    - [\ninvalid"), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	_, err := Load(path)
	if err == nil {
		t.Error("expected error loading malformed YAML, got nil")
	}
}

func TestLoad_EmptyFile(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "empty.yml")
	if err := os.WriteFile(path, []byte(""), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load empty file: %v", err)
	}
	// Empty YAML should produce zero-value config
	if cfg.SchemaVersion != 0 {
		t.Errorf("SchemaVersion = %d, want 0", cfg.SchemaVersion)
	}
	if len(cfg.Features) != 0 {
		t.Errorf("Features length = %d, want 0", len(cfg.Features))
	}
}

func TestSave_CreatesFile(t *testing.T) {
	cfg := &IgorConfig{
		SchemaVersion: 1,
		Features:      []string{"python"},
	}

	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "subdir", "config.yml")

	// Save should fail because subdir doesn't exist
	err := cfg.Save(path)
	if err == nil {
		t.Error("expected error saving to nonexistent directory, got nil")
	}
}
