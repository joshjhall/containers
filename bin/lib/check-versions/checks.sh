#!/usr/bin/env bash
# Version check functions for individual tools
#
# Part of the version checking system (see bin/check-versions.sh).
# Contains per-tool check functions and factory functions for common patterns.
#
# Each check function fetches the latest version for a tool and calls
# set_latest() to record it.

# Progress helpers for quiet mode in JSON
progress_msg() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo -n "$1"
    fi
}

progress_done() {
    if [ "$OUTPUT_FORMAT" = "text" ]; then
        echo " ✓"
    fi
}

# Check functions for each tool
check_python() {
    progress_msg "  Python..."
    local latest
    latest=$(fetch_url "https://endoflife.date/api/python.json" | jq -r '[.[] | select(.cycle | startswith("3."))] | .[0].latest // "null"' 2>/dev/null)
    set_latest "Python" "$latest"
    progress_done
}

check_nodejs() {
    progress_msg "  Node.js..."
    local current=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "Node.js" ]; then
            current="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    local latest=""
    # If version is just major (like "22"), get the latest LTS in that major version
    if [[ "$current" =~ ^[0-9]+$ ]]; then
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\")) | select(.lts != false)] | .[0].version" 2>/dev/null | command sed 's/^v//')
        # If no LTS found for that major, get any version
        if [ -z "$latest" ] || [ "$latest" = "null" ]; then
            latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r "[.[] | select(.version | startswith(\"v$current.\"))] | .[0].version" 2>/dev/null | command sed 's/^v//')
        fi
    else
        # Get latest LTS
        latest=$(fetch_url "https://nodejs.org/dist/index.json" | jq -r '[.[] | select(.lts != false)] | .[0].version' 2>/dev/null | command sed 's/^v//')
    fi

    set_latest "Node.js" "$latest"
    progress_done
}

check_rust() {
    progress_msg "  Rust..."
    # Try the Rust API endpoint
    local latest
    latest=$(fetch_url "https://api.github.com/repos/rust-lang/rust/releases" | jq -r '[.[] | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))] | .[0].tag_name' 2>/dev/null)
    if [ -z "$latest" ]; then
        # Fallback to forge.rust-lang.org
        latest=$(fetch_url "https://forge.rust-lang.org/infra/channel-layout.html" | grep -oE 'stable.*?[0-9]+\.[0-9]+\.[0-9]+' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
    fi
    set_latest "Rust" "$latest"
    progress_done
}

check_java() {
    progress_msg "  Java..."
    # Get the current major version
    local current_major=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "Java" ]; then
            current_major="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    # Use Adoptium API to get latest version for this major
    local latest
    latest=$(fetch_url "https://api.adoptium.net/v3/info/release_versions?release_type=ga&version=${current_major}" | jq -r '.versions[0].semver' 2>/dev/null | command sed 's/+.*//')

    # If that fails, try the release names endpoint
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.adoptium.net/v3/assets/latest/${current_major}/hotspot" | jq -r '.[0].release_name' 2>/dev/null | command sed 's/jdk-//' | command sed 's/+.*//')
    fi

    set_latest "Java" "$latest"
    progress_done
}

check_r() {
    progress_msg "  R..."
    local latest

    # Use CRAN sources page - more reliable than homepage or SVN
    # Parse the latest release tarball name
    latest=$(fetch_url "https://cran.r-project.org/sources.html" 8 | grep -oE 'R-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' | head -1 | command sed 's/R-//;s/\.tar\.gz//' 2>/dev/null)

    # Mark as error if fetch failed
    if [ -z "$latest" ]; then
        latest="error"
    fi

    set_latest "R" "$latest"
    progress_done
}

check_jdtls() {
    progress_msg "  jdtls..."
    # Get the latest jdtls version from Eclipse downloads
    local latest
    latest=$(fetch_url "https://download.eclipse.org/jdtls/milestones/" 10 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 2>/dev/null)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        set_latest "jdtls" "error"
    else
        set_latest "jdtls" "$latest"
    fi
    progress_done
}

check_android_cmdline_tools() {
    progress_msg "  android-cmdline-tools..."
    # Get the latest cmdline-tools version from the Android Studio download page
    # The version is embedded in the download filename
    local latest
    latest=$(fetch_url "https://developer.android.com/studio" 10 | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' | head -1 | grep -oE '[0-9]+' 2>/dev/null)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        # Fallback: mark as needing manual check
        set_latest "android-cmdline-tools" "error"
    else
        set_latest "android-cmdline-tools" "$latest"
    fi
    progress_done
}

check_android_ndk() {
    progress_msg "  android-ndk..."
    # Get the latest NDK version from the download page
    # NDK versions are like r27d, r29, etc. We need to map to the SDK manager format
    local ndk_release
    ndk_release=$(fetch_url "https://developer.android.com/ndk/downloads" 10 | grep -oE 'android-ndk-r[0-9]+[a-z]?' | sort -V | tail -1 | grep -oE 'r[0-9]+[a-z]?' 2>/dev/null)

    if [ -z "$ndk_release" ]; then
        set_latest "android-ndk" "error"
    else
        # NDK version format in SDK manager is like "29.0.14206865"
        # We can't easily get the full version, but we can check if major version matches
        # Extract major version (e.g., r29 -> 29)
        local major_ver
        major_ver=$(echo "$ndk_release" | grep -oE '[0-9]+')

        # Get the current major version from what's pinned
        local current=""
        for i in "${!TOOLS[@]}"; do
            if [ "${TOOLS[$i]}" = "android-ndk" ]; then
                current="${CURRENT_VERSIONS[$i]}"
                break
            fi
        done
        local current_major
        current_major=$(echo "$current" | cut -d. -f1)

        # If major versions match, consider it current
        if [ "$major_ver" = "$current_major" ]; then
            set_latest "android-ndk" "$current"
        else
            # Different major version - report the release name for reference
            set_latest "android-ndk" "${major_ver}.x.x ($ndk_release)"
        fi
    fi
    progress_done
}

check_github_release() {
    local tool="$1"
    local repo="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "$tool" "$latest"
    progress_done
}

check_gitlab_release() {
    local tool="$1"
    local project_id="$2"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://gitlab.com/api/v4/projects/$project_id/releases" | jq -r '.[0].tag_name // "null"' 2>/dev/null | command sed 's/^v//')
    set_latest "$tool" "$latest"
    progress_done
}

check_entr() {
    progress_msg "  entr..."
    # entr uses a simple versioning on their website
    # We'll check the latest version from the downloads page
    local latest
    latest=$(fetch_url "http://eradman.com/entrproject/" | grep -oE 'entr-[0-9]+\.[0-9]+\.tar\.gz' | head -1 | command sed 's/entr-//;s/\.tar\.gz//')

    set_latest "entr" "$latest"
    progress_done
}

check_biome() {
    progress_msg "  biome..."
    # Biome changed tag format from cli/vX.Y.Z to @biomejs/biome@X.Y.Z
    local latest
    latest=$(fetch_url "https://api.github.com/repos/biomejs/biome/releases" | jq -r '[.[] | select(.tag_name | startswith("@biomejs/biome@"))] | .[0].tag_name // "null"' 2>/dev/null | command sed 's|^@biomejs/biome@||')
    # Fallback to old format if new format not found
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.github.com/repos/biomejs/biome/releases" | jq -r '[.[] | select(.tag_name | startswith("cli/v"))] | .[0].tag_name // "null"' 2>/dev/null | command sed 's|^cli/v||')
    fi
    set_latest "biome" "$latest"
    progress_done
}

check_crates_io() {
    local tool="$1"
    local crate="${2:-$tool}"
    progress_msg "  $tool..."
    local latest
    latest=$(fetch_url "https://crates.io/api/v1/crates/$crate" | jq -r '.crate.max_version // "null"' 2>/dev/null)
    set_latest "$tool" "$latest"
    progress_done
}

check_maven_central() {
    local tool="$1"
    local group_id="$2"
    local artifact_id="$3"
    progress_msg "  $tool..."
    # Check Maven Central for latest version
    local latest
    latest=$(fetch_url "https://search.maven.org/solrsearch/select?q=g:${group_id}+AND+a:${artifact_id}&rows=1&wt=json" | \
        jq -r '.response.docs[0].latestVersion // "unknown"' 2>/dev/null)

    if [ -n "$latest" ] && [ "$latest" != "unknown" ] && [ "$latest" != "null" ]; then
        set_latest "$tool" "$latest"
    else
        set_latest "$tool" "error"
    fi
    progress_done
}

check_kubectl() {
    progress_msg "  kubectl..."
    local current=""
    for i in "${!TOOLS[@]}"; do
        if [ "${TOOLS[$i]}" = "kubectl" ]; then
            current="${CURRENT_VERSIONS[$i]}"
            break
        fi
    done

    local latest=""
    # Extract major.minor from current version (handles both 1.33 and 1.33.0 formats)
    local major_minor=""
    if [[ "$current" =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
        # Get latest patch version for this major.minor from GitHub releases
        latest=$(fetch_url "https://api.github.com/repos/kubernetes/kubernetes/releases" | jq -r "[.[] | select(.tag_name | startswith(\"v$major_minor.\")) | select(.prerelease == false)] | .[0].tag_name" 2>/dev/null | command sed 's/^v//')
    fi

    # If no specific version found, get the latest stable release (not stable.txt which lags behind)
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
        latest=$(fetch_url "https://api.github.com/repos/kubernetes/kubernetes/releases" | jq -r '[.[] | select(.prerelease == false)] | .[0].tag_name' 2>/dev/null | command sed 's/^v//')
    fi

    set_latest "kubectl" "$latest"
    progress_done
}
