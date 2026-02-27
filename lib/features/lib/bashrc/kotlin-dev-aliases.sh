# shellcheck disable=SC2046

# ----------------------------------------------------------------------------
# Kotlin Development Aliases
# ----------------------------------------------------------------------------
# ktlint shortcuts
alias ktf='ktlint -F'          # Format files
alias ktcheck='ktlint'          # Check files
alias ktfmt='ktlint -F'         # Alias for format

# detekt shortcuts
alias dkt='detekt'
alias dktcheck='detekt --build-upon-default-config'

# ----------------------------------------------------------------------------
# ktlint-all - Run ktlint on all Kotlin files in current directory
# ----------------------------------------------------------------------------
ktlint-all() {
    echo "=== Running ktlint on all Kotlin files ==="
    if [ "$1" = "-F" ] || [ "$1" = "--format" ]; then
        ktlint -F "**/*.kt" "**/*.kts"
    else
        ktlint "**/*.kt" "**/*.kts"
    fi
}

# ----------------------------------------------------------------------------
# detekt-report - Run detekt with HTML report
# ----------------------------------------------------------------------------
detekt-report() {
    local output="${1:-detekt-report.html}"
    echo "=== Running detekt with HTML report ==="
    detekt --report html:"$output"
    echo "Report saved to: $output"
}

# ----------------------------------------------------------------------------
# kotlin-dev-version - Show Kotlin development tools versions
# ----------------------------------------------------------------------------
kotlin-dev-version() {
    echo "=== Kotlin Development Tools ==="

    echo ""
    echo "ktlint:"
    if command -v ktlint &>/dev/null; then
        ktlint --version 2>&1 | head -1
    else
        echo "  Not installed"
    fi

    echo ""
    echo "detekt:"
    if command -v detekt &>/dev/null; then
        detekt --version 2>&1 | head -1
    else
        echo "  Not installed"
    fi

    echo ""
    echo "kotlin-language-server:"
    if command -v kotlin-language-server &>/dev/null; then
        kotlin-language-server --version 2>&1 | head -1 || echo "  Installed (version check not supported)"
    else
        echo "  Not installed"
    fi

    echo ""
    echo "Kotlin (base):"
    kotlinc -version 2>&1 | head -1
}

# ----------------------------------------------------------------------------
# kt-init-project - Initialize a Kotlin project with recommended config
#
# Arguments:
#   $1 - Project name (optional, defaults to current directory name)
# ----------------------------------------------------------------------------
kt-init-project() {
    local project_name="${1:-$(basename $(pwd))}"

    echo "=== Initializing Kotlin Project: $project_name ==="

    # Create .editorconfig for ktlint
    if [ ! -f ".editorconfig" ]; then
        command cat > .editorconfig << 'EDITORCONFIG'
root = true

[*]
charset = utf-8
end_of_line = lf
indent_size = 4
indent_style = space
insert_final_newline = true
trim_trailing_whitespace = true

[*.{kt,kts}]
ktlint_code_style = ktlint_official
EDITORCONFIG
        echo "Created .editorconfig"
    fi

    # Create detekt config
    if [ ! -f "detekt.yml" ]; then
        if command -v detekt &>/dev/null; then
            detekt --generate-config
            echo "Created detekt.yml"
        fi
    fi

    # Create .gitignore if not exists
    if [ ! -f ".gitignore" ]; then
        command cat > .gitignore << 'GITIGNORE'
# Kotlin
*.class
*.jar
*.war
*.nar
*.ear
*.zip
*.tar.gz
*.rar

# Gradle
.gradle/
build/
!gradle/wrapper/gradle-wrapper.jar

# Maven
target/

# IDE
.idea/
*.iml
*.ipr
*.iws
.vscode/

# OS
.DS_Store
Thumbs.db
GITIGNORE
        echo "Created .gitignore"
    fi

    echo ""
    echo "Project initialized. Next steps:"
    echo "  - Run 'gradle init --type kotlin-application' for Gradle project"
    echo "  - Or create src/main/kotlin/ directory for manual setup"
}
