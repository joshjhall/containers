package cmd

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/term"
)

var agentConnectTimeout int

var agentConnectCmd = &cobra.Command{
	Use:   "connect <N>",
	Short: "Connect to a running agent container",
	Long: `Wait for the agent container to be ready, then exec into it
with an interactive bash shell.

Readiness is determined by the container running and the
agent-ready marker file existing. A spinner shows progress
while waiting.`,
	Args: cobra.ExactArgs(1),
	RunE: runAgentConnect,
}

func init() {
	agentConnectCmd.Flags().IntVar(&agentConnectTimeout, "timeout", 60, "readiness timeout in seconds")
	agentCmd.AddCommand(agentConnectCmd)
}

// spinner characters for animated progress display.
var spinnerChars = []rune("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")

// isTTY checks if the given writer is a terminal.
func isTTY(w io.Writer) bool {
	if f, ok := w.(*os.File); ok {
		return term.IsTerminal(int(f.Fd()))
	}
	return false
}

func runAgentConnect(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadAgentContext(nil)
	if err != nil {
		return err
	}

	n, err := validateAgentNum(args[0], ctx.maxAgents)
	if err != nil {
		return err
	}

	name := containerName(ctx.project, n)
	suffix := agentSuffix(n)
	workdir := filepath.Join(ctx.baseDir, ctx.repos[0]+"-"+suffix)
	readyFile := fmt.Sprintf("/home/%s/.local/state/%s/agent-ready", ctx.username, ctx.project)

	useTTY := isTTY(w)
	deadline := time.Now().Add(time.Duration(agentConnectTimeout) * time.Second)

	// Stage 1: Wait for container to be running.
	if !isContainerRunning(ctx.docker, name) {
		if err := waitWithSpinner(w, useTTY, deadline, "Waiting for container to start", func() bool {
			return isContainerRunning(ctx.docker, name)
		}); err != nil {
			return fmt.Errorf("timeout: container %s is not running after %ds", name, agentConnectTimeout)
		}
	}

	// Stage 2: Wait for readiness marker.
	if err := waitWithSpinner(w, useTTY, deadline, "Waiting for agent initialization", func() bool {
		_, err := ctx.docker.Run("exec", name, "test", "-f", readyFile)
		return err == nil
	}); err != nil {
		fmt.Fprintf(w, "Warning: readiness marker not found, connecting anyway\n")
	}

	// Exec into the container.
	fmt.Fprintf(w, "Connecting to agent %d ...\n", n)
	return ctx.docker.Passthrough(
		"exec", "-it",
		"-u", ctx.username,
		"-w", workdir,
		name,
		"bash", "-l",
	)
}

// waitWithSpinner polls checkFn with animated spinner feedback until it returns
// true or the deadline is reached. Returns nil on success, error on timeout.
func waitWithSpinner(w io.Writer, useTTY bool, deadline time.Time, message string, checkFn func() bool) error {
	ticks := 0
	for {
		elapsed := ticks / 10
		if time.Now().After(deadline) {
			if useTTY {
				fmt.Fprintf(w, "\r\033[K")
			}
			return fmt.Errorf("timeout after %ds", elapsed)
		}
		// Check every second (every 10 ticks).
		if ticks%10 == 0 && checkFn() {
			if useTTY {
				fmt.Fprintf(w, "\r\033[K")
			}
			return nil
		}
		if useTTY {
			i := ticks % len(spinnerChars)
			fmt.Fprintf(w, "\r  %c %s... (%ds)", spinnerChars[i], message, elapsed)
		} else if ticks == 0 {
			fmt.Fprintf(w, "%s...\n", message)
		}
		time.Sleep(100 * time.Millisecond)
		ticks++
	}
}
