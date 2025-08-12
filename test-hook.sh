#!/bin/bash
# Test file with shellcheck issues

# SC2086: Quote to prevent word splitting
echo $1

# SC2034: Unused variable
UNUSED_VAR="test"

# This is fine
echo "Hello world"