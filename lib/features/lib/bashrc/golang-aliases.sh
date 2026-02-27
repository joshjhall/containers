# shellcheck disable=SC2155

# ----------------------------------------------------------------------------
# Go Aliases
# ----------------------------------------------------------------------------
alias gob='go build'
alias gor='go run'
alias got='go test'
alias gotv='go test -v'
alias gotc='go test -cover'
alias gof='go fmt'
alias gom='go mod'
alias gomt='go mod tidy'
alias gomd='go mod download'
alias gomi='go mod init'
alias gomv='go mod vendor'
alias gols='go list'

# ----------------------------------------------------------------------------
# go-init - Create a new Go module project
#
# Arguments:
#   $1 - Module name (required, e.g., github.com/user/project)
#   $2 - Project type (optional: cli, lib, api, default: lib)
#
# Example:
#   go-init github.com/myuser/myproject cli
# ----------------------------------------------------------------------------
go-init() {
    if [ -z "$1" ]; then
        echo "Usage: go-init <module-name> [type]"
        echo "Types: cli, lib, api"
        return 1
    fi

    local module_name="$1"
    local project_type="${2:-lib}"

    # Validate module name format (typical Go module path)
    if ! [[ "$module_name" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        echo "Error: Invalid module name format" >&2
        echo "Module name should contain only alphanumeric, dots, dashes, slashes, and underscores" >&2
        return 1
    fi

    # Validate project type
    case "$project_type" in
        cli|lib|api)
            # Valid types
            ;;
        *)
            echo "Error: Invalid project type '$project_type'" >&2
            echo "Valid types: cli, lib, api" >&2
            return 1
            ;;
    esac

    local project_dir=$(basename "$module_name")

    # Sanitize project directory name (remove any path traversal attempts)
    project_dir=$(echo "$project_dir" | tr -cd 'a-zA-Z0-9._-')

    if [ -z "$project_dir" ] || [ "$project_dir" = "." ] || [ "$project_dir" = ".." ]; then
        echo "Error: Invalid project directory name after sanitization" >&2
        return 1
    fi

    echo "Creating new Go project: $module_name (type: $project_type)"

    # Create project directory
    mkdir -p "$project_dir"
    cd "$project_dir" || return 1

    # Initialize go module
    go mod init "$module_name"

    # Create standard Go project structure
    mkdir -p cmd pkg internal test docs

    # Create .gitignore
    load_go_template "common/gitignore.tmpl" > .gitignore

    # Create type-specific files
    case "$project_type" in
        cli)
            mkdir -p cmd/${project_dir}
            load_go_template "cli/main.go.tmpl" > cmd/${project_dir}/main.go
            ;;
        api)
            load_go_template "api/main.go.tmpl" > main.go
            ;;
        *)
            # Default library setup
            load_go_template "lib/lib.go.tmpl" "$project_dir" > ${project_dir}.go
            load_go_template "lib/lib_test.go.tmpl" "$project_dir" > ${project_dir}_test.go
            ;;
    esac

    # Create Makefile
    load_go_template "common/Makefile.tmpl" > Makefile

    echo "Project $project_dir created successfully!"
    echo ""
    echo "Next steps:"
    echo "  cd $project_dir"
    echo "  go mod tidy"
    echo "  make test"
}

# ----------------------------------------------------------------------------
# go-bench - Run benchmarks with nice output
#
# Arguments:
#   $@ - Additional arguments to pass to go test -bench
#
# Example:
#   go-bench
#   go-bench -benchtime=10s
# ----------------------------------------------------------------------------
go-bench() {
    echo "Running Go benchmarks..."
    go test -bench=. -benchmem "$@" | tee benchmark_results.txt
    echo ""
    echo "Results saved to benchmark_results.txt"
}

# ----------------------------------------------------------------------------
# go-cover - Run tests with coverage and open HTML report
# ----------------------------------------------------------------------------
go-cover() {
    echo "Running tests with coverage..."
    go test -coverprofile=coverage.out ./...
    go tool cover -html=coverage.out -o coverage.html
    echo "Coverage report generated: coverage.html"

    # Try to open in browser if possible
    if command -v xdg-open &> /dev/null; then
        xdg-open coverage.html
    elif command -v open &> /dev/null; then
        open coverage.html
    fi
}

# ----------------------------------------------------------------------------
# go-deps - Show module dependencies as a tree
# ----------------------------------------------------------------------------
go-deps() {
    if [ -f go.mod ]; then
        echo "=== Direct dependencies ==="
        go list -m -f '{{.Path}} {{.Version}}' all | grep -v '^[[:space:]]'
        echo ""
        echo "=== Full dependency tree ==="
        go mod graph
    else
        echo "No go.mod found in current directory"
    fi
}

# ----------------------------------------------------------------------------
# go-update - Update all dependencies to latest versions
# ----------------------------------------------------------------------------
go-update() {
    if [ -f go.mod ]; then
        echo "Updating Go dependencies to latest versions..."
        go get -u ./...
        go mod tidy
        echo "Dependencies updated. Run 'go test ./...' to verify."
    else
        echo "No go.mod found in current directory"
    fi
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
