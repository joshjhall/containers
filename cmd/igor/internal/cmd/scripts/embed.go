package scripts

import "embed"

//go:embed *.sh
var AgentScripts embed.FS
