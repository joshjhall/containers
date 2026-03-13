package template

import "embed"

//go:embed sources/*
var templateFS embed.FS
