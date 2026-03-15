package cmd

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"gopkg.in/yaml.v3"
)

func testdataDir() string {
	_, filename, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(filename), "..", "..", "testdata")
}

// executeInit runs the init command with the given args in a temp directory.
func executeInit(t *testing.T, args ...string) string {
	t.Helper()
	tmpDir := t.TempDir()

	// Save and restore working directory
	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(tmpDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { os.Chdir(origDir) })

	// Reset package-level state before each run
	nonInteractive = false
	configFile = ""

	rootCmd.SetArgs(append([]string{"init"}, args...))
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	return tmpDir
}

func TestInit_NonInteractive_Minimal(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Verify all 5 files are created
	expectedFiles := []string{
		".devcontainer/docker-compose.yml",
		".devcontainer/devcontainer.json",
		".devcontainer/.env",
		".env.example",
		".igor.yml",
	}

	for _, f := range expectedFiles {
		path := filepath.Join(tmpDir, f)
		info, err := os.Stat(path)
		if err != nil {
			t.Errorf("expected file %s to exist: %v", f, err)
			continue
		}
		if info.Size() == 0 {
			t.Errorf("file %s is empty", f)
		}
	}
}

func TestInit_NonInteractive_ValidYAML(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// docker-compose.yml should be valid YAML
	composeData, err := os.ReadFile(filepath.Join(tmpDir, ".devcontainer/docker-compose.yml"))
	if err != nil {
		t.Fatalf("ReadFile docker-compose.yml: %v", err)
	}
	var composeMap map[string]any
	if err := yaml.Unmarshal(composeData, &composeMap); err != nil {
		t.Errorf("docker-compose.yml is not valid YAML: %v", err)
	}

	// Verify it has expected top-level keys
	if _, ok := composeMap["services"]; !ok {
		t.Error("docker-compose.yml missing 'services' key")
	}
}

func TestInit_NonInteractive_ValidJSON(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// devcontainer.json has // comment markers, strip them for JSON validation
	jsonData, err := os.ReadFile(filepath.Join(tmpDir, ".devcontainer/devcontainer.json"))
	if err != nil {
		t.Fatalf("ReadFile devcontainer.json: %v", err)
	}

	// Strip // comment lines (Igor markers)
	var lines []string
	for _, line := range strings.Split(string(jsonData), "\n") {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "//") {
			lines = append(lines, line)
		}
	}
	cleaned := strings.Join(lines, "\n")

	var jsonMap map[string]any
	if err := json.Unmarshal([]byte(cleaned), &jsonMap); err != nil {
		t.Errorf("devcontainer.json is not valid JSON (after stripping comments): %v\nContent:\n%s", err, cleaned)
	}

	// Verify it has expected keys
	if _, ok := jsonMap["name"]; !ok {
		t.Error("devcontainer.json missing 'name' key")
	}
}

func TestInit_NonInteractive_IgorYMLRoundtrip(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Load the generated .igor.yml and verify features match input
	generated, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load generated .igor.yml: %v", err)
	}

	if generated.SchemaVersion != 1 {
		t.Errorf("SchemaVersion = %d, want 1", generated.SchemaVersion)
	}
	if generated.Project.Name != "myapp" {
		t.Errorf("Project.Name = %q, want %q", generated.Project.Name, "myapp")
	}
	if generated.ContainersDir != "containers" {
		t.Errorf("ContainersDir = %q, want %q", generated.ContainersDir, "containers")
	}

	// The generated .igor.yml should contain the explicit features
	featureSet := make(map[string]bool)
	for _, f := range generated.Features {
		featureSet[f] = true
	}
	if !featureSet["python"] {
		t.Error("generated .igor.yml missing feature 'python'")
	}
	if !featureSet["python_dev"] {
		t.Error("generated .igor.yml missing feature 'python_dev'")
	}
}

func TestInit_NonInteractive_GeneratedHashes(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	generated, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Generated hashes should be populated
	if len(generated.Generated) == 0 {
		t.Error("expected non-empty Generated hashes map")
	}

	// Each generated file should have a hash
	for _, path := range []string{
		".devcontainer/docker-compose.yml",
		".devcontainer/devcontainer.json",
		".devcontainer/.env",
		".env.example",
		".igor.yml",
	} {
		if _, ok := generated.Generated[path]; !ok {
			t.Errorf("missing hash for %s", path)
		}
	}
}

func TestInit_NonInteractive_Fullstack(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "fullstack.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	// Verify docker-compose.yml contains expected fullstack features
	composeData, err := os.ReadFile(filepath.Join(tmpDir, ".devcontainer/docker-compose.yml"))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	compose := string(composeData)

	// Should have docker socket mount
	if !strings.Contains(compose, "docker.sock") {
		t.Error("fullstack docker-compose.yml should mount docker socket")
	}
	// Should have SYS_ADMIN for bindfs (dev_tools implies bindfs)
	if !strings.Contains(compose, "SYS_ADMIN") {
		t.Error("fullstack docker-compose.yml should include SYS_ADMIN capability")
	}
	// Should have cache volumes
	if !strings.Contains(compose, "cache") {
		t.Error("fullstack docker-compose.yml should include cache volumes")
	}
}

func TestInit_NonInteractive_MissingConfig(t *testing.T) {
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

	rootCmd.SetArgs([]string{"init", "--non-interactive"})
	err = rootCmd.Execute()
	if err == nil {
		t.Error("expected error when --non-interactive used without --config")
	}
}

func TestInit_NonInteractive_InvalidConfigPath(t *testing.T) {
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

	rootCmd.SetArgs([]string{"init", "--non-interactive", "--config", "/nonexistent/config.yml"})
	err = rootCmd.Execute()
	if err == nil {
		t.Error("expected error with invalid config path")
	}
}

func TestInit_NonInteractive_ComposeValid(t *testing.T) {
	// Skip if docker compose is not available
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available")
	}

	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	composePath := filepath.Join(tmpDir, ".devcontainer", "docker-compose.yml")
	cmd := exec.Command("docker", "compose", "-f", composePath, "config", "--quiet")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("docker compose config failed: %v\nOutput: %s", err, string(output))
	}
}

func TestInit_NonInteractive_FullstackComposeValid(t *testing.T) {
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not available")
	}

	cfgPath := filepath.Join(testdataDir(), "fullstack.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	composePath := filepath.Join(tmpDir, ".devcontainer", "docker-compose.yml")
	cmd := exec.Command("docker", "compose", "-f", composePath, "config", "--quiet")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Errorf("docker compose config failed: %v\nOutput: %s", err, string(output))
	}
}

func TestInit_NonInteractive_DefaultVersionsFilled(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "minimal.igor.yml")
	tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)

	generated, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// minimal.igor.yml has no versions specified, so default PYTHON_VERSION should be filled
	if generated.Versions == nil {
		t.Fatal("expected Versions to be populated with defaults")
	}
	if v, ok := generated.Versions["PYTHON_VERSION"]; !ok {
		t.Error("expected PYTHON_VERSION to be set from defaults")
	} else if v == "" {
		t.Error("PYTHON_VERSION should not be empty")
	}
}

func TestInit_NonInteractive_FeatureOrderStable(t *testing.T) {
	cfgPath := filepath.Join(testdataDir(), "fullstack.igor.yml")

	// Run init twice and compare the features list ordering
	var featureLists [2][]string
	for i := range featureLists {
		tmpDir := executeInit(t, "--non-interactive", "--config", cfgPath)
		generated, err := igorconfig.Load(filepath.Join(tmpDir, ".igor.yml"))
		if err != nil {
			t.Fatalf("Load (run %d): %v", i, err)
		}
		featureLists[i] = generated.Features
	}

	if len(featureLists[0]) != len(featureLists[1]) {
		t.Fatalf("feature list lengths differ: %d vs %d", len(featureLists[0]), len(featureLists[1]))
	}
	for i, f := range featureLists[0] {
		if featureLists[1][i] != f {
			t.Errorf("feature order differs at index %d: %q vs %q", i, f, featureLists[1][i])
		}
	}

	// Verify they're actually sorted
	for i := 1; i < len(featureLists[0]); i++ {
		if featureLists[0][i] < featureLists[0][i-1] {
			t.Errorf("features not sorted: %q comes after %q", featureLists[0][i], featureLists[0][i-1])
		}
	}
}
