package config

import (
	"os"

	"gopkg.in/yaml.v3"
)

// IgorConfig is the .igor.yml state file.
type IgorConfig struct {
	// SchemaVersion for future migration support.
	SchemaVersion int `yaml:"schema_version"`

	// ContainersRef is the git ref (tag/commit) of the containers submodule.
	ContainersRef string `yaml:"containers_ref,omitempty"`

	// ContainersDir is the relative path to the containers submodule.
	ContainersDir string `yaml:"containers_dir"`

	// Project holds project-level settings.
	Project ProjectConfig `yaml:"project"`

	// Features lists explicitly selected feature IDs.
	Features []string `yaml:"features"`

	// Versions maps version arg names to chosen versions.
	Versions map[string]string `yaml:"versions,omitempty"`

	// Generated tracks generated file paths and their SHA-256 hashes.
	Generated map[string]string `yaml:"generated,omitempty"`
}

// ProjectConfig holds project-level configuration.
type ProjectConfig struct {
	// Name is the project name (used for workspace directory).
	Name string `yaml:"name"`

	// Username is the container user.
	Username string `yaml:"username"`

	// BaseImage is the Debian base image.
	BaseImage string `yaml:"base_image"`

	// WorkingDir is the workspace directory inside the container.
	WorkingDir string `yaml:"working_dir,omitempty"`
}

// Load reads an .igor.yml file.
func Load(path string) (*IgorConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg IgorConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// Save writes the config to the given path.
func (c *IgorConfig) Save(path string) error {
	data, err := yaml.Marshal(c)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}
