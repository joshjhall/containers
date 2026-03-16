package main

import (
	"os"
	"runtime/debug"

	"github.com/joshjhall/containers/cmd/igor/internal/cmd"
)

func init() {
	// For dev builds, populate BuildTime from VCS info if not set via ldflags.
	if cmd.Version == "dev" && cmd.BuildTime == "" {
		if info, ok := debug.ReadBuildInfo(); ok {
			for _, s := range info.Settings {
				if s.Key == "vcs.time" {
					cmd.BuildTime = s.Value
					break
				}
			}
		}
	}
}

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
