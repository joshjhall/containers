package template

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

func testdataDir() string {
	_, filename, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(filename), "..", "..", "testdata")
}

func TestRenderer_MinimalPython(t *testing.T) {
	reg := feature.NewRegistry()
	sel := feature.Resolve(map[string]bool{
		"python":     true,
		"python_dev": true,
	}, reg)

	ctx := NewRenderContext(
		config.ProjectConfig{
			Name:      "myapp",
			Username:  "developer",
			BaseImage: "debian:trixie-slim",
		},
		"containers",
		sel, reg,
		map[string]string{"PYTHON_VERSION": "3.14.0"},
	)

	renderer, err := NewRenderer()
	if err != nil {
		t.Fatalf("NewRenderer: %v", err)
	}

	templates := []string{
		"docker-compose.yml.tmpl",
		"devcontainer.json.tmpl",
		"env.tmpl",
		"env-example.tmpl",
		"igor.yml.tmpl",
	}

	for _, tmpl := range templates {
		t.Run(tmpl, func(t *testing.T) {
			output, err := renderer.Render(tmpl, ctx)
			if err != nil {
				t.Fatalf("Render(%s): %v", tmpl, err)
			}
			if output == "" {
				t.Errorf("Render(%s) produced empty output", tmpl)
			}

			// Update golden files with -update flag
			goldenPath := filepath.Join(testdataDir(), "golden", "minimal", tmpl+".golden")
			if os.Getenv("UPDATE_GOLDEN") == "1" {
				os.MkdirAll(filepath.Dir(goldenPath), 0755)
				os.WriteFile(goldenPath, []byte(output), 0644)
				return
			}

			// Compare against golden file if it exists
			golden, err := os.ReadFile(goldenPath)
			if err != nil {
				// Golden doesn't exist yet — skip comparison but don't fail
				t.Logf("No golden file at %s (run with UPDATE_GOLDEN=1 to create)", goldenPath)
				return
			}
			if output != string(golden) {
				t.Errorf("Render(%s) output differs from golden.\nGot:\n%s\nWant:\n%s", tmpl, output, string(golden))
			}
		})
	}
}

func TestRenderer_FullStack(t *testing.T) {
	reg := feature.NewRegistry()
	sel := feature.Resolve(map[string]bool{
		"python": true, "python_dev": true,
		"node": true, "node_dev": true,
		"rust": true, "rust_dev": true,
		"golang": true, "golang_dev": true,
		"dev_tools": true, "docker": true, "op": true,
		"kubernetes": true, "terraform": true, "aws": true,
		"postgres_client": true, "redis_client": true,
		"ollama": true,
	}, reg)

	ctx := NewRenderContext(
		config.ProjectConfig{
			Name:      "fullstack",
			Username:  "dev",
			BaseImage: "debian:bookworm-slim",
		},
		"containers",
		sel, reg,
		map[string]string{
			"PYTHON_VERSION": "3.14.0",
			"NODE_VERSION":   "22.12.0",
			"RUST_VERSION":   "1.83.0",
			"GO_VERSION":     "1.23.4",
		},
	)

	renderer, err := NewRenderer()
	if err != nil {
		t.Fatalf("NewRenderer: %v", err)
	}

	templates := []string{
		"docker-compose.yml.tmpl",
		"devcontainer.json.tmpl",
		"env.tmpl",
		"env-example.tmpl",
		"igor.yml.tmpl",
	}

	for _, tmpl := range templates {
		t.Run(tmpl, func(t *testing.T) {
			output, err := renderer.Render(tmpl, ctx)
			if err != nil {
				t.Fatalf("Render(%s): %v", tmpl, err)
			}
			if output == "" {
				t.Errorf("Render(%s) produced empty output", tmpl)
			}

			// Golden file comparison (same pattern as minimal)
			goldenPath := filepath.Join(testdataDir(), "golden", "fullstack", tmpl+".golden")
			if os.Getenv("UPDATE_GOLDEN") == "1" {
				os.MkdirAll(filepath.Dir(goldenPath), 0755)
				os.WriteFile(goldenPath, []byte(output), 0644)
				return
			}

			golden, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Logf("No golden file at %s (run with UPDATE_GOLDEN=1 to create)", goldenPath)
				return
			}
			if output != string(golden) {
				t.Errorf("Render(%s) output differs from golden.\nGot:\n%s\nWant:\n%s", tmpl, output, string(golden))
			}
		})
	}
}

func TestRenderer_DockerCompose_BindfsCapabilities(t *testing.T) {
	reg := feature.NewRegistry()
	sel := feature.Resolve(map[string]bool{"dev_tools": true}, reg)

	ctx := NewRenderContext(
		config.ProjectConfig{Name: "test", Username: "dev", BaseImage: "debian:trixie-slim"},
		"containers", sel, reg, nil,
	)

	renderer, err := NewRenderer()
	if err != nil {
		t.Fatalf("NewRenderer: %v", err)
	}

	output, err := renderer.Render("docker-compose.yml.tmpl", ctx)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	// dev_tools implies bindfs, which needs cap_add and devices
	if !contains(output, "SYS_ADMIN") {
		t.Error("docker-compose should include SYS_ADMIN cap_add when bindfs is selected")
	}
	if !contains(output, "/dev/fuse") {
		t.Error("docker-compose should include /dev/fuse device when bindfs is selected")
	}
}

func TestRenderer_DockerCompose_DockerSocket(t *testing.T) {
	reg := feature.NewRegistry()
	sel := feature.Resolve(map[string]bool{"docker": true}, reg)

	ctx := NewRenderContext(
		config.ProjectConfig{Name: "test", Username: "dev", BaseImage: "debian:trixie-slim"},
		"containers", sel, reg, nil,
	)

	renderer, err := NewRenderer()
	if err != nil {
		t.Fatalf("NewRenderer: %v", err)
	}

	output, err := renderer.Render("docker-compose.yml.tmpl", ctx)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	if !contains(output, "docker.sock") {
		t.Error("docker-compose should mount Docker socket when docker feature is selected")
	}
}

func TestRenderer_NoDockerSocket_WhenNotSelected(t *testing.T) {
	reg := feature.NewRegistry()
	sel := feature.Resolve(map[string]bool{"python": true}, reg)

	ctx := NewRenderContext(
		config.ProjectConfig{Name: "test", Username: "dev", BaseImage: "debian:trixie-slim"},
		"containers", sel, reg, nil,
	)

	renderer, err := NewRenderer()
	if err != nil {
		t.Fatalf("NewRenderer: %v", err)
	}

	output, err := renderer.Render("docker-compose.yml.tmpl", ctx)
	if err != nil {
		t.Fatalf("Render: %v", err)
	}

	if contains(output, "docker.sock") {
		t.Error("docker-compose should NOT mount Docker socket when docker feature is not selected")
	}
}

func contains(s, substr string) bool {
	return len(s) > 0 && len(substr) > 0 && indexOf(s, substr) >= 0
}

func indexOf(s, substr string) int {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}
