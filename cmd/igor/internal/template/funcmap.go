package template

import (
	"strings"
	"text/template"
)

func funcMap() template.FuncMap {
	return template.FuncMap{
		"hasFeature": func(ctx *RenderContext, id string) bool {
			return ctx.Selection.Has(id)
		},
		"indent": func(n int, s string) string {
			pad := strings.Repeat(" ", n)
			lines := strings.Split(s, "\n")
			for i, line := range lines {
				if line != "" {
					lines[i] = pad + line
				}
			}
			return strings.Join(lines, "\n")
		},
		"joinComma": func(items []string) string {
			return strings.Join(items, ", ")
		},
		"buildArgLines": func(ctx *RenderContext) string {
			var lines []string
			for _, f := range ctx.EnabledFeatures {
				lines = append(lines, "- "+f.BuildArg+"=true")
				if f.VersionArg != "" {
					ver := ctx.Versions[f.VersionArg]
					if ver == "" {
						ver = f.DefaultVersion
					}
					lines = append(lines, "- "+f.VersionArg+"="+ver)
				}
			}
			return strings.Join(lines, "\n")
		},
		"add": func(a, b int) int {
			return a + b
		},
		"sub": func(a, b int) int {
			return a - b
		},
		"contains": func(s, substr string) bool {
			return strings.Contains(s, substr)
		},
		"split": func(s, sep string) []string {
			return strings.Split(s, sep)
		},
	}
}
