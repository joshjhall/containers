package generate

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
)

// WriteFiles writes the planned files, creating directories as needed.
// It returns a map of relative path → SHA-256 hash.
func WriteFiles(entries []FileEntry) (map[string]string, error) {
	hashes := make(map[string]string, len(entries))

	for _, e := range entries {
		dir := filepath.Dir(e.Path)
		if err := os.MkdirAll(dir, 0755); err != nil {
			return nil, fmt.Errorf("creating directory %s: %w", dir, err)
		}

		if err := os.WriteFile(e.Path, []byte(e.Content), 0644); err != nil {
			return nil, fmt.Errorf("writing %s: %w", e.Path, err)
		}

		hash := sha256.Sum256([]byte(e.Content))
		hashes[e.Path] = fmt.Sprintf("%x", hash)
	}

	return hashes, nil
}
