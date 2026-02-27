
# ----------------------------------------------------------------------------
# Java Aliases - Common development commands
# ----------------------------------------------------------------------------
# Maven aliases
alias mvnc='mvn clean'
alias mvnci='mvn clean install'
alias mvncp='mvn clean package'
alias mvncist='mvn clean install -DskipTests'
alias mvnt='mvn test'
alias mvnts='mvn test -Dtest='
alias mvndep='mvn dependency:tree'
alias mvndeps='mvn dependency:sources'
alias mvneff='mvn help:effective-pom'

# Gradle aliases
alias gw='./gradlew'
alias gwb='./gradlew build'
alias gwc='./gradlew clean'
alias gwcb='./gradlew clean build'
alias gwt='./gradlew test'
alias gwts='./gradlew test --tests'
alias gwdep='./gradlew dependencies'
alias gwtasks='./gradlew tasks'

# ----------------------------------------------------------------------------
# java-version - Show detailed Java version information
# ----------------------------------------------------------------------------
java-version() {
    echo "=== Java Environment ==="
    echo "Java Version:"
    java -version 2>&1 | head -n 3
    echo ""
    echo "JAVA_HOME: $JAVA_HOME"
    echo ""
    echo "Build Tools:"
    mvn --version 2>/dev/null | head -n 1 || echo "Maven not found"
    gradle --version 2>/dev/null | grep "Gradle" || echo "Gradle not found"
    echo ""
    echo "Cache Directories:"
    echo "  Maven: ${MAVEN_USER_HOME:-/cache/maven}"
    echo "  Gradle: ${GRADLE_USER_HOME:-/cache/gradle}"
}

# ----------------------------------------------------------------------------
# mvn-create - Create a new Maven project from archetype
#
# Arguments:
#   $1 - Group ID (required)
#   $2 - Artifact ID (required)
#   $3 - Archetype (optional, default: quickstart)
#
# Example:
#   mvn-create com.example my-app
#   mvn-create com.example my-webapp webapp
# ----------------------------------------------------------------------------
mvn-create() {
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Usage: mvn-create <groupId> <artifactId> [archetype]"
        echo ""
        echo "Archetypes:"
        echo "  quickstart - Simple Java application (default)"
        echo "  webapp     - Web application"
        echo "  spring     - Spring Boot application"
        return 1
    fi

    local groupId="$1"
    local artifactId="$2"
    local archetype="${3:-quickstart}"

    case "$archetype" in
        webapp)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeArtifactId=maven-archetype-webapp \
                -DarchetypeVersion=1.4 \
                -DinteractiveMode=false
            ;;
        spring)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeGroupId=org.springframework.boot \
                -DarchetypeArtifactId=spring-boot-maven-archetype \
                -DinteractiveMode=false
            ;;
        *)
            mvn archetype:generate \
                -DgroupId="$groupId" \
                -DartifactId="$artifactId" \
                -DarchetypeArtifactId=maven-archetype-quickstart \
                -DarchetypeVersion=1.4 \
                -DinteractiveMode=false
            ;;
    esac
}

# ----------------------------------------------------------------------------
# gradle-init - Initialize a new Gradle project
#
# Arguments:
#   $1 - Project type (default: java-application)
#   $2 - DSL type (default: groovy, can be kotlin)
#
# Example:
#   gradle-init
#   gradle-init java-library
#   gradle-init java-application kotlin
# ----------------------------------------------------------------------------
gradle-init() {
    local type="${1:-java-application}"
    local dsl="${2:-groovy}"

    echo "Creating Gradle project (type: $type, DSL: $dsl)..."
    gradle init --type "$type" --dsl "$dsl"
}

# ----------------------------------------------------------------------------
# java-clean-cache - Clean Maven and Gradle caches
# ----------------------------------------------------------------------------
java-clean-cache() {
    echo "=== Cleaning Java build caches ==="

    if [ -d "${MAVEN_USER_HOME:-/cache/maven}/repository" ]; then
        echo "Cleaning Maven cache..."
        command rm -rf "${MAVEN_USER_HOME:-/cache/maven}/repository"/*
    fi

    if [ -d "${GRADLE_USER_HOME:-/cache/gradle}/caches" ]; then
        echo "Cleaning Gradle cache..."
        command rm -rf "${GRADLE_USER_HOME:-/cache/gradle}/caches"/*
    fi

    echo "Cache cleanup complete"
}

# ----------------------------------------------------------------------------
# mvn-deps-update - Check and update Maven dependencies
# ----------------------------------------------------------------------------
mvn-deps-update() {
    echo "=== Checking for Maven dependency updates ==="
    mvn versions:display-dependency-updates
    echo ""
    echo "To update dependencies, use:"
    echo "  mvn versions:use-latest-releases"
    echo "  mvn versions:use-latest-snapshots"
}

# ----------------------------------------------------------------------------
# gradle-deps-update - Check Gradle dependencies
# ----------------------------------------------------------------------------
gradle-deps-update() {
    echo "=== Checking for Gradle dependency updates ==="
    if [ -x "./gradlew" ]; then
        ./gradlew dependencyUpdates
    else
        gradle dependencyUpdates
    fi
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
