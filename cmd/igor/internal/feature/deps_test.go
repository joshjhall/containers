package feature

import (
	"testing"
)

func TestResolve_KotlinImpliesJava(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"kotlin": true}, reg)

	if !sel.Has("java") {
		t.Error("kotlin should auto-select java")
	}
	if !sel.Auto["java"] {
		t.Error("java should be in Auto set, not Explicit")
	}
	if !sel.Explicit["kotlin"] {
		t.Error("kotlin should remain in Explicit set")
	}
}

func TestResolve_DevToolsChain(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"dev_tools": true}, reg)

	// dev_tools → bindfs → cron
	if !sel.Has("bindfs") {
		t.Error("dev_tools should auto-select bindfs")
	}
	if !sel.Has("cron") {
		t.Error("dev_tools should auto-select cron (via bindfs)")
	}
}

func TestResolve_RustDevImpliesCron(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"rust_dev": true}, reg)

	// rust_dev requires rust and cron
	if !sel.Has("rust") {
		t.Error("rust_dev should auto-select rust")
	}
	if !sel.Has("cron") {
		t.Error("rust_dev should auto-select cron")
	}
}

func TestResolve_DevImpliesBase(t *testing.T) {
	reg := NewRegistry()

	cases := []struct {
		dev  string
		base string
	}{
		{"python_dev", "python"},
		{"node_dev", "node"},
		{"rust_dev", "rust"},
		{"golang_dev", "golang"},
		{"ruby_dev", "ruby"},
		{"java_dev", "java"},
		{"r_dev", "r"},
		{"mojo_dev", "mojo"},
		{"kotlin_dev", "kotlin"},
		{"android_dev", "android"},
	}

	for _, tc := range cases {
		sel := Resolve(map[string]bool{tc.dev: true}, reg)
		if !sel.Has(tc.base) {
			t.Errorf("%s should auto-select %s", tc.dev, tc.base)
		}
	}
}

func TestResolve_CloudflareImpliesNode(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"cloudflare": true}, reg)

	if !sel.Has("node") {
		t.Error("cloudflare should auto-select node")
	}
}

func TestResolve_AndroidImpliesJava(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"android": true}, reg)

	if !sel.Has("java") {
		t.Error("android should auto-select java")
	}
}

func TestResolve_NoExtraDeps(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"python": true}, reg)

	if len(sel.Auto) != 0 {
		t.Errorf("python alone should have no auto deps, got: %v", sel.Auto)
	}
}

func TestResolve_CronImpliedByBindfs(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"bindfs": true}, reg)

	if !sel.Has("cron") {
		t.Error("bindfs should auto-select cron (via Requires)")
	}
}

func TestSelection_All(t *testing.T) {
	sel := &Selection{
		Explicit: map[string]bool{"python": true, "node": true},
		Auto:     map[string]bool{"cron": true},
	}
	all := sel.All()
	if len(all) != 3 {
		t.Errorf("expected 3 features, got %d", len(all))
	}
}

func TestResolve_BindfsImpliedByDevTools(t *testing.T) {
	reg := NewRegistry()
	sel := Resolve(map[string]bool{"dev_tools": true}, reg)

	// bindfs has ImpliedBy: ["dev_tools"]
	if !sel.Has("bindfs") {
		t.Error("bindfs should be implied by dev_tools")
	}
	if !sel.Auto["bindfs"] {
		t.Error("bindfs should be in Auto set")
	}
}
