package cmd

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"
)

var agentBuildDryRun bool

var agentBuildCmd = &cobra.Command{
	Use:   "build",
	Short: "Build the agent container image",
	Long: `Build a Docker image for agent containers using the features
and versions defined in .igor.yml.

Build args are derived from the feature registry. The image is tagged
as <project>-agent:<tag> (default tag: latest).`,
	RunE: runAgentBuild,
}

func init() {
	agentBuildCmd.Flags().BoolVar(&agentBuildDryRun, "dry-run", false, "print docker command without executing")
	agentCmd.AddCommand(agentBuildCmd)
}

func runAgentBuild(cmd *cobra.Command, args []string) error {
	w := cmd.OutOrStdout()

	ctx, err := loadAgentContext(nil)
	if err != nil {
		return err
	}

	// Ensure shared volumes exist.
	if !agentBuildDryRun {
		for _, vol := range ctx.sharedVolumes {
			volName := strings.SplitN(vol, ":", 2)[0]
			if _, err := ctx.docker.Run("volume", "inspect", volName); err != nil {
				if _, err := ctx.docker.Run("volume", "create", volName); err != nil {
					return fmt.Errorf("creating volume %s: %w", volName, err)
				}
				fmt.Fprintf(w, "Created volume %s\n", volName)
			}
		}
	}

	// Build docker build command.
	dockerArgs := []string{
		"build",
		"-t", ctx.imageName + ":" + ctx.imageTag,
		"-f", ctx.containersDir + "/Dockerfile",
		"--build-arg", "PROJECT_PATH=.",
		"--build-arg", "PROJECT_NAME=" + ctx.project,
		"--build-arg", "USERNAME=" + ctx.username,
	}

	for _, f := range ctx.features {
		dockerArgs = append(dockerArgs, "--build-arg", f.BuildArg+"=true")
	}

	for argName, version := range ctx.versions {
		dockerArgs = append(dockerArgs, "--build-arg", argName+"="+version)
	}

	dockerArgs = append(dockerArgs, ctx.containersDir)

	if agentBuildDryRun {
		fmt.Fprintf(w, "docker %s\n", strings.Join(dockerArgs, " "))
		return nil
	}

	fmt.Fprintf(w, "Building %s:%s ...\n", ctx.imageName, ctx.imageTag)
	return ctx.docker.Passthrough(dockerArgs...)
}
