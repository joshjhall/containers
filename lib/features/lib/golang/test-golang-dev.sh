#!/bin/bash
echo "=== Go Development Tools Status ==="

# Check core development tools
echo ""
echo "Core development tools:"
for tool in gopls dlv golangci-lint goimports gomodifytags impl goplay; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check linting tools
echo ""
echo "Linting tools:"
for tool in staticcheck gosec revive errcheck ineffassign gocritic gocyclo gocognit goconst godot; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check testing tools
echo ""
echo "Testing tools:"
for tool in gotests mockgen richgo benchstat govulncheck stress; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check workflow tools
echo ""
echo "Workflow tools:"
for tool in air goreleaser ko swag wire godoc; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check analysis tools
echo ""
echo "Analysis tools:"
for tool in go-callvis goda; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

# Check protobuf tools
echo ""
echo "Protobuf tools:"
for tool in protoc-gen-go protoc-gen-go-grpc; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Run 'go-lint-all' to run all linters"
echo "Run 'go-test-coverage' to generate coverage report"
