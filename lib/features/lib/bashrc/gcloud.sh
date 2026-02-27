# ----------------------------------------------------------------------------
# Google Cloud SDK Configuration and Helpers
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
# Google Cloud Aliases - Common gcloud shortcuts
# ----------------------------------------------------------------------------
alias gc='gcloud'
alias gcauth='gcloud auth login'
alias gcproj='gcloud config set project'
alias gcprojs='gcloud projects list'
alias gcconf='gcloud config list'
alias gccompute='gcloud compute'
alias gcssh='gcloud compute ssh'
alias gcinstances='gcloud compute instances list'
alias gck8s='gcloud container clusters'
alias gcfunc='gcloud functions'
alias gcrun='gcloud run'

# ----------------------------------------------------------------------------
# gcloud-project - Switch or display GCP project
#
# Arguments:
#   $1 - Project ID to switch to (optional)
#
# Examples:
#   gcloud-project           # Show current project and list all
#   gcloud-project my-project # Switch to my-project
# ----------------------------------------------------------------------------
gcloud-project() {
    if [ -z "$1" ]; then
        echo "Current project: $(gcloud config get-value project)"
        echo "Available projects:"
        gcloud projects list
    else
        gcloud config set project "$1"
        echo "Switched to project: $1"
    fi
}

gcloud-region() {
    if [ -z "$1" ]; then
        echo "Current region: $(gcloud config get-value compute/region)"
        echo "Current zone: $(gcloud config get-value compute/zone)"
    else
        gcloud config set compute/region "$1"
        echo "Set region to: $1"
        if [ -n "$2" ]; then
            gcloud config set compute/zone "$2"
            echo "Set zone to: $2"
        fi
    fi
}

# ----------------------------------------------------------------------------
# gcssh-quick - SSH to GCE instance with minimal typing
#
# Arguments:
#   $1 - Instance name (required)
#   $2 - Zone (optional, uses default if not specified)
#
# Example:
#   gcssh-quick web-server us-central1-a
# ----------------------------------------------------------------------------
gcssh-quick() {
    if [ -z "$1" ]; then
        echo "Usage: gcssh-quick <instance-name> [zone]"
        return 1
    fi
    local instance="$1"
    local zone="${2:-$(gcloud config get-value compute/zone)}"
    gcloud compute ssh "$instance" --zone="$zone"
}

# ----------------------------------------------------------------------------
# gcloud-resources - List all major GCP resources in current project
#
# Shows:
#   - Compute Engine instances
#   - GKE clusters
#   - Cloud Run services
#   - Cloud Functions
# ----------------------------------------------------------------------------
gcloud-resources() {
    echo "=== Compute Instances ==="
    gcloud compute instances list 2>/dev/null || echo "No instances"
    echo -e "\n=== Container Clusters ==="
    gcloud container clusters list 2>/dev/null || echo "No clusters"
    echo -e "\n=== Cloud Run Services ==="
    gcloud run services list 2>/dev/null || echo "No services"
    echo -e "\n=== Cloud Functions ==="
    gcloud functions list 2>/dev/null || echo "No functions"
}

# GCloud auto-completion is automatically enabled by the package


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
