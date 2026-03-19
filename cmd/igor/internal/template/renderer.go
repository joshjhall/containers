package template

import (
	"bytes"
	"fmt"
	"text/template"
)

// Renderer renders embedded templates with a RenderContext.
type Renderer struct {
	templates *template.Template
}

// NewRenderer parses all embedded template sources.
func NewRenderer() (*Renderer, error) {
	tmpl, err := template.New("").Funcs(funcMap()).ParseFS(templateFS, "sources/*.tmpl")
	if err != nil {
		return nil, fmt.Errorf("parsing templates: %w", err)
	}
	return &Renderer{templates: tmpl}, nil
}

// Render executes the named template with the given context and returns the output.
func (r *Renderer) Render(name string, ctx *RenderContext) (string, error) {
	var buf bytes.Buffer
	if err := r.templates.ExecuteTemplate(&buf, name, ctx); err != nil {
		return "", fmt.Errorf("rendering %s: %w", name, err)
	}
	return buf.String(), nil
}
