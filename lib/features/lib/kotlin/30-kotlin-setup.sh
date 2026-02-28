#!/bin/bash
# Kotlin development environment setup

# Check for Kotlin projects
if [ -f ${WORKING_DIR}/build.gradle.kts ]; then
    echo "=== Kotlin Gradle Project Detected ==="
    echo "Kotlin project with Gradle found. Common commands:"
    echo "  gradle build        - Build project"
    echo "  gradle test         - Run tests"
    echo "  gradle run          - Run application"

    if [ -x ${WORKING_DIR}/gradlew ]; then
        echo ""
        echo "Gradle wrapper available - use './gradlew' for consistent builds"
    fi
elif [ -f ${WORKING_DIR}/pom.xml ] && command grep -q "kotlin" ${WORKING_DIR}/pom.xml 2>/dev/null; then
    echo "=== Kotlin Maven Project Detected ==="
    echo "Kotlin project with Maven found. Common commands:"
    echo "  mvn compile         - Compile project"
    echo "  mvn test            - Run tests"
    echo "  mvn package         - Package application"
fi

# Display Kotlin environment
echo ""
kotlin-version 2>/dev/null || {
    echo "Kotlin: $(kotlinc -version 2>&1)"
}
