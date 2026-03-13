package main

import (
	"os"

	"github.com/joshjhall/containers/cmd/igor/internal/cmd"
)

func main() {
	if err := cmd.Execute(); err != nil {
		os.Exit(1)
	}
}
