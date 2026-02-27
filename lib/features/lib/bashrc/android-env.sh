# ----------------------------------------------------------------------------
# Android SDK environment configuration
# ----------------------------------------------------------------------------

# Error protection for interactive shells
set +u
set +e

if [[ $- != *i* ]]; then
    return 0
fi

# Source base utilities
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# Android SDK
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME

# Add SDK tools to PATH
_android_paths=(
    "$ANDROID_HOME/cmdline-tools/latest/bin"
    "$ANDROID_HOME/platform-tools"
    "$ANDROID_HOME/emulator"
)

for _path in "${_android_paths[@]}"; do
    if [ -d "$_path" ]; then
        if command -v safe_add_to_path >/dev/null 2>&1; then
            safe_add_to_path "$_path" 2>/dev/null || export PATH="$_path:$PATH"
        else
            export PATH="$_path:$PATH"
        fi
    fi
done

# Find and add build-tools to PATH
_build_tools=$(ls -d "$ANDROID_HOME/build-tools/"* 2>/dev/null | sort -V | tail -1)
if [ -n "$_build_tools" ] && [ -d "$_build_tools" ]; then
    if command -v safe_add_to_path >/dev/null 2>&1; then
        safe_add_to_path "$_build_tools" 2>/dev/null || export PATH="$_build_tools:$PATH"
    else
        export PATH="$_build_tools:$PATH"
    fi
fi

# NDK (find installed version)
_ndk_dir=$(ls -d "$ANDROID_HOME/ndk/"* 2>/dev/null | sort -V | tail -1)
if [ -n "$_ndk_dir" ] && [ -d "$_ndk_dir" ]; then
    export ANDROID_NDK_HOME="$_ndk_dir"
    export NDK_HOME="$ANDROID_NDK_HOME"
fi

# Android Gradle cache
export ANDROID_SDK_HOME="/cache/android-sdk"

# Clean up temp variables
unset _android_paths _path _build_tools _ndk_dir
