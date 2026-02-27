# ----------------------------------------------------------------------------
# Java environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u  # Don't error on unset variables
set +e  # Don't exit on errors

# Check if we're in an interactive shell
if [[ $- != *i* ]]; then
    # Not interactive, skip loading
    return 0
fi


# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Java installation
export JAVA_HOME=/usr/lib/jvm/default-java
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "$JAVA_HOME/bin" 2>/dev/null || export PATH="$JAVA_HOME/bin:$PATH"
else
    export PATH="$JAVA_HOME/bin:$PATH"
fi

# Maven configuration
export M2_HOME=/usr/share/maven
export MAVEN_HOME=$M2_HOME
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "$M2_HOME/bin" 2>/dev/null || export PATH="$M2_HOME/bin:$PATH"
else
    export PATH="$M2_HOME/bin:$PATH"
fi
export MAVEN_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"

# Maven cache directory
export MAVEN_USER_HOME="/cache/maven"
export M2_REPO="${MAVEN_USER_HOME}/repository"

# Gradle configuration
export GRADLE_HOME=/usr/share/gradle
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "$GRADLE_HOME/bin" 2>/dev/null || export PATH="$GRADLE_HOME/bin:$PATH"
else
    export PATH="$GRADLE_HOME/bin:$PATH"
fi
export GRADLE_USER_HOME="/cache/gradle"
export GRADLE_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"
