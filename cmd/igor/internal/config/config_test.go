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

func TestLoad_WithAgents(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "agents.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if cfg.Agents.Max != 3 {
		t.Errorf("Agents.Max = %d, want 3", cfg.Agents.Max)
	}
	if cfg.Agents.Username != "worker" {
		t.Errorf("Agents.Username = %q, want %q", cfg.Agents.Username, "worker")
	}
	if cfg.Agents.Network != "myapp-dev-network" {
		t.Errorf("Agents.Network = %q, want %q", cfg.Agents.Network, "myapp-dev-network")
	}
	if cfg.Agents.ImageTag != "v2.0" {
		t.Errorf("Agents.ImageTag = %q, want %q", cfg.Agents.ImageTag, "v2.0")
	}

	wantVols := []string{"pip-cache:/cache/pip", "npm-cache:/cache/npm"}
	if len(cfg.Agents.SharedVolumes) != len(wantVols) {
		t.Fatalf("SharedVolumes length = %d, want %d", len(cfg.Agents.SharedVolumes), len(wantVols))
	}
	for i, v := range wantVols {
		if cfg.Agents.SharedVolumes[i] != v {
			t.Errorf("SharedVolumes[%d] = %q, want %q", i, cfg.Agents.SharedVolumes[i], v)
		}
	}

	wantRepos := []string{"myapp", "myapp-frontend"}
	if len(cfg.Agents.Repos) != len(wantRepos) {
		t.Fatalf("Repos length = %d, want %d", len(cfg.Agents.Repos), len(wantRepos))
	}
	for i, r := range wantRepos {
		if cfg.Agents.Repos[i] != r {
			t.Errorf("Repos[%d] = %q, want %q", i, cfg.Agents.Repos[i], r)
		}
	}
}

func TestLoad_WithoutAgents(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "minimal.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if !cfg.Agents.IsZero() {
		t.Errorf("Agents should be zero-value for minimal config, got %+v", cfg.Agents)
	}
}

func TestAgentDefaults(t *testing.T) {
	cacheVols := []string{"pip-cache:/cache/pip", "npm-cache:/cache/npm"}
	defaults := AgentDefaults("myproject", cacheVols)

	if defaults.Max != 5 {
		t.Errorf("Max = %d, want 5", defaults.Max)
	}
	if defaults.Username != "agent" {
		t.Errorf("Username = %q, want %q", defaults.Username, "agent")
	}
	if defaults.Network != "myproject-network" {
		t.Errorf("Network = %q, want %q", defaults.Network, "myproject-network")
	}
	if defaults.ImageTag != "latest" {
		t.Errorf("ImageTag = %q, want %q", defaults.ImageTag, "latest")
	}
	if len(defaults.SharedVolumes) != len(cacheVols) {
		t.Fatalf("SharedVolumes length = %d, want %d", len(defaults.SharedVolumes), len(cacheVols))
	}
	for i, v := range cacheVols {
		if defaults.SharedVolumes[i] != v {
			t.Errorf("SharedVolumes[%d] = %q, want %q", i, defaults.SharedVolumes[i], v)
		}
	}
	if len(defaults.Repos) != 0 {
		t.Errorf("Repos length = %d, want 0", len(defaults.Repos))
	}
}

func TestAgentDefaults_NilCacheVolumes(t *testing.T) {
	defaults := AgentDefaults("proj", nil)

	if defaults.SharedVolumes != nil {
		t.Errorf("SharedVolumes = %v, want nil", defaults.SharedVolumes)
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
		Agents: AgentConfig{
			Max:           3,
			Username:      "worker",
			Network:       "roundtrip-network",
			ImageTag:      "v1.0",
			SharedVolumes: []string{"pip-cache:/cache/pip"},
			Repos:         []string{"myrepo"},
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

	if reloaded.Agents.Max != original.Agents.Max {
		t.Errorf("Agents.Max = %d, want %d", reloaded.Agents.Max, original.Agents.Max)
	}
	if reloaded.Agents.Username != original.Agents.Username {
		t.Errorf("Agents.Username = %q, want %q", reloaded.Agents.Username, original.Agents.Username)
	}
	if reloaded.Agents.Network != original.Agents.Network {
		t.Errorf("Agents.Network = %q, want %q", reloaded.Agents.Network, original.Agents.Network)
	}
	if reloaded.Agents.ImageTag != original.Agents.ImageTag {
		t.Errorf("Agents.ImageTag = %q, want %q", reloaded.Agents.ImageTag, original.Agents.ImageTag)
	}
	if len(reloaded.Agents.SharedVolumes) != len(original.Agents.SharedVolumes) {
		t.Fatalf("Agents.SharedVolumes length = %d, want %d", len(reloaded.Agents.SharedVolumes), len(original.Agents.SharedVolumes))
	}
	for i, v := range original.Agents.SharedVolumes {
		if reloaded.Agents.SharedVolumes[i] != v {
			t.Errorf("Agents.SharedVolumes[%d] = %q, want %q", i, reloaded.Agents.SharedVolumes[i], v)
		}
	}
	if len(reloaded.Agents.Repos) != len(original.Agents.Repos) {
		t.Fatalf("Agents.Repos length = %d, want %d", len(reloaded.Agents.Repos), len(original.Agents.Repos))
	}
	for i, r := range original.Agents.Repos {
		if reloaded.Agents.Repos[i] != r {
			t.Errorf("Agents.Repos[%d] = %q, want %q", i, reloaded.Agents.Repos[i], r)
		}
	}
}

func TestLoad_WithServices(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "services.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	if len(cfg.Services) != 2 {
		t.Fatalf("Services length = %d, want 2", len(cfg.Services))
	}

	pg, ok := cfg.Services["postgres"]
	if !ok {
		t.Fatal("missing 'postgres' service")
	}
	if pg.Image != "postgres:16" {
		t.Errorf("postgres.Image = %q, want %q", pg.Image, "postgres:16")
	}
	if pg.Port != 5432 {
		t.Errorf("postgres.Port = %d, want 5432", pg.Port)
	}
	if !pg.PerAgentDB {
		t.Error("postgres.PerAgentDB should be true")
	}
	if len(pg.Environment) != 2 {
		t.Errorf("postgres.Environment length = %d, want 2", len(pg.Environment))
	}
	if len(pg.Volumes) != 1 {
		t.Errorf("postgres.Volumes length = %d, want 1", len(pg.Volumes))
	}

	redis, ok := cfg.Services["redis"]
	if !ok {
		t.Fatal("missing 'redis' service")
	}
	if redis.Image != "redis:7" {
		t.Errorf("redis.Image = %q, want %q", redis.Image, "redis:7")
	}
	if redis.Port != 6379 {
		t.Errorf("redis.Port = %d, want 6379", redis.Port)
	}
	if redis.PerAgentDB {
		t.Error("redis.PerAgentDB should be false")
	}
}

func TestLoad_WithoutServices(t *testing.T) {
	cfg, err := Load(filepath.Join(testdataDir(), "minimal.igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(cfg.Services) != 0 {
		t.Errorf("Services should be empty for minimal config, got %d", len(cfg.Services))
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
