package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

// DockerRunner abstracts docker CLI for testability.
type DockerRunner interface {
	// Run executes a docker command and captures output.
	Run(args ...string) (string, error)
	// Passthrough executes a docker command with stdin/stdout/stderr attached.
	Passthrough(args ...string) error
}

// execDockerRunner implements DockerRunner via os/exec.
type execDockerRunner struct{}

func (e *execDockerRunner) Run(args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func (e *execDockerRunner) Passthrough(args ...string) error {
	cmd := exec.Command("docker", args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// agentContext holds resolved config for all agent subcommands.
type agentContext struct {
	cfg           *igorconfig.IgorConfig
	project       string
	imageName     string
	imageTag      string
	network       string
	username      string
	maxAgents     int
	repos         []string
	sharedVolumes []string
	baseDir       string
	containersDir string
	features      []*feature.Feature
	versions      map[string]string
	docker        DockerRunner
}

// agentDockerOverride allows tests to inject a mock DockerRunner.
// When non-nil, loadAgentContext uses this instead of the real exec runner.
var agentDockerOverride DockerRunner

var agentCmd = &cobra.Command{
	Use:   "agent",
	Short: "Manage agent containers",
	Long: `Build, start, stop, and connect to agent containers.

Agent containers are purpose-built development environments that run
alongside git worktrees created by "igor worktree create".`,
}

func init() {
	rootCmd.AddCommand(agentCmd)
}

// loadAgentContext loads .igor.yml, resolves features, and builds a fully
// populated agentContext. The docker field is set to the provided runner,
// or the real exec runner if nil.
func loadAgentContext(docker DockerRunner) (*agentContext, error) {
	cfgPath := ".igor.yml"
	if configFile != "" {
		cfgPath = configFile
	}

	cfg, err := igorconfig.Load(cfgPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fmt.Errorf("no .igor.yml found; run 'igor init' first")
		}
		return nil, fmt.Errorf("loading .igor.yml: %w", err)
	}

	reg := feature.NewRegistry()

	// Build explicit set from config features.
	explicit := make(map[string]bool, len(cfg.Features))
	for _, id := range cfg.Features {
		explicit[id] = true
	}
	sel := feature.Resolve(explicit, reg)

	// Collect enabled features in registry order.
	allIDs := sel.All()
	var features []*feature.Feature
	for _, f := range reg.All() {
		if allIDs[f.ID] {
			features = append(features, f)
		}
	}

	// Collect cache volumes (deduplicated).
	volSet := make(map[string]bool)
	var cacheVolumes []string
	for _, f := range features {
		for _, v := range f.CacheVolumes {
			if !volSet[v] {
				volSet[v] = true
				cacheVolumes = append(cacheVolumes, v)
			}
		}
	}

	// Apply agent config defaults.
	ac := cfg.Agents
	maxAgents := ac.Max
	if maxAgents == 0 {
		maxAgents = 5
	}
	username := ac.Username
	if username == "" {
		username = "agent"
	}
	network := ac.Network
	if network == "" {
		network = fmt.Sprintf("%s-network", cfg.Project.Name)
	}
	imageTag := ac.ImageTag
	if imageTag == "" {
		imageTag = "latest"
	}
	sharedVolumes := ac.SharedVolumes
	if len(sharedVolumes) == 0 && len(cacheVolumes) > 0 {
		sharedVolumes = make([]string, len(cacheVolumes))
		copy(sharedVolumes, cacheVolumes)
	}

	repos := ac.Repos
	if len(repos) == 0 {
		repos = []string{cfg.Project.Name}
	}

	// Determine base directory.
	baseDir := "/workspace"
	if cfg.Project.WorkingDir != "" {
		baseDir = filepath.Dir(cfg.Project.WorkingDir)
	}

	// Resolve containers dir.
	containersDir := cfg.ContainersDir
	if containersDir == "" {
		containersDir = "containers"
	}
	if !filepath.IsAbs(containersDir) {
		containersDir = filepath.Join(baseDir, cfg.Project.Name, containersDir)
	}

	if docker == nil {
		if agentDockerOverride != nil {
			docker = agentDockerOverride
		} else {
			docker = &execDockerRunner{}
		}
	}

	return &agentContext{
		cfg:           cfg,
		project:       cfg.Project.Name,
		imageName:     cfg.Project.Name + "-agent",
		imageTag:      imageTag,
		network:       network,
		username:      username,
		maxAgents:     maxAgents,
		repos:         repos,
		sharedVolumes: sharedVolumes,
		baseDir:       baseDir,
		containersDir: containersDir,
		features:      features,
		versions:      cfg.Versions,
		docker:        docker,
	}, nil
}

// containerName returns the docker container name for agent N.
func containerName(project string, n int) string {
	return fmt.Sprintf("%s-agent-%d", project, n)
}

// agentSuffix returns the worktree suffix for agent N (e.g. "agent01").
func agentSuffix(n int) string {
	return fmt.Sprintf("agent%02d", n)
}

// validateAgentNum parses and validates an agent number argument.
func validateAgentNum(arg string, max int) (int, error) {
	n, err := strconv.Atoi(arg)
	if err != nil {
		return 0, fmt.Errorf("invalid agent number %q: must be an integer", arg)
	}
	if n < 1 || n > max {
		return 0, fmt.Errorf("agent number must be between 1 and %d", max)
	}
	return n, nil
}

// isContainerRunning checks if a container exists and is running.
func isContainerRunning(docker DockerRunner, name string) bool {
	out, err := docker.Run("inspect", "-f", "{{.State.Running}}", name)
	if err != nil {
		return false
	}
	return out == "true"
}

// containerExists checks if a container exists (running or stopped).
func containerExists(docker DockerRunner, name string) bool {
	_, err := docker.Run("inspect", "-f", "{{.State.Status}}", name)
	return err == nil
}

// imageExists checks if a docker image exists locally.
func imageExists(docker DockerRunner, name, tag string) bool {
	_, err := docker.Run("image", "inspect", name+":"+tag)
	return err == nil
}
