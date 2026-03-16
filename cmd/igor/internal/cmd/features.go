package cmd

import (
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/joshjhall/containers/cmd/igor/internal/feature"
)

var featuresFormat string

var featuresCmd = &cobra.Command{
	Use:   "features",
	Short: "List all available container features",
	RunE: func(cmd *cobra.Command, args []string) error {
		reg := feature.NewRegistry()
		w := cmd.OutOrStdout()

		switch featuresFormat {
		case "table":
			printFeaturesTable(w, reg)
		case "markdown":
			printFeaturesMarkdown(w, reg)
		default:
			return fmt.Errorf("unknown format %q (use table or markdown)", featuresFormat)
		}
		return nil
	},
}

func init() {
	featuresCmd.Flags().StringVar(&featuresFormat, "format", "table", "output format: table, markdown")
	rootCmd.AddCommand(featuresCmd)
}

var categoryOrder = []struct {
	cat   feature.Category
	label string
}{
	{feature.CategoryLanguage, "Languages"},
	{feature.CategoryTool, "Tools"},
	{feature.CategoryCloud, "Cloud & Infrastructure"},
	{feature.CategoryDatabase, "Database Clients"},
	{feature.CategoryAI, "AI/ML"},
}

func printFeaturesTable(w io.Writer, reg *feature.Registry) {
	for i, c := range categoryOrder {
		features := reg.ByCategory(c.cat)
		if len(features) == 0 {
			continue
		}
		if i > 0 {
			fmt.Fprintln(w)
		}
		fmt.Fprintf(w, "%s:\n", c.label)
		tw := tabwriter.NewWriter(w, 2, 0, 2, ' ', 0)
		fmt.Fprintf(tw, "  ID\tBuild Arg\tVersion Arg\tDefault\tRequires\n")
		for _, f := range features {
			fmt.Fprintf(tw, "  %s\t%s\t%s\t%s\t%s\n",
				f.ID, f.BuildArg,
				dash(f.VersionArg), dash(f.DefaultVersion),
				formatSlice(f.Requires),
			)
		}
		tw.Flush()
	}
}

func printFeaturesMarkdown(w io.Writer, reg *feature.Registry) {
	for i, c := range categoryOrder {
		features := reg.ByCategory(c.cat)
		if len(features) == 0 {
			continue
		}
		if i > 0 {
			fmt.Fprintln(w)
		}
		fmt.Fprintf(w, "## %s\n\n", c.label)
		fmt.Fprintln(w, "| ID | Display Name | Build Arg | Version Arg | Default | Requires | Implied By |")
		fmt.Fprintln(w, "|----|-------------|-----------|-------------|---------|----------|------------|")
		for _, f := range features {
			fmt.Fprintf(w, "| %s | %s | %s | %s | %s | %s | %s |\n",
				f.ID, f.DisplayName, f.BuildArg,
				dash(f.VersionArg), dash(f.DefaultVersion),
				formatSlice(f.Requires), formatSlice(f.ImpliedBy),
			)
		}
	}
}

func formatSlice(s []string) string {
	if len(s) == 0 {
		return "-"
	}
	return strings.Join(s, ", ")
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
