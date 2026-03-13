package wizard

import "github.com/charmbracelet/lipgloss"

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("212"))

	subtitleStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("241"))

	successStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("82"))

	autoDepStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("214"))
)
