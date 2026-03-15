package generate

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteFiles_CreatesFilesAndHashes(t *testing.T) {
	tmpDir := t.TempDir()

	content1 := "hello world"
	content2 := "docker-compose content"

	entries := []FileEntry{
		{Path: filepath.Join(tmpDir, "a.txt"), Content: content1},
		{Path: filepath.Join(tmpDir, "subdir", "b.txt"), Content: content2},
	}

	hashes, err := WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles: %v", err)
	}

	// Verify files exist and have correct content
	for _, e := range entries {
		data, err := os.ReadFile(e.Path)
		if err != nil {
			t.Fatalf("ReadFile(%s): %v", e.Path, err)
		}
		if string(data) != e.Content {
			t.Errorf("file %s content = %q, want %q", e.Path, string(data), e.Content)
		}
	}

	// Verify hashes
	if len(hashes) != 2 {
		t.Fatalf("hashes length = %d, want 2", len(hashes))
	}

	for _, e := range entries {
		wantHash := fmt.Sprintf("%x", sha256.Sum256([]byte(e.Content)))
		if hashes[e.Path] != wantHash {
			t.Errorf("hash[%s] = %q, want %q", e.Path, hashes[e.Path], wantHash)
		}
	}
}

func TestWriteFiles_CreatesDirectories(t *testing.T) {
	tmpDir := t.TempDir()

	entries := []FileEntry{
		{Path: filepath.Join(tmpDir, "deep", "nested", "dir", "file.txt"), Content: "nested"},
	}

	_, err := WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles: %v", err)
	}

	data, err := os.ReadFile(entries[0].Path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "nested" {
		t.Errorf("content = %q, want %q", string(data), "nested")
	}
}

func TestWriteFiles_Empty(t *testing.T) {
	hashes, err := WriteFiles(nil)
	if err != nil {
		t.Fatalf("WriteFiles(nil): %v", err)
	}
	if len(hashes) != 0 {
		t.Errorf("hashes length = %d, want 0", len(hashes))
	}
}

func TestWriteFiles_OverwritesExisting(t *testing.T) {
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "overwrite.txt")

	if err := os.WriteFile(path, []byte("old-content"), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	entries := []FileEntry{
		{Path: path, Content: "new-content"},
	}

	_, err := WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(data) != "new-content" {
		t.Errorf("content = %q, want %q", string(data), "new-content")
	}
}

func TestWriteFiles_HashDeterministic(t *testing.T) {
	tmpDir := t.TempDir()
	content := "deterministic content"

	entries := []FileEntry{
		{Path: filepath.Join(tmpDir, "det.txt"), Content: content},
	}

	hashes1, err := WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles (1st): %v", err)
	}

	hashes2, err := WriteFiles(entries)
	if err != nil {
		t.Fatalf("WriteFiles (2nd): %v", err)
	}

	path := entries[0].Path
	if hashes1[path] != hashes2[path] {
		t.Errorf("hashes differ across runs: %q vs %q", hashes1[path], hashes2[path])
	}
}
