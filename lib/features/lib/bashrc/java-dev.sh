# ----------------------------------------------------------------------------
# Java Development Tool Aliases and Functions
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
# Java Development Tool Aliases
# ----------------------------------------------------------------------------
# Spring Boot shortcuts
alias sb='spring'
alias sbrun='spring run'
alias sbjar='spring jar'
alias sbinit='spring init'

# JBang shortcuts
alias jb='jbang'
alias jbrun='jbang run'
alias jbedit='jbang edit'

# Maven Daemon shortcuts
alias md='mvnd'
alias mdc='mvnd clean'
alias mdci='mvnd clean install'
alias mdcp='mvnd clean package'

# Code quality shortcuts
alias pmd-java='pmd check -d . -R rulesets/java/quickstart.xml -f text'
alias cpd-java='cpd --minimum-tokens 100 --language java --files .'
alias spotbugs-gui='spotbugs -gui'

# Google Java Format
alias gjf='google-java-format'
alias gjf-check='google-java-format --dry-run --set-exit-if-changed'
alias gjf-fix='google-java-format --replace'

# ============================================================================
# USER-FACING HELPER FUNCTIONS
# ============================================================================
# The following functions are meant to be used interactively by developers
# after sourcing this file. Variables like $name, $group, etc. are assigned
# from function parameters ($1, $2, ...) when the functions are called.
# SC2154 warnings about "variable referenced but not assigned" are false
# positives - shellcheck doesn't track function parameter assignments.
# shellcheck disable=SC2154

# ----------------------------------------------------------------------------
# java-format-all - Format all Java files in current directory
# ----------------------------------------------------------------------------
java-format-all() {
    echo "Formatting all Java files..."
    command find . -name "*.java" -type f | xargs google-java-format --replace
    echo "Formatting complete"
}

# ----------------------------------------------------------------------------
# java-quality-check - Run code quality tools via Maven
# ----------------------------------------------------------------------------
java-quality-check() {
    echo "=== Running Java Code Quality Checks ==="

    if [ -f pom.xml ]; then
        echo "Maven project detected"
        echo ""

        echo "To run code quality checks, use Maven plugins:"
        echo "  mvn com.github.spotbugs:spotbugs-maven-plugin:check"
        echo "  mvn pmd:check"
        echo "  mvn checkstyle:check"
        echo ""
        echo "Or add these plugins to your pom.xml for easier access"
    elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
        echo "Gradle project detected"
        echo ""

        echo "To run code quality checks, add and use Gradle plugins:"
        echo "  gradle spotbugsMain"
        echo "  gradle pmdMain"
        echo "  gradle checkstyleMain"
    else
        echo "No build file detected. Create a pom.xml or build.gradle first."
    fi
}

# ----------------------------------------------------------------------------
# spring-init-web - Initialize a new Spring Boot web project
#
# Arguments:
#   $1 - Project name (required)
#   $2 - Group ID (optional, default: com.example)
#
# Example:
#   spring-init-web my-app
#   spring-init-web my-app com.mycompany
# ----------------------------------------------------------------------------
spring-init-web() {
    if [ -z "$1" ]; then
        echo "Usage: spring-init-web <project-name> [group-id]"
        return 1
    fi

    local name="$1"
    local group="${2:-com.example}"

    echo "Creating Spring Boot web project: $name"
    spring init \
        --type=maven-project \
        --language=java \
        --boot-version=${SPRING_VERSION} \
        --group="$group" \
        --artifact="$name" \
        --name="$name" \
        --description="Spring Boot Web Application" \
        --package-name="${group}.${name}" \
        --dependencies=web,devtools,actuator,validation \
        "$name"

    cd "$name" || return
    echo "Project created in $(pwd)"
    echo "Run 'mvn spring-boot:run' to start the application"
}

# ----------------------------------------------------------------------------
# spring-init-api - Initialize a new Spring Boot REST API project
#
# Arguments:
#   $1 - Project name (required)
#   $2 - Group ID (optional, default: com.example)
#
# Example:
#   spring-init-api my-api
# ----------------------------------------------------------------------------
spring-init-api() {
    if [ -z "$1" ]; then
        echo "Usage: spring-init-api <project-name> [group-id]"
        return 1
    fi

    local name="$1"
    local group="${2:-com.example}"

    echo "Creating Spring Boot REST API project: $name"
    spring init \
        --type=maven-project \
        --language=java \
        --boot-version=${SPRING_VERSION} \
        --group="$group" \
        --artifact="$name" \
        --name="$name" \
        --description="Spring Boot REST API" \
        --package-name="${group}.${name}" \
        --dependencies=web,data-jpa,h2,devtools,actuator,validation,lombok \
        "$name"

    cd "$name" || return
    echo "Project created in $(pwd)"
    echo "Run 'mvn spring-boot:run' to start the API"
}

# ----------------------------------------------------------------------------
# jbang-init - Create a new JBang script
#
# Arguments:
#   $1 - Script name (required)
#   $2 - Template (optional: cli, hello, rest)
#
# Example:
#   jbang-init MyScript.java
#   jbang-init MyCli.java cli
# ----------------------------------------------------------------------------
jbang-init() {
    if [ -z "$1" ]; then
        echo "Usage: jbang-init <script-name> [template]"
        echo "Templates: cli, hello, rest"
        return 1
    fi

    local script="$1"
    local template="${2:-hello}"

    case "$template" in
        cli)
            jbang init --template=cli "$script"
            ;;
        rest)
            jbang init --template=rest "$script"
            ;;
        *)
            jbang init "$script"
            ;;
    esac

    echo "JBang script created: $script"
    echo "Run with: jbang $script"
    echo "Edit with: jbang edit $script"
}

# ----------------------------------------------------------------------------
# mvn-wrapper - Install Maven wrapper in current project
# ----------------------------------------------------------------------------
mvn-wrapper() {
    if [ ! -f pom.xml ]; then
        echo "Error: No pom.xml found in current directory"
        return 1
    fi

    echo "Installing Maven wrapper..."
    mvn wrapper:wrapper
    echo "Maven wrapper installed. Use './mvnw' instead of 'mvn'"
}

# ----------------------------------------------------------------------------
# gradle-wrapper - Install Gradle wrapper in current project
# ----------------------------------------------------------------------------
gradle-wrapper() {
    if [ ! -f build.gradle ] && [ ! -f build.gradle.kts ]; then
        echo "Error: No build.gradle[.kts] found in current directory"
        return 1
    fi

    echo "Installing Gradle wrapper..."
    gradle wrapper
    echo "Gradle wrapper installed. Use './gradlew' instead of 'gradle'"
}

# ----------------------------------------------------------------------------
# load_java_template - Load a Java template with variable substitution
#
# Arguments:
#   $1 - Template path relative to templates/java/ (required)
#   $2 - Class name for substitution (optional)
#
# Example:
#   load_java_template "benchmark/Benchmark.java.tmpl" "MyBenchmark"
# ----------------------------------------------------------------------------
load_java_template() {
    local template_path="$1"
    local class_name="${2:-}"
    local template_file="/tmp/build-scripts/features/templates/java/${template_path}"

    if [ ! -f "$template_file" ]; then
        echo "Error: Template not found: $template_file" >&2
        return 1
    fi

    if [ -n "$class_name" ]; then
        command sed "s/__CLASS_NAME__/${class_name}/g" "$template_file"
    else
        command cat "$template_file"
    fi
}

# ----------------------------------------------------------------------------
# java-benchmark - Create and run a JMH benchmark
#
# Arguments:
#   $1 - Class name (required)
#
# Example:
#   java-benchmark StringBenchmark
# ----------------------------------------------------------------------------
java-benchmark() {
    if [ -z "$1" ]; then
        echo "Usage: java-benchmark <class-name>"
        return 1
    fi

    local class="$1"
    local file="${class}.java"

    if [ ! -f "$file" ]; then
        echo "Creating JMH benchmark template: $file"
        load_java_template "benchmark/Benchmark.java.tmpl" "$class" > "$file"
        echo "Benchmark template created"
    fi

    echo "Compiling and running benchmark..."
    jbang --deps org.openjdk.jmh:jmh-core:${JMH_VERSION},org.openjdk.jmh:jmh-generator-annprocess:${JMH_VERSION} "$file"
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
