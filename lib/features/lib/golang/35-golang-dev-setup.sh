#!/bin/bash
# Go development tools configuration
if command -v go &> /dev/null; then
    echo "=== Go Development Tools ==="

    # Check for .golangci.yml
    if [ -f ${WORKING_DIR}/.golangci.yml ] || [ -f ${WORKING_DIR}/.golangci.yaml ]; then
        echo "golangci-lint configuration detected"
        echo "Run 'golangci-lint run' to lint your code"
    fi

    # Check for Makefile
    if [ -f ${WORKING_DIR}/Makefile ]; then
        if grep -q "test:" ${WORKING_DIR}/Makefile 2>/dev/null; then
            echo "Makefile with test target detected"
            echo "Run 'make test' to run tests"
        fi
    fi

    # Check for .goreleaser.yml
    if [ -f ${WORKING_DIR}/.goreleaser.yml ] || [ -f ${WORKING_DIR}/.goreleaser.yaml ]; then
        echo "GoReleaser configuration detected"
        echo "Run 'goreleaser check' to validate config"
    fi

    # Show available dev tools
    echo ""
    echo "Go development tools available:"
    echo "  Linting: golangci-lint, staticcheck, gosec, revive, errcheck"
    echo "  Testing: gotests, mockgen, richgo, benchstat"
    echo "  Analysis: go-callvis, goda, govulncheck"
    echo "  Workflow: air (live reload), goreleaser, ko"
    echo ""
    echo "Helpful commands:"
    echo "  go-lint-all         - Run all linters"
    echo "  go-test-coverage    - Generate coverage report"
    echo "  go-generate-tests   - Generate test files"
    echo "  go-visualize        - Visualize code structure"
    echo "  go-live            - Run with live reload"
fi
