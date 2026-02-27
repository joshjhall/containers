# ----------------------------------------------------------------------------
# Kotlin Development Tools Configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# detekt home
if [ -d "/opt/detekt" ]; then
    export DETEKT_HOME="/opt/detekt"
fi

# Kotlin Language Server
if [ -d "/opt/kotlin-language-server" ]; then
    export KLS_HOME="/opt/kotlin-language-server/server"
fi
