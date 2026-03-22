package scripts

import (
	"testing"
)

func TestAgentScriptsEmbed(t *testing.T) {
	wantFiles := []string{
		"agent-entrypoint.sh",
		"agent-init.sh",
		"agent-start.sh",
	}

	for _, name := range wantFiles {
		data, err := AgentScripts.ReadFile(name)
		if err != nil {
			t.Errorf("failed to read embedded %s: %v", name, err)
			continue
		}
		if len(data) == 0 {
			t.Errorf("embedded %s is empty", name)
		}
		// Verify shebang line.
		if string(data[:2]) != "#!" {
			t.Errorf("embedded %s missing shebang", name)
		}
	}
}
