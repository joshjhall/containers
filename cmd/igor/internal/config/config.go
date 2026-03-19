package config

import (
	"fmt"
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

	// Agents holds optional agent/worktree settings.
	Agents AgentConfig `yaml:"agents,omitempty"`
}

// AgentConfig holds optional agent/worktree settings.
type AgentConfig struct {
	Max           int      `yaml:"max,omitempty"`
	Username      string   `yaml:"username,omitempty"`
	Network       string   `yaml:"network,omitempty"`
	ImageTag      string   `yaml:"image_tag,omitempty"`
	SharedVolumes []string `yaml:"shared_volumes,omitempty"`
	Repos         []string `yaml:"repos,omitempty"`
}

// IsZero returns true when no agent fields have been explicitly set.
func (a AgentConfig) IsZero() bool {
	return a.Max == 0 && a.Username == "" && a.Network == "" &&
		a.ImageTag == "" && len(a.SharedVolumes) == 0 && len(a.Repos) == 0
}

// AgentDefaults returns an AgentConfig with zero-value fields filled with
// sensible defaults derived from the project name and cache volumes.
func AgentDefaults(projectName string, cacheVolumes []string) AgentConfig {
	ac := AgentConfig{
		Max:      5,
		Username: "agent",
		Network:  fmt.Sprintf("%s-network", projectName),
		ImageTag: "latest",
	}
	if len(cacheVolumes) > 0 {
		ac.SharedVolumes = make([]string, len(cacheVolumes))
		copy(ac.SharedVolumes, cacheVolumes)
	}
	return ac
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
