#!/bin/bash
# shellcheck disable=SC2154  # Variables in helper functions assigned from parameters
# Java Development Tools - Advanced development utilities for Java
#
# Description:
#   Installs comprehensive Java development tools for testing, code quality,
#   debugging, and productivity. These complement the base Java installation
#   with modern development utilities.
#
# Tools Installed:
#   - Testing: JUnit Platform Console, TestNG
#   - Code Quality: SpotBugs, PMD, Checkstyle, Error Prone
#   - Build Enhancement: Maven Wrapper, Gradle Wrapper installers
#   - Spring Boot CLI: Rapid Spring application development
#   - JReleaser: Modern release automation
#   - JBang: Java scripting and single-file execution
#   - SDKMAN!: Java SDK version management
#   - Lombok: Boilerplate code reduction
#   - JMH: Java Microbenchmark Harness
#
# Requirements:
#   - Java must be installed (via INCLUDE_JAVA=true)
#
set -euo pipefail

# Source standard feature header for user handling
source /tmp/build-scripts/base/feature-header.sh

# Source apt utilities for reliable package installation
source /tmp/build-scripts/base/apt-utils.sh

# Start logging
log_feature_start "Java Development Tools"

# ============================================================================
# Prerequisites Check
# ============================================================================
log_message "Checking prerequisites..."

# Check if Java is available
if [ ! -f "/usr/local/bin/java" ]; then
    log_error "Java not found at /usr/local/bin/java"
    log_error "The INCLUDE_JAVA feature must be enabled before java-dev tools can be installed"
    log_feature_end
    exit 1
fi

# Check if Maven is available
if [ ! -f "/usr/local/bin/mvn" ]; then
    log_error "Maven not found at /usr/local/bin/mvn"
    log_error "The INCLUDE_JAVA feature must be enabled first"
    log_feature_end
    exit 1
fi

# ============================================================================
# System Dependencies
# ============================================================================
log_message "Installing system dependencies for Java dev tools..."

log_message "Updating package lists and installing dependencies..."

# Update package lists with retry logic
apt_update

# Install system dependencies with retry logic
apt_install \
    unzip \
    zip \
    jq

# ============================================================================
# Development Tools Installation
# ============================================================================
log_message "Installing Java development tools..."

# Set up tool installation directory
TOOLS_DIR="/opt/java-tools"
log_command "Creating tools directory" \
    mkdir -p "${TOOLS_DIR}/bin"

# ============================================================================
# Spring Boot CLI
# ============================================================================
log_message "Installing Spring Boot CLI..."

SPRING_VERSION="3.5.7"
export SPRING_VERSION  # Export for use in shell functions
log_command "Downloading Spring Boot CLI ${SPRING_VERSION}" \
    wget -q "https://repo.maven.apache.org/maven2/org/springframework/boot/spring-boot-cli/${SPRING_VERSION}/spring-boot-cli-${SPRING_VERSION}-bin.tar.gz" \
    -O /tmp/spring-boot-cli.tar.gz

log_command "Extracting Spring Boot CLI" \
    tar -xzf /tmp/spring-boot-cli.tar.gz -C "${TOOLS_DIR}"

create_symlink "${TOOLS_DIR}/spring-${SPRING_VERSION}/bin/spring" "/usr/local/bin/spring" "Spring Boot CLI"

rm -f /tmp/spring-boot-cli.tar.gz

# ============================================================================
# JBang - Java Scripting
# ============================================================================
log_message "Installing JBang..."

# Download and extract JBang directly (more reliable than installer script)
JBANG_VERSION="0.132.1"
log_command "Downloading JBang ${JBANG_VERSION}" \
    wget -q "https://github.com/jbangdev/jbang/releases/download/v${JBANG_VERSION}/jbang-${JBANG_VERSION}.tar" -O /tmp/jbang.tar

log_command "Extracting JBang" \
    tar -xf /tmp/jbang.tar -C "${TOOLS_DIR}"

# Create symlink directly to the jbang script
create_symlink "${TOOLS_DIR}/jbang-${JBANG_VERSION}/bin/jbang" "/usr/local/bin/jbang" "JBang Java scripting tool"

rm -f /tmp/jbang.tar

# ============================================================================
# Maven Daemon - Faster Maven builds (amd64 only)
# ============================================================================
ARCH=$(dpkg --print-architecture)
if [ "$ARCH" = "amd64" ]; then
    log_message "Installing Maven Daemon..."

    MVND_VERSION="1.0.3"
    MVND_URL="https://github.com/apache/maven-mvnd/releases/download/${MVND_VERSION}/maven-mvnd-${MVND_VERSION}-linux-amd64.tar.gz"

    log_command "Downloading Maven Daemon ${MVND_VERSION}" \
        wget "${MVND_URL}" -O /tmp/mvnd.tar.gz

    log_command "Extracting Maven Daemon" \
        tar -xzf /tmp/mvnd.tar.gz -C "${TOOLS_DIR}"

    create_symlink "${TOOLS_DIR}/maven-mvnd-${MVND_VERSION}-linux-amd64/bin/mvnd" "/usr/local/bin/mvnd" "Maven Daemon"
    create_symlink "${TOOLS_DIR}/maven-mvnd-${MVND_VERSION}-linux-amd64/bin/mvnd" "/usr/local/bin/mvndaemon" "Maven Daemon (alias)"

    rm -f /tmp/mvnd.tar.gz
else
    log_message "Skipping Maven Daemon installation - only available for amd64 architecture"
fi

# ============================================================================
# Code Quality Tools (Optional)
# ============================================================================
log_message "Installing code quality tools (best effort)..."

# Create a directory for standalone JARs
JARS_DIR="${TOOLS_DIR}/jars"
log_command "Creating JARs directory" \
    mkdir -p "${JARS_DIR}"

# Note: We're skipping the complex code quality tools (SpotBugs, PMD, Checkstyle)
# as they have frequent download issues and can be installed via Maven plugins instead.
# Users can install them with:
#   mvn com.github.spotbugs:spotbugs-maven-plugin:check
#   mvn pmd:check
#   mvn checkstyle:check

# ============================================================================
# Google Java Format - Essential formatter
# ============================================================================
log_message "Installing Google Java Format..."

GJF_VERSION="1.30.0"

# JMH version for benchmarking
JMH_VERSION="1.37"
GJF_URL="https://github.com/google/google-java-format/releases/download/v${GJF_VERSION}/google-java-format-${GJF_VERSION}-all-deps.jar"
if wget -q --spider "${GJF_URL}" 2>/dev/null; then
    log_command "Downloading Google Java Format ${GJF_VERSION}" \
        wget -q "${GJF_URL}" -O "${JARS_DIR}/google-java-format.jar"

    # Create wrapper script
    cat > /usr/local/bin/google-java-format << 'EOF'
#!/bin/bash
java -jar /opt/java-tools/jars/google-java-format.jar "$@"
EOF
    log_command "Setting Google Java Format script permissions" \
        chmod +x /usr/local/bin/google-java-format
else
    log_warning "Google Java Format not available, skipping..."
fi

# ============================================================================
# Shell Aliases and Functions
# ============================================================================
log_message "Setting up Java development helpers..."

# Ensure /etc/bashrc.d exists
log_command "Creating bashrc.d directory" \
    mkdir -p /etc/bashrc.d

# Add java-dev aliases and helpers
write_bashrc_content /etc/bashrc.d/55-java-dev.sh "Java development tools" << JAVA_DEV_BASHRC_EOF
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

# Defensive programming - check for required commands
_check_command() {
    command -v "$1" >/dev/null 2>&1
}

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
    find . -name "*.java" -type f | xargs google-java-format --replace
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

    cd "$name"
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

    cd "$name"
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
        cat > "$file" << BENCHMARK
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.runner.Runner;
import org.openjdk.jmh.runner.options.Options;
import org.openjdk.jmh.runner.options.OptionsBuilder;

import java.util.concurrent.TimeUnit;

@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Thread)
@Fork(value = 2, jvmArgs = {"-Xms2G", "-Xmx2G"})
@Warmup(iterations = 3)
@Measurement(iterations = 5)
public class $class {

    @Param({"10", "100", "1000"})
    private int size;

    private String data;

    @Setup
    public void setup() {
        data = "x".repeat(size);
    }

    @Benchmark
    public int baseline() {
        return data.length();
    }

    public static void main(String[] args) throws Exception {
        Options opt = new OptionsBuilder()
                .include($class.class.getSimpleName())
                .build();

        new Runner(opt).run();
    }
}
BENCHMARK
        echo "Benchmark template created"
    fi

    echo "Compiling and running benchmark..."
    jbang --deps org.openjdk.jmh:jmh-core:${JMH_VERSION},org.openjdk.jmh:jmh-generator-annprocess:${JMH_VERSION} "\$file"
}

# Clean up helper functions
unset -f _check_command 2>/dev/null || true

# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
JAVA_DEV_BASHRC_EOF

log_command "Setting Java dev bashrc script permissions" \
    chmod +x /etc/bashrc.d/55-java-dev.sh

# ============================================================================
# Create Development Templates
# ============================================================================
log_message "Creating Java development templates..."

# Create templates directory
TEMPLATES_DIR="/etc/java-dev-templates"
log_command "Creating templates directory" \
    mkdir -p "${TEMPLATES_DIR}"

# Checkstyle configuration
cat > "${TEMPLATES_DIR}/checkstyle.xml" << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE module PUBLIC
    "-//Checkstyle//DTD Checkstyle Configuration 1.3//EN"
    "https://checkstyle.org/dtds/configuration_1_3.dtd">

<module name="Checker">
    <property name="charset" value="UTF-8"/>
    <property name="severity" value="warning"/>
    <property name="fileExtensions" value="java, properties, xml"/>

    <module name="TreeWalker">
        <module name="OuterTypeFilename"/>
        <module name="IllegalTokenText">
            <property name="tokens" value="STRING_LITERAL, CHAR_LITERAL"/>
            <property name="format"
             value="\\u00(09|0(a|A)|0(c|C)|0(d|D)|22|27|5(C|c))|\\(0(10|11|12|14|15|42|47)|134)"/>
            <property name="message"
             value="Consider using special escape sequence instead of octal value or Unicode escaped value."/>
        </module>
        <module name="AvoidEscapedUnicodeCharacters">
            <property name="allowEscapesForControlCharacters" value="true"/>
            <property name="allowByTailComment" value="true"/>
            <property name="allowNonPrintableEscapes" value="true"/>
        </module>
        <module name="LineLength">
            <property name="max" value="120"/>
            <property name="ignorePattern" value="^package.*|^import.*|a href|href|http://|https://|ftp://"/>
        </module>
        <module name="OneTopLevelClass"/>
        <module name="NoLineWrap"/>
        <module name="EmptyBlock">
            <property name="option" value="TEXT"/>
            <property name="tokens"
             value="LITERAL_TRY, LITERAL_FINALLY, LITERAL_IF, LITERAL_ELSE, LITERAL_SWITCH"/>
        </module>
    </module>
</module>
EOF

# PMD ruleset
cat > "${TEMPLATES_DIR}/pmd-ruleset.xml" << 'EOF'
<?xml version="1.0"?>
<ruleset name="Custom Rules"
    xmlns="http://pmd.sourceforge.net/ruleset/2.0.0"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://pmd.sourceforge.net/ruleset/2.0.0
    https://pmd.sourceforge.io/ruleset_2_0_0.xsd">

    <description>Custom PMD rules for Java projects</description>

    <rule ref="category/java/bestpractices.xml">
        <exclude name="JUnitAssertionsShouldIncludeMessage"/>
        <exclude name="JUnitTestContainsTooManyAsserts"/>
    </rule>

    <rule ref="category/java/codestyle.xml">
        <exclude name="AtLeastOneConstructor"/>
        <exclude name="LocalVariableCouldBeFinal"/>
        <exclude name="MethodArgumentCouldBeFinal"/>
    </rule>

    <rule ref="category/java/design.xml">
        <exclude name="LawOfDemeter"/>
        <exclude name="LoosePackageCoupling"/>
    </rule>

    <rule ref="category/java/errorprone.xml">
        <exclude name="BeanMembersShouldSerialize"/>
    </rule>

    <rule ref="category/java/performance.xml"/>
    <rule ref="category/java/security.xml"/>
</ruleset>
EOF

# SpotBugs exclude filter
cat > "${TEMPLATES_DIR}/spotbugs-exclude.xml" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<FindBugsFilter>
    <!-- Exclude test classes -->
    <Match>
        <Class name="~.*Test" />
    </Match>

    <!-- Exclude generated code -->
    <Match>
        <Package name="~.*\.generated\..*" />
    </Match>

    <!-- Common false positives -->
    <Match>
        <Bug pattern="EI_EXPOSE_REP,EI_EXPOSE_REP2" />
        <Class name="~.*DTO$|~.*Entity$" />
    </Match>
</FindBugsFilter>
EOF

# ============================================================================
# Container Startup Scripts
# ============================================================================
log_message "Creating java-dev startup script..."

cat > /etc/container/first-startup/35-java-dev-setup.sh << 'EOF'
#!/bin/bash
# Java development tools configuration
if command -v java &> /dev/null; then
    echo "=== Java Development Tools ==="

    # List available dev tools
    echo "Development tools available:"
    echo "  Spring Boot CLI: spring"
    echo "  JBang: jbang"
    echo "  Maven Daemon: mvnd"
    echo "  Code Quality: spotbugs, pmd, checkstyle"
    echo "  Formatting: google-java-format"
    echo "  Release: jreleaser"
    echo ""

    # Check for Java project
    if [ -f ${WORKING_DIR}/pom.xml ] || [ -f ${WORKING_DIR}/build.gradle* ]; then
        # Copy templates if they don't exist
        if [ ! -f ${WORKING_DIR}/checkstyle.xml ] && [ -f /etc/java-dev-templates/checkstyle.xml ]; then
            cp /etc/java-dev-templates/checkstyle.xml ${WORKING_DIR}/
            echo "Created checkstyle.xml configuration"
        fi

        if [ ! -f ${WORKING_DIR}/pmd-ruleset.xml ] && [ -f /etc/java-dev-templates/pmd-ruleset.xml ]; then
            cp /etc/java-dev-templates/pmd-ruleset.xml ${WORKING_DIR}/
            echo "Created pmd-ruleset.xml configuration"
        fi

        if [ ! -f ${WORKING_DIR}/spotbugs-exclude.xml ] && [ -f /etc/java-dev-templates/spotbugs-exclude.xml ]; then
            cp /etc/java-dev-templates/spotbugs-exclude.xml ${WORKING_DIR}/
            echo "Created spotbugs-exclude.xml filter"
        fi

        echo ""
        echo "Quick commands:"
        echo "  java-quality-check   - Run all code quality tools"
        echo "  java-format-all      - Format all Java files"
        echo "  mvn-wrapper          - Add Maven wrapper"
        echo "  gradle-wrapper       - Add Gradle wrapper"
    fi
fi
EOF

log_command "Setting Java dev startup script permissions" \
    chmod +x /etc/container/first-startup/35-java-dev-setup.sh

# ============================================================================
# Verification Script
# ============================================================================
log_message "Creating java-dev verification script..."

cat > /usr/local/bin/test-java-dev << 'EOF'
#!/bin/bash
echo "=== Java Development Tools Status ==="

# Check main tools
echo ""
echo "Main development tools:"
for tool in spring jbang mvnd jreleaser; do
    if command -v $tool &> /dev/null; then
        case $tool in
            spring)
                version=$(spring --version 2>&1)
                ;;
            jbang)
                version=$(jbang --version 2>&1)
                ;;
            mvnd)
                version=$(mvnd --version 2>&1 | head -1)
                ;;
            jreleaser)
                version=$(jreleaser --version 2>&1)
                ;;
        esac
        echo "✓ $tool: $version"
    else
        echo "✗ $tool is not found"
    fi
done

# Check code quality tools
echo ""
echo "Code quality tools:"
for tool in spotbugs pmd cpd checkstyle google-java-format; do
    if command -v $tool &> /dev/null; then
        echo "✓ $tool is installed"
    else
        echo "✗ $tool is not found"
    fi
done

echo ""
echo "Run 'java-dev-help' to see available commands"
EOF

log_command "Setting test-java-dev script permissions" \
    chmod +x /usr/local/bin/test-java-dev

# Create help command
cat > /usr/local/bin/java-dev-help << 'EOF'
#!/bin/bash
echo "=== Java Development Commands ==="
echo ""
echo "Project initialization:"
echo "  spring-init-web <name>    - Create Spring Boot web app"
echo "  spring-init-api <name>    - Create Spring Boot REST API"
echo "  jbang-init <script>       - Create JBang script"
echo "  mvn-create <group> <id>   - Create Maven project"
echo ""
echo "Code quality:"
echo "  java-quality-check        - Run all quality tools"
echo "  java-format-all           - Format all Java files"
echo "  pmd-java                  - Run PMD analysis"
echo "  cpd-java                  - Detect copy-paste"
echo ""
echo "Build tools:"
echo "  mvnd                      - Fast Maven builds"
echo "  mvn-wrapper               - Add Maven wrapper"
echo "  gradle-wrapper            - Add Gradle wrapper"
echo ""
echo "Utilities:"
echo "  java-benchmark <class>    - Create/run JMH benchmark"
echo "  jbang <script>            - Run Java scripts"
echo "  spring jar                - Create executable JAR"
EOF

log_command "Setting java-dev-help script permissions" \
    chmod +x /usr/local/bin/java-dev-help

# ============================================================================
# Final Verification
# ============================================================================
log_message "Verifying key Java development tools..."

log_command "Checking Spring Boot CLI" \
    /usr/local/bin/spring --version || log_warning "Spring Boot CLI not installed"

log_command "Checking JBang" \
    /usr/local/bin/jbang --version || log_warning "JBang not installed"

log_command "Checking Maven Daemon" \
    /usr/local/bin/mvnd --version || log_warning "Maven Daemon not installed"

log_command "Checking SpotBugs" \
    /usr/local/bin/spotbugs -version || log_warning "SpotBugs not installed"

# End logging
log_feature_end

echo ""
echo "Run 'test-java-dev' to check installed tools"
echo "Run 'java-dev-help' to see available commands"
echo "Run 'check-build-logs.sh java-development-tools' to review installation logs"
