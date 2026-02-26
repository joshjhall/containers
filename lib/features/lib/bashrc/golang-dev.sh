# ----------------------------------------------------------------------------
# Go Development Tool Aliases and Functions
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# ----------------------------------------------------------------------------
# Go Development Tool Aliases
# ----------------------------------------------------------------------------
# Linting shortcuts
alias gol='golangci-lint run'
alias gosl='staticcheck ./...'
alias gocyc='gocyclo -over 10 .'
alias gosec='gosec ./...'
alias gorev='revive ./...'
alias goerr='errcheck ./...'
alias gocrit='gocritic check ./...'

# Testing shortcuts
alias gotest='richgo test'
alias gotestv='richgo test -v'
alias gotestc='richgo test -cover'
alias gotesta='richgo test ./...'
alias gobench='go test -bench=. -benchmem'
alias gostress='stress'

# Documentation
alias godocs='godoc -http=:6060'
alias goswag='swag init'

# Build and release
alias gorel='goreleaser'
alias gorelc='goreleaser check'
alias goreld='goreleaser release --skip=publish --clean'

# ----------------------------------------------------------------------------
# go-lint-all - Run all linters
# ----------------------------------------------------------------------------
go-lint-all() {
    echo "=== Running all Go linters ==="

    echo "Running golangci-lint..."
    golangci-lint run ./... || true

    echo -e "\nRunning staticcheck..."
    staticcheck ./... || true

    echo -e "\nRunning gosec..."
    gosec -quiet ./... || true

    echo -e "\nRunning errcheck..."
    errcheck ./... || true

    echo -e "\nRunning ineffassign..."
    ineffassign ./... || true

    echo -e "\nChecking for vulnerabilities..."
    govulncheck ./... || true
}

# ----------------------------------------------------------------------------
# go-security-check - Run security scanners
# ----------------------------------------------------------------------------
go-security-check() {
    echo "=== Running Go security scanners ==="

    echo "Running gosec (static security analysis)..."
    gosec ./... || true

    echo -e "\nRunning govulncheck (vulnerability database)..."
    govulncheck ./... || true
}

# ----------------------------------------------------------------------------
# go-test-coverage - Run tests with detailed coverage report
# ----------------------------------------------------------------------------
go-test-coverage() {
    echo "=== Running tests with coverage ==="

    # Run tests with coverage
    richgo test -coverprofile=coverage.out -covermode=atomic ./...

    # Generate coverage report
    echo -e "\n=== Coverage Summary ==="
    go tool cover -func=coverage.out | tail -n 1

    # Generate HTML report
    go tool cover -html=coverage.out -o coverage.html
    echo -e "\nDetailed coverage report: coverage.html"
}

# ----------------------------------------------------------------------------
# go-generate-tests - Generate test files for functions
#
# Arguments:
#   $1 - File or directory path (optional, defaults to current directory)
#
# Example:
#   go-generate-tests
#   go-generate-tests pkg/utils/
# ----------------------------------------------------------------------------
go-generate-tests() {
    local target="${1:-.}"
    echo "Generating tests for: $target"

    if [ -f "$target" ]; then
        gotests -all -w "$target"
    else
        command find "$target" -name "*.go" -not -name "*_test.go" -not -path "*/vendor/*" | while read -r file; do
            echo "Generating tests for $file"
            gotests -all -w "$file"
        done
    fi
}

# ----------------------------------------------------------------------------
# go-mock-gen - Generate mocks for interfaces
#
# Arguments:
#   $1 - Source file containing interfaces (required)
#   $2 - Destination package (optional, defaults to mocks)
#
# Example:
#   go-mock-gen internal/service/interface.go
#   go-mock-gen internal/service/interface.go internal/mocks
# ----------------------------------------------------------------------------
go-mock-gen() {
    if [ -z "$1" ]; then
        echo "Usage: go-mock-gen <interface-file> [destination-package]"
        return 1
    fi

    local source="$1"
    local dest="${2:-mocks}"
    local source_file
    source_file=$(basename "$source" .go)

    echo "Generating mocks for interfaces in $source"

    # Create destination directory
    mkdir -p "$dest"

    # Generate mock
    mockgen -source="$source" -destination="$dest/mock_${source_file}.go" -package="$(basename $dest)"
}

# ----------------------------------------------------------------------------
# go-visualize - Visualize Go code structure
#
# Arguments:
#   $1 - Package to visualize (optional, defaults to main)
#
# Example:
#   go-visualize
#   go-visualize ./cmd/app
# ----------------------------------------------------------------------------
go-visualize() {
    local pkg="${1:-main}"
    echo "Generating visualization for package: $pkg"

    # Generate call graph
    go-callvis -group pkg,type -focus "$pkg" . &
    local pid=$!

    echo "Visualization server started at http://localhost:7878"
    echo "Press Ctrl+C to stop"

    # Wait for interrupt
    trap 'kill $pid 2>/dev/null; exit' INT
    wait $pid
}

# ----------------------------------------------------------------------------
# go-profile-cpu - Profile CPU usage
#
# Arguments:
#   $1 - Command to profile (required)
#   $@ - Additional arguments for the command
#
# Example:
#   go-profile-cpu ./myapp
#   go-profile-cpu go test -bench=.
# ----------------------------------------------------------------------------
go-profile-cpu() {
    if [ -z "$1" ]; then
        echo "Usage: go-profile-cpu <command> [args...]"
        return 1
    fi

    echo "Profiling CPU usage..."

    # Run with CPU profiling
    CPUPROFILE=cpu.prof "$@"

    echo "Opening profile in browser..."
    go tool pprof -http=:8080 cpu.prof
}

# ----------------------------------------------------------------------------
# go-check-deps - Check dependencies for issues
# ----------------------------------------------------------------------------
go-check-deps() {
    echo "=== Checking Go dependencies ==="

    echo "Checking for vulnerabilities..."
    govulncheck ./...

    echo -e "\nChecking for outdated dependencies..."
    go list -u -m all | grep '\['

    echo -e "\nDependency graph:"
    goda graph "..." | head -20
    echo "(Showing first 20 lines, run 'goda graph ...' for full output)"
}

# ----------------------------------------------------------------------------
# go-benchmark-compare - Compare benchmark results
#
# Arguments:
#   $1 - Old benchmark file (required)
#   $2 - New benchmark file (required)
#
# Example:
#   go test -bench=. > old.txt
#   # make changes
#   go test -bench=. > new.txt
#   go-benchmark-compare old.txt new.txt
# ----------------------------------------------------------------------------
go-benchmark-compare() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: go-benchmark-compare <old-benchmark> <new-benchmark>"
        return 1
    fi

    echo "Comparing benchmark results..."
    benchstat "$1" "$2"
}

# ----------------------------------------------------------------------------
# go-live - Run with live reload using air
#
# Arguments:
#   $@ - Additional arguments for air
#
# Example:
#   go-live
#   go-live --build.cmd "go build -o ./tmp/main ."
# ----------------------------------------------------------------------------
go-live() {
    if [ ! -f .air.toml ]; then
        echo "Initializing air configuration..."
        air init
    fi

    echo "Starting live reload server..."
    air "$@"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
