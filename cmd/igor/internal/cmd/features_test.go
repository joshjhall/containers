package cmd

import (
	"bytes"
	"strings"
	"testing"

	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

func executeFeatures(t *testing.T, args ...string) string {
	t.Helper()

	// Reset flag state from prior tests.
	featuresFormat = "table"

	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	rootCmd.SetArgs(append([]string{"features"}, args...))
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("features Execute: %v", err)
	}
	return buf.String()
}

func TestFeatures_DefaultFormat(t *testing.T) {
	out := executeFeatures(t)

	// Category headers present
	for _, header := range []string{"Languages:", "Tools:", "Cloud & Infrastructure:", "Database Clients:", "AI/ML:"} {
		if !strings.Contains(out, header) {
			t.Errorf("missing category header %q", header)
		}
	}

	// Known feature IDs present
	for _, id := range []string{"python", "node", "rust", "golang", "docker", "kubernetes"} {
		if !strings.Contains(out, id) {
			t.Errorf("missing feature ID %q in table output", id)
		}
	}

	// Column headers present
	if !strings.Contains(out, "Build Arg") {
		t.Error("missing column header 'Build Arg'")
	}
}

func TestFeatures_MarkdownFormat(t *testing.T) {
	out := executeFeatures(t, "--format=markdown")

	// Markdown headers
	for _, header := range []string{"## Languages", "## Tools", "## Cloud & Infrastructure", "## Database Clients", "## AI/ML"} {
		if !strings.Contains(out, header) {
			t.Errorf("missing markdown header %q", header)
		}
	}

	// Markdown table delimiters
	if !strings.Contains(out, "|") {
		t.Error("missing markdown table delimiters")
	}
	if !strings.Contains(out, "|-") {
		t.Error("missing markdown table separator row")
	}

	// Column headers
	for _, col := range []string{"Display Name", "Build Arg", "Version Arg", "Implied By"} {
		if !strings.Contains(out, col) {
			t.Errorf("missing markdown column %q", col)
		}
	}
}

func TestFeatures_AllRegistryFeaturesPresent(t *testing.T) {
	out := executeFeatures(t)

	reg := feature.NewRegistry()
	for _, f := range reg.All() {
		if !strings.Contains(out, f.ID) {
			t.Errorf("feature %q missing from output", f.ID)
		}
	}
}

func TestFeatures_CategoryGrouping(t *testing.T) {
	out := executeFeatures(t)

	headers := []string{"Languages:", "Tools:", "Cloud & Infrastructure:", "Database Clients:", "AI/ML:"}
	lastIdx := -1
	for _, h := range headers {
		idx := strings.Index(out, h)
		if idx == -1 {
			t.Errorf("missing header %q", h)
			continue
		}
		if idx <= lastIdx {
			t.Errorf("header %q appears before a preceding category", h)
		}
		lastIdx = idx
	}
}

func TestFeatures_FormatFlag(t *testing.T) {
	flag := featuresCmd.Flags().Lookup("format")
	if flag == nil {
		t.Fatal("--format flag not registered")
	}
	if flag.DefValue != "table" {
		t.Errorf("--format default = %q, want %q", flag.DefValue, "table")
	}
}

func TestFeatures_InvalidFormat(t *testing.T) {
	featuresFormat = "table"

	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	rootCmd.SetArgs([]string{"features", "--format=csv"})
	err := rootCmd.Execute()
	if err == nil {
		t.Error("expected error for invalid format")
	}
}
