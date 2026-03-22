package cmd

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	igorconfig "github.com/joshjhall/containers/cmd/igor/internal/config"
)

// setupServiceTest creates a temp dir with .igor.yml containing services and chdirs into it.
func setupServiceTest(t *testing.T, cfg *igorconfig.IgorConfig) (*mockDocker, string) {
	t.Helper()
	return setupAgentTest(t, cfg)
}

// executeServicesCmd runs a services subcommand with the mock docker runner injected.
func executeServicesCmd(t *testing.T, mock *mockDocker, args ...string) (string, error) {
	t.Helper()
	var buf bytes.Buffer
	rootCmd.SetOut(&buf)
	defer rootCmd.SetOut(nil)

	configFile = ""
	servicesStopClean = false

	origOverride := servicesDockerOverride
	servicesDockerOverride = mock
	defer func() { servicesDockerOverride = origOverride }()

	rootCmd.SetArgs(append([]string{"services"}, args...))
	err := rootCmd.Execute()
	return buf.String(), err
}

func serviceTestConfig() *igorconfig.IgorConfig {
	return &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Agents:        igorconfig.AgentConfig{Max: 3},
		Services: map[string]igorconfig.ServiceConfig{
			"postgres": {
				Image:       "postgres:16",
				Environment: []string{"POSTGRES_USER=postgres", "POSTGRES_PASSWORD=devpassword"},
				Volumes:     []string{"pgdata:/var/lib/postgresql/data"},
				Port:        5432,
				PerAgentDB:  true,
			},
		},
	}
}

// --- ServiceContainerName ---

func TestServiceContainerName(t *testing.T) {
	tests := []struct {
		project string
		svc     string
		want    string
	}{
		{"myapp", "postgres", "myapp-postgres"},
		{"project", "redis", "project-redis"},
	}
	for _, tt := range tests {
		got := serviceContainerName(tt.project, tt.svc)
		if got != tt.want {
			t.Errorf("serviceContainerName(%q, %q) = %q, want %q", tt.project, tt.svc, got, tt.want)
		}
	}
}

// --- ExtractPgCredentials ---

func TestExtractPgCredentials(t *testing.T) {
	tests := []struct {
		name     string
		env      []string
		wantUser string
		wantPass string
	}{
		{
			"explicit values",
			[]string{"POSTGRES_USER=admin", "POSTGRES_PASSWORD=secret"},
			"admin", "secret",
		},
		{
			"defaults when empty",
			[]string{},
			"postgres", "devpassword",
		},
		{
			"partial — only user",
			[]string{"POSTGRES_USER=myuser"},
			"myuser", "devpassword",
		},
		{
			"malformed entry ignored",
			[]string{"BADFORMAT", "POSTGRES_PASSWORD=pw"},
			"postgres", "pw",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			user, pass := extractPgCredentials(tt.env)
			if user != tt.wantUser {
				t.Errorf("user = %q, want %q", user, tt.wantUser)
			}
			if pass != tt.wantPass {
				t.Errorf("password = %q, want %q", pass, tt.wantPass)
			}
		})
	}
}

// --- PerAgentDBURL ---

func TestPerAgentDBURL(t *testing.T) {
	svc := igorconfig.ServiceConfig{
		Image:       "postgres:16",
		Environment: []string{"POSTGRES_USER=postgres", "POSTGRES_PASSWORD=devpassword"},
		Port:        5432,
		PerAgentDB:  true,
	}

	url := perAgentDBURL("myapp", 1, "postgres", svc)
	want := "postgres://postgres:devpassword@myapp-postgres:5432/myapp_agent01"
	if url != want {
		t.Errorf("perAgentDBURL() = %q, want %q", url, want)
	}

	url = perAgentDBURL("myapp", 5, "postgres", svc)
	want = "postgres://postgres:devpassword@myapp-postgres:5432/myapp_agent05"
	if url != want {
		t.Errorf("perAgentDBURL() = %q, want %q", url, want)
	}
}

// --- Services Start ---

func TestServicesStart_NewContainer(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["network inspect"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["network create"] = mockResult{output: "ok", err: nil}

	out, err := executeServicesCmd(t, mock, "start", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Creating container") {
		t.Errorf("expected 'Creating container', got: %s", out)
	}
	if !strings.Contains(out, "started") {
		t.Errorf("expected 'started', got: %s", out)
	}
	if !mock.hasCall("run -d") {
		t.Error("expected docker run -d call")
	}
	if !mock.hasCall("--name myproject-postgres") {
		t.Error("expected --name myproject-postgres")
	}
	if !mock.hasCall("-e POSTGRES_USER=postgres") {
		t.Error("expected POSTGRES_USER env var")
	}
	if !mock.hasCall("postgres:16") {
		t.Error("expected postgres:16 image")
	}
}

func TestServicesStart_AlreadyRunning(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeServicesCmd(t, mock, "start", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "already running") {
		t.Errorf("expected 'already running', got: %s", out)
	}
}

func TestServicesStart_Stopped(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	callNum := 0
	mock.runFunc = func(args ...string) (string, error) {
		if len(args) >= 2 && args[0] == "inspect" && args[1] == "-f" {
			callNum++
			if callNum == 1 {
				return "false", nil // isContainerRunning → not running
			}
			return "exited", nil // containerExists → yes
		}
		if args[0] == "start" {
			return "", nil
		}
		return "", nil
	}

	out, err := executeServicesCmd(t, mock, "start", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Starting stopped container") {
		t.Errorf("expected 'Starting stopped container', got: %s", out)
	}
}

func TestServicesStart_UnknownService(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	_, err := executeServicesCmd(t, mock, "start", "nonexistent")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "not defined") {
		t.Errorf("error should mention 'not defined', got: %v", err)
	}
}

// --- Services Stop ---

func TestServicesStop_Running(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeServicesCmd(t, mock, "stop", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "stopped") {
		t.Errorf("expected 'stopped', got: %s", out)
	}
	if !mock.hasCall("stop myproject-postgres") {
		t.Error("expected docker stop call")
	}
}

func TestServicesStop_NotRunning(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}

	out, err := executeServicesCmd(t, mock, "stop", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "not running") {
		t.Errorf("expected 'not running', got: %s", out)
	}
}

func TestServicesStop_WithClean(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeServicesCmd(t, mock, "stop", "--clean", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "stopped") {
		t.Errorf("expected 'stopped', got: %s", out)
	}
	if !strings.Contains(out, "removed") {
		t.Errorf("expected 'removed', got: %s", out)
	}
	if !mock.hasCall("stop myproject-postgres") {
		t.Error("expected docker stop call")
	}
	if !mock.hasCall("rm -v myproject-postgres") {
		t.Error("expected docker rm -v call")
	}
}

// --- Services Status ---

func TestServicesStatus_Table(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}

	out, err := executeServicesCmd(t, mock, "status")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "myproject-postgres") {
		t.Errorf("expected container name, got: %s", out)
	}
	if !strings.Contains(out, "postgres:16") {
		t.Errorf("expected image name, got: %s", out)
	}
	if !strings.Contains(out, "not created") {
		t.Errorf("expected 'not created' status, got: %s", out)
	}
}

// --- Services Reset ---

func TestServicesReset_PerAgentDB(t *testing.T) {
	cfg := serviceTestConfig()
	mock, _ := setupServiceTest(t, cfg)

	mock.runFunc = func(args ...string) (string, error) {
		if len(args) >= 2 && args[0] == "inspect" && args[1] == "-f" {
			return "true", nil // container running
		}
		if len(args) >= 2 && args[0] == "exec" {
			return "", nil // psql commands succeed
		}
		return "", nil
	}

	out, err := executeServicesCmd(t, mock, "reset", "postgres")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "Resetting per-agent databases") {
		t.Errorf("expected reset message, got: %s", out)
	}
	// Should reset databases for agents 1-3 (max=3).
	for i := 1; i <= 3; i++ {
		dbName := fmt.Sprintf("myproject_agent%02d", i)
		if !strings.Contains(out, dbName+" reset") {
			t.Errorf("expected %s reset, got: %s", dbName, out)
		}
	}
	// Should have DROP and CREATE calls for each agent.
	dropCount := 0
	createCount := 0
	for _, call := range mock.calls {
		joined := strings.Join(call, " ")
		if strings.Contains(joined, "DROP DATABASE") {
			dropCount++
		}
		if strings.Contains(joined, "CREATE DATABASE") {
			createCount++
		}
	}
	if dropCount != 3 {
		t.Errorf("expected 3 DROP calls, got %d", dropCount)
	}
	if createCount != 3 {
		t.Errorf("expected 3 CREATE calls, got %d", createCount)
	}
}

func TestServicesReset_NonDB(t *testing.T) {
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Services: map[string]igorconfig.ServiceConfig{
			"redis": {Image: "redis:7", Port: 6379},
		},
	}
	mock, _ := setupServiceTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "true", err: nil}

	out, err := executeServicesCmd(t, mock, "reset", "redis")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "container removed") {
		t.Errorf("expected 'container removed', got: %s", out)
	}
	if !mock.hasCall("stop myproject-redis") {
		t.Error("expected docker stop call")
	}
	if !mock.hasCall("rm myproject-redis") {
		t.Error("expected docker rm call")
	}
}

// --- Agent Start with PerAgentDB ---

func TestAgentStart_WithPerAgentDB(t *testing.T) {
	cfg := serviceTestConfig()
	cfg.Features = []string{"python"}
	mock, _ := setupAgentTest(t, cfg)

	agentCreated := false
	mock.runFunc = func(args ...string) (string, error) {
		joined := strings.Join(args, " ")
		if len(args) >= 2 && args[0] == "inspect" && args[1] == "-f" {
			// After agent container is created, service container check must return running.
			if agentCreated && strings.Contains(joined, "myproject-postgres") {
				return "true", nil
			}
			return "", fmt.Errorf("not found") // agent container doesn't exist
		}
		if len(args) >= 2 && args[0] == "image" && args[1] == "inspect" {
			return "ok", nil
		}
		if len(args) >= 2 && args[0] == "network" && args[1] == "inspect" {
			return "ok", nil
		}
		if args[0] == "run" && strings.Contains(joined, "sleep infinity") {
			agentCreated = true
			return "abc123", nil
		}
		if len(args) >= 2 && args[0] == "exec" {
			if strings.Contains(joined, "SELECT 1 FROM pg_database") {
				return "", nil // empty = DB doesn't exist
			}
			if strings.Contains(joined, "CREATE DATABASE") {
				return "CREATE DATABASE", nil
			}
			return "", nil // pg_isready etc.
		}
		return "", nil
	}

	out, err := executeAgentCmd(t, mock, "start", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "started") {
		t.Errorf("expected 'started', got: %s", out)
	}

	// Verify DATABASE_URL was injected.
	if !mock.hasCall("DATABASE_URL=postgres://postgres:devpassword@myproject-postgres:5432/myproject_agent01") {
		t.Error("expected DATABASE_URL env var in docker run args")
	}

	// Verify psql was called to check/create the database.
	if !mock.hasCall("psql") {
		t.Error("expected psql call for database provisioning")
	}
}

func TestAgentStart_NoServices(t *testing.T) {
	// Ensure existing behavior is preserved when no services are configured.
	cfg := &igorconfig.IgorConfig{
		SchemaVersion: 1,
		ContainersDir: "containers",
		Project:       igorconfig.ProjectConfig{Name: "myproject", Username: "dev"},
		Features:      []string{"python"},
	}
	mock, _ := setupAgentTest(t, cfg)

	mock.matchResults["inspect -f"] = mockResult{output: "", err: fmt.Errorf("not found")}
	mock.matchResults["image inspect"] = mockResult{output: "ok", err: nil}
	mock.matchResults["network inspect"] = mockResult{output: "ok", err: nil}

	out, err := executeAgentCmd(t, mock, "start", "1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(out, "started") {
		t.Errorf("expected 'started', got: %s", out)
	}

	// Verify no DATABASE_URL was injected.
	if mock.hasCall("DATABASE_URL") {
		t.Error("should not inject DATABASE_URL when no services configured")
	}
}
