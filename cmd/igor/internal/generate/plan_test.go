package generate

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNewPlan_AllNew(t *testing.T) {
	entries := []FileEntry{
		{Path: "/nonexistent/a.txt", TemplateName: "a.tmpl", Content: "aaa"},
		{Path: "/nonexistent/b.txt", TemplateName: "b.tmpl", Content: "bbb"},
		{Path: "/nonexistent/c.txt", TemplateName: "c.tmpl", Content: "ccc"},
	}

	plan := NewPlan(entries)

	if len(plan.Creates) != 3 {
		t.Errorf("Creates length = %d, want 3", len(plan.Creates))
	}
	if len(plan.Skips) != 0 {
		t.Errorf("Skips length = %d, want 0", len(plan.Skips))
	}
}

func TestNewPlan_SomeExist(t *testing.T) {
	tmpDir := t.TempDir()

	// Create one existing file
	existingPath := filepath.Join(tmpDir, "existing.txt")
	if err := os.WriteFile(existingPath, []byte("old"), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	entries := []FileEntry{
		{Path: existingPath, TemplateName: "a.tmpl", Content: "new-content"},
		{Path: filepath.Join(tmpDir, "new.txt"), TemplateName: "b.tmpl", Content: "new-file"},
	}

	plan := NewPlan(entries)

	if len(plan.Creates) != 1 {
		t.Errorf("Creates length = %d, want 1", len(plan.Creates))
	}
	if len(plan.Skips) != 1 {
		t.Errorf("Skips length = %d, want 1", len(plan.Skips))
	}

	if plan.Creates[0].Path != filepath.Join(tmpDir, "new.txt") {
		t.Errorf("Creates[0].Path = %q, want new.txt", plan.Creates[0].Path)
	}
	if plan.Skips[0].Path != existingPath {
		t.Errorf("Skips[0].Path = %q, want existing.txt", plan.Skips[0].Path)
	}
}

func TestNewPlan_AllExist(t *testing.T) {
	tmpDir := t.TempDir()

	paths := make([]string, 3)
	for i := range paths {
		paths[i] = filepath.Join(tmpDir, filepath.Base(t.Name())+string(rune('a'+i))+".txt")
		if err := os.WriteFile(paths[i], []byte("data"), 0644); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
	}

	entries := []FileEntry{
		{Path: paths[0], TemplateName: "a.tmpl", Content: "new"},
		{Path: paths[1], TemplateName: "b.tmpl", Content: "new"},
		{Path: paths[2], TemplateName: "c.tmpl", Content: "new"},
	}

	plan := NewPlan(entries)

	if len(plan.Creates) != 0 {
		t.Errorf("Creates length = %d, want 0", len(plan.Creates))
	}
	if len(plan.Skips) != 3 {
		t.Errorf("Skips length = %d, want 3", len(plan.Skips))
	}
}

func TestNewPlan_Empty(t *testing.T) {
	plan := NewPlan(nil)

	if len(plan.Creates) != 0 {
		t.Errorf("Creates length = %d, want 0", len(plan.Creates))
	}
	if len(plan.Skips) != 0 {
		t.Errorf("Skips length = %d, want 0", len(plan.Skips))
	}
}

func TestNewPlan_PreservesContent(t *testing.T) {
	entries := []FileEntry{
		{Path: "/nonexistent/file.txt", TemplateName: "tmpl.tmpl", Content: "keep-this-content"},
	}

	plan := NewPlan(entries)

	if plan.Creates[0].Content != "keep-this-content" {
		t.Errorf("Content = %q, want %q", plan.Creates[0].Content, "keep-this-content")
	}
	if plan.Creates[0].TemplateName != "tmpl.tmpl" {
		t.Errorf("TemplateName = %q, want %q", plan.Creates[0].TemplateName, "tmpl.tmpl")
	}
}
