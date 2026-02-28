#!/bin/bash
echo "=== R Installation Status ==="
if command -v R &> /dev/null; then
    R --version | command head -n 1
    echo "R binary: $(which R)"
    echo "R home: $(R RHOME)"
    echo "R library paths:"
    Rscript -e ".libPaths()" | command sed 's/^/  /'
else
    echo "✗ R is not installed"
fi

echo ""
if command -v Rscript &> /dev/null; then
    echo "✓ Rscript is available at $(which Rscript)"
else
    echo "✗ Rscript is not found"
fi
