package cmd

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
	"gopkg.in/yaml.v3"
)

// mockResult holds a pre-configured return value for a docker command.
type mockResult struct {
	output string
	err    error
}

// mockDocker records docker calls and returns configurable responses.
// Set runFunc for full control over Run behavior; otherwise matchResults
// and sequential results are used.
type mockDocker struct {
	calls        [][]string
	results      []mockResult // consumed in order; default success if exhausted
	matchResults map[string]mockResult
	runFunc      func(args ...string) (string, error) // optional override
}

func newMockDocker() *mockDocker {
	return &mockDocker{
		matchResults: make(map[string]mockResult),
	}
}

func (m *mockDocker) Run(args ...string) (string, error) {
	m.calls = append(m.calls, args)

	if m.runFunc != nil {
		return m.runFunc(args...)
	}

	// Check match-based results (two-arg key, then single-arg key).
	if len(args) >= 2 {
		key := args[0] + " " + args[1]
		if r, ok := m.matchResults[key]; ok {
			return r.output, r.err
		}
	}
	if len(args) >= 1 {
		if r, ok := m.matchResults[args[0]]; ok {
			return r.output, r.err
		}
	}

	// Fall back to ordered results.
	if len(m.results) > 0 {
		r := m.results[0]
		m.results = m.results[1:]
		return r.output, r.err
	}

	return "", nil
}

func (m *mockDocker) Passthrough(args ...string) error {
	m.calls = append(m.calls, args)

	if len(args) >= 1 {
		if r, ok := m.matchResults["passthrough:"+args[0]]; ok {
			return r.err
		}
	}

	return nil
}

func (m *mockDocker) callCount() int {
	return len(m.calls)
}

func (m *mockDocker) hasCall(substr string) bool {
	for _, c := range m.calls {
		if strings.Contains(strings.Join(c, " "), substr) {
			return true
		}
	}
	return false
}

// setupAgentTest creates a temp dir with .igor.yml and chdir into it.
func setupAgentTest(t *testing.T, cfg *igorconfig.IgorConfig) (*mockDocker, string) {
	t.Helper()

	// Reset globals that leak between tests.
	configFile = ""

	baseDir := t.TempDir()
	projectDir := filepath.Join(baseDir, cfg.Project.Name)
	if err := os.MkdirAll(projectDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}

	// Create a containers subdir to satisfy containersDir resolution.
	containersDir := filepath.Join(projectDir, cfg.ContainersDir)
	if cfg.ContainersDir == "" {
		containersDir = filepath.Join(projectDir, "containers")
	}
	if err := os.MkdirAll(containersDir, 0755); err != nil {
		t.Fatalf("MkdirAll containers: %v", err)
	}

	// Override WorkingDir to point to our temp dir.
	cfg.Project.WorkingDir = projectDir

	data, err := yaml.Marshal(cfg)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if err := os.WriteFile(filepath.Join(projectDir, ".igor.yml"), data, 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	origDir, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(projectDir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { os.Chdir(origDir) })

	mock := newMockDocker()
	return mock, baseDir
}

// executeAgentCmd runs an agent subcommand with the mock docker runner injected.
func executeAgentCmd(t *testing.T, mock *mockDocker, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	// Reset globals that may persist between test runs.
	configFile = ""
	agentBuildDryRun = false
	agentLogsFollow = false
	agentStartRebuild = false
	agentConnectTimeout = 60

	// Inject mock docker via package-level override.
	origOverride := agentDockerOverride
	agentDockerOverride = mock
	defer func() { agentDockerOverride = origOverride }()

	rootCmd.SetArgs(append([]string{"agent"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}

// --- Helper tests ---

func TestContainerName(t *testing.T) {
	tests := []struct {
		project string
		n       int
		want    string
	}{
		{"myproject", 1, "myproject-agent-1"},
		{"myproject", 5, "myproject-agent-5"},
		{"app", 10, "app-agent-10"},
	}
	for _, tt := range tests {
		got := containerName(tt.project, tt.n)
		if got != tt.want {
			t.Errorf("containerName(%q, %d) = %q, want %q", tt.project, tt.n, got, tt.want)
		}
	}
}

func TestAgentSuffix(t *testing.T) {
	tests := []struct {
		n    int
		want string
	}{
		{1, "agent01"},
		{5, "agent05"},
		{12, "agent12"},
	}
	for _, tt := range tests {
		got := agentSuffix(tt.n)
		if got != tt.want {
			t.Errorf("agentSuffix(%d) = %q, want %q", tt.n, got, tt.want)
		}
	}
}

func TestValidateAgentNum(t *testing.T) {
	tests := []struct {
		arg     string
		max     int
		want    int
		wantErr string
	}{
		{"1", 5, 1, ""},
		{"5", 5, 5, ""},
		{"0", 5, 0, "between 1 and 5"},
		{"6", 5, 0, "between 1 and 5"},
		{"abc", 5, 0, "must be an integer"},
		{"3", 3, 3, ""},
		{"4", 3, 0, "between 1 and 3"},
	}
	for _, tt := range tests {
		t.Run(tt.arg, func(t *testing.T) {
			got, err := validateAgentNum(tt.arg, tt.max)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatal("expected error")
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Errorf("error %q should contain %q", err.Error(), tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %d, want %d", got, tt.want)
			}
		})
	}
}

// --- Build tests ---

func TestAgentBuild_DryRun(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Features:      []string{"python", "node"},
		Versions:      map[string]string{"PYTHON_VERSION": "3.12.0"},
	}
	mock, _ := setupAgentTest(t, cfg)

	out, err := executeAgentCmd(t, mock, "build", "--dry-run")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "docker build") {
		t.Errorf("expected docker build command, got: %s", out)
	}
	if !strings.Contains(out, "INCLUDE_PYTHON=true") {
		t.Errorf("expected INCLUDE_PYTHON=true in output, got: %s", out)
	}
	if !strings.Contains(out, "INCLUDE_NODE=true") {
		t.Errorf("expected INCLUDE_NODE=true in output, got: %s", out)
	}
	if !strings.Contains(out, "PYTHON_VERSION=3.12.0") {
		t.Errorf("expected PYTHON_VERSION in output, got: %s", out)
	}
	if !strings.Contains(out, "PROJECT_NAME=myproject") {
		t.Errorf("expected PROJECT_NAME in output, got: %s", out)
	}
	if !strings.Contains(out, "USERNAME=agent") {
		t.Errorf("expected USERNAME=agent in output, got: %s", out)
	}

	// Mock should have zero calls (dry-run).
	if mock.callCount() != 0 {
		t.Errorf("dry-run should not execute docker commands, got %d calls", mock.callCount())
	}
}

func TestAgentBuild_BuildArgs(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "testproj", Username: "dev"},
		Features:      []string{"python", "python_dev", "docker"},
	}
	mock, _ := setupAgentTest(t, cfg)

	out, err := executeAgentCmd(t, mock, "build", "--dry-run")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "INCLUDE_PYTHON=true") {
		t.Errorf("expected INCLUDE_PYTHON in build args, got: %s", out)
	}
	if !strings.Contains(out, "INCLUDE_PYTHON_DEV=true") {
		t.Errorf("expected INCLUDE_PYTHON_DEV in build args, got: %s", out)
	}
	if !strings.Contains(out, "INCLUDE_DOCKER=true") {
		t.Errorf("expected INCLUDE_DOCKER in build args, got: %s", out)
	}
}

// --- Start tests ---

func TestAgentStart_InvalidN(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Max: 5},
	}

	tests := []struct {
		arg     string
		wantErr string
	}{
		{"0", "between 1 and 5"},
		{"abc", "must be an integer"},
		{"6", "between 1 and 5"},
	}

	for _, tt := range tests {
		t.Run(tt.arg, func(t *testing.T) {
			mock, _ := setupAgentTest(t, cfg)
			_, err := executeAgentCmd(t, mock, "start", tt.arg)
			if err == nil {
				t.Fatal("expected error")
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Errorf("error %q should contain %q", err.Error(), tt.wantErr)
			}
		})
	}
}

func TestAgentStart_AlreadyRunning(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeAgentCmd(t, mock, "start", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "already running") {
		t.Errorf("expected 'already running' message, got: %s", out)
	}
}

func TestAgentStart_NoImage(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["image inspect"] = mockResult{output: "", err: fmt.Errorf("not found")}

	_, err := executeAgentCmd(t, mock, "start", "1")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "run 'igor agent build' first") {
		t.Errorf("error should mention build, got: %v", err)
	}
}

func TestAgentStart_NewContainer(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Features:      []string{"python"},
	}
	mock, baseDir := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["image inspect"] = mockResult{output: "ok", err: nil}
	mock.matchResults["network inspect"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["network create"] = mockResult{output: "ok", err: nil}

	out, err := executeAgentCmd(t, mock, "start", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Creating container") {
		t.Errorf("expected 'Creating container' message, got: %s", out)
	}
	if !strings.Contains(out, "started") {
		t.Errorf("expected 'started' message, got: %s", out)
	}

	if !mock.hasCall("run -d") {
		t.Error("expected docker run -d call")
	}
	if !mock.hasCall("--name myproject-agent-1") {
		t.Error("expected --name myproject-agent-1")
	}
	if !mock.hasCall("--network myproject-network") {
		t.Error("expected --network")
	}
	if !mock.hasCall("--hostname agent-1") {
		t.Error("expected --hostname")
	}
	if !mock.hasCall(filepath.Join(baseDir, "myproject-agent01")) {
		t.Error("expected worktree volume mount")
	}
	if !mock.hasCall("sleep infinity") {
		t.Error("expected sleep infinity command")
	}
}

func TestAgentStart_StoppedContainer(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	callNum := 0
	mock.runFunc = func(args ...string) (string, error) {
		if len(args) >= 2 && args[0] == "inspect" && args[1] == "-f" {
			callNum++
			if callNum == 1 {
				// isContainerRunning → not running
				return "false", nil
			}
			// containerExists → exists (stopped)
			return "exited", nil
		}
		if args[0] == "start" {
			return "", nil
		}
		return "", nil
	}

	out, err := executeAgentCmd(t, mock, "start", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Starting stopped container") {
		t.Errorf("expected 'Starting stopped container' message, got: %s", out)
	}
	if !mock.hasCall("start myproject-agent-1") {
		t.Error("expected docker start call")
	}
}

// --- Stop tests ---

func TestAgentStop_Running(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeAgentCmd(t, mock, "stop", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "stopped") {
		t.Errorf("expected 'stopped' message, got: %s", out)
	}
	if !mock.hasCall("stop myproject-agent-1") {
		t.Error("expected docker stop call")
	}
}

func TestAgentStop_NotRunning(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}

	out, err := executeAgentCmd(t, mock, "stop", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "not running") {
		t.Errorf("expected 'not running' message, got: %s", out)
	}
}

// --- Restart tests ---

func TestAgentRestart_Sequence(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	callNum := 0
	mock.runFunc = func(args ...string) (string, error) {
		if len(args) >= 2 && args[0] == "inspect" && args[1] == "-f" {
			callNum++
			switch {
			case callNum == 1:
				// isContainerRunning in restart → yes
				return "true", nil
			case callNum == 2:
				// containerExists in restart → yes (after stop)
				return "exited", nil
			case callNum == 3:
				// isContainerRunning in start → no (just removed)
				return "", fmt.Errorf("not found")
			case callNum == 4:
				// containerExists in start → no (just removed)
				return "", fmt.Errorf("not found")
			}
		}
		if len(args) >= 2 && args[0] == "image" && args[1] == "inspect" {
			return "ok", nil
		}
		if len(args) >= 2 && args[0] == "network" && args[1] == "inspect" {
			return "ok", nil
		}
		return "", nil
	}

	out, err := executeAgentCmd(t, mock, "restart", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "Stopping") {
		t.Errorf("expected 'Stopping' in output, got: %s", out)
	}
	if !strings.Contains(out, "Removing") {
		t.Errorf("expected 'Removing' in output, got: %s", out)
	}
	if !mock.hasCall("stop myproject-agent-1") {
		t.Error("expected docker stop")
	}
	if !mock.hasCall("rm myproject-agent-1") {
		t.Error("expected docker rm")
	}
	if !mock.hasCall("run -d") {
		t.Error("expected docker run")
	}
}

// --- Status tests ---

func TestAgentStatus_Table(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Max: 3},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["image inspect"] = mockResult{output: "ok", err: nil}
	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}

	out, err := executeAgentCmd(t, mock, "status")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(out, "Image: myproject-agent:latest (built)") {
		t.Errorf("expected image status, got: %s", out)
	}
	if !strings.Contains(out, "myproject-network") {
		t.Errorf("expected network in output, got: %s", out)
	}
	if !strings.Contains(out, "AGENT") {
		t.Errorf("expected table header, got: %s", out)
	}
	for i := 1; i <= 3; i++ {
		name := containerName("myproject", i)
		if !strings.Contains(out, name) {
			t.Errorf("expected %s in status output, got: %s", name, out)
		}
	}
	if !strings.Contains(out, "not created") {
		t.Errorf("expected 'not created' status, got: %s", out)
	}
}

// --- Logs tests ---

func TestAgentLogs_Basic(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "exited", err: nil}

	_, err := executeAgentCmd(t, mock, "logs", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !mock.hasCall("logs myproject-agent-1") {
		t.Error("expected docker logs call")
	}
}

func TestAgentLogs_Follow(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "exited", err: nil}

	_, err := executeAgentCmd(t, mock, "logs", "-f", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !mock.hasCall("logs -f myproject-agent-1") {
		t.Error("expected docker logs -f call")
	}
}

func TestAgentLogs_NotExist(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}

	_, err := executeAgentCmd(t, mock, "logs", "1")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Errorf("error should mention 'does not exist', got: %v", err)
	}
}

// --- Context loading tests ---

func TestLoadAgentContext_Defaults(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "testapp", Username: "dev"},
		Features:      []string{"python"},
	}
	setupAgentTest(t, cfg)

	mock := newMockDocker()
	ctx, err := loadAgentContext(mock)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if ctx.project != "testapp" {
		t.Errorf("project = %q, want %q", ctx.project, "testapp")
	}
	if ctx.imageName != "testapp-agent" {
		t.Errorf("imageName = %q, want %q", ctx.imageName, "testapp-agent")
	}
	if ctx.imageTag != "latest" {
		t.Errorf("imageTag = %q, want %q", ctx.imageTag, "latest")
	}
	if ctx.network != "testapp-network" {
		t.Errorf("network = %q, want %q", ctx.network, "testapp-network")
	}
	if ctx.username != "agent" {
		t.Errorf("username = %q, want %q", ctx.username, "agent")
	}
	if ctx.maxAgents != 5 {
		t.Errorf("maxAgents = %d, want 5", ctx.maxAgents)
	}
	if len(ctx.repos) != 1 || ctx.repos[0] != "testapp" {
		t.Errorf("repos = %v, want [testapp]", ctx.repos)
	}
	if len(ctx.sharedVolumes) == 0 {
		t.Error("expected shared volumes from python cache volumes")
	}
}

func TestLoadAgentContext_CustomConfig(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myapp", Username: "dev"},
		Features:      []string{"golang"},
		Agents: igorconfig.AgentConfig{
			Max:           3,
			Username:      "coder",
			Network:       "custom-net",
			ImageTag:      "v2",
			SharedVolumes: []string{"data:/data"},
			Repos:         []string{"myapp", "shared-lib"},
		},
	}
	setupAgentTest(t, cfg)

	mock := newMockDocker()
	ctx, err := loadAgentContext(mock)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if ctx.maxAgents != 3 {
		t.Errorf("maxAgents = %d, want 3", ctx.maxAgents)
	}
	if ctx.username != "coder" {
		t.Errorf("username = %q, want %q", ctx.username, "coder")
	}
	if ctx.network != "custom-net" {
		t.Errorf("network = %q, want %q", ctx.network, "custom-net")
	}
	if ctx.imageTag != "v2" {
		t.Errorf("imageTag = %q, want %q", ctx.imageTag, "v2")
	}
	if len(ctx.sharedVolumes) != 1 || ctx.sharedVolumes[0] != "data:/data" {
		t.Errorf("sharedVolumes = %v, want [data:/data]", ctx.sharedVolumes)
	}
	if len(ctx.repos) != 2 {
		t.Errorf("repos = %v, want [myapp shared-lib]", ctx.repos)
	}
}
