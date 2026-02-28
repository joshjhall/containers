# ----------------------------------------------------------------------------
# Kubernetes environment configuration
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
# Kubernetes Aliases - Common kubectl operations
# ----------------------------------------------------------------------------
alias k='kubectl'                                    # Short alias
alias kgp='kubectl get pods'                        # List pods
alias kgpa='kubectl get pods --all-namespaces'      # List all pods
alias kgs='kubectl get svc'                         # List services
alias kgd='kubectl get deployment'                  # List deployments
alias kgn='kubectl get nodes'                       # List nodes
alias kgns='kubectl get namespaces'                 # List namespaces
alias kaf='kubectl apply -f'                        # Apply config
alias kdel='kubectl delete'                         # Delete resource
alias klog='kubectl logs'                           # View logs
alias kexec='kubectl exec -it'                      # Execute in pod
alias kctx='kubectl config current-context'         # Current context
alias kns='kubectl config set-context --current --namespace'  # Set namespace
alias kdesc='kubectl describe'                      # Describe resource
alias kpf='kubectl port-forward'                    # Port forwarding

# kubectl auto-completion with validation
if command -v kubectl &> /dev/null; then
    COMPLETION_FILE="/tmp/kubectl-completion.$$.bash"
    if kubectl completion bash > "$COMPLETION_FILE" 2>/dev/null; then
        # Validate completion output before sourcing
        if [ -f "$COMPLETION_FILE" ] && \
           [ "$(wc -c < "$COMPLETION_FILE")" -lt 100000 ] && \
           ! command grep -qE '(rm -rf|curl.*bash|wget.*bash|eval.*\$)' "$COMPLETION_FILE"; then
            # shellcheck disable=SC1090  # Dynamic source is validated
            source "$COMPLETION_FILE"
            complete -F __start_kubectl k
        fi
    fi
    command rm -f "$COMPLETION_FILE"
fi

# Source base utilities for secure PATH management
if [ -f /opt/container-runtime/base/logging.sh ]; then
    source /opt/container-runtime/base/logging.sh
fi
if [ -f /opt/container-runtime/base/path-utils.sh ]; then
    source /opt/container-runtime/base/path-utils.sh
fi

# krew PATH
if command -v safe_add_to_path >/dev/null 2>&1; then
    safe_add_to_path "${HOME}/.krew/bin" 2>/dev/null || export PATH="${PATH}:${HOME}/.krew/bin"
else
    export PATH="${PATH}:${HOME}/.krew/bin"
fi

# ----------------------------------------------------------------------------
# k-logs - Stream logs from all pods matching a label
#
# Arguments:
#   $1 - Label selector (required)
#   $2 - Namespace (default: current)
#
# Example:
#   k-logs app=myapp
#   k-logs app=myapp production
# ----------------------------------------------------------------------------
k-logs() {
    if [ -z "$1" ]; then
        echo "Usage: k-logs <label-selector> [namespace]"
        return 1
    fi

    local selector="$1"
    local namespace="${2:-}"

    if [ -n "$namespace" ]; then
        kubectl logs -f -l "$selector" -n "$namespace" --all-containers=true
    else
        kubectl logs -f -l "$selector" --all-containers=true
    fi
}

# ----------------------------------------------------------------------------
# k-shell - Open shell in a pod
#
# Arguments:
#   $1 - Pod name or partial name (required)
#   $2 - Container name (optional)
#   $3 - Shell command (default: /bin/bash)
#
# Example:
#   k-shell mypod
#   k-shell mypod mycontainer
#   k-shell mypod "" /bin/sh
# ----------------------------------------------------------------------------
k-shell() {
    if [ -z "$1" ]; then
        echo "Usage: k-shell <pod-name> [container] [shell]"
        return 1
    fi

    local pod="$1"
    local container="${2:-}"
    local shell="${3:-/bin/bash}"

    # If exact pod name not found, try to find a matching pod
    if ! kubectl get pod "$pod" &>/dev/null; then
        pod=$(kubectl get pods --no-headers | command grep "$pod" | head -n1 | awk '{print $1}')
        if [ -z "$pod" ]; then
            echo "No pod matching '$1' found"
            return 1
        fi
        echo "Using pod: $pod"
    fi

    if [ -n "$container" ]; then
        kubectl exec -it "$pod" -c "$container" -- "$shell" || kubectl exec -it "$pod" -c "$container" -- /bin/sh
    else
        kubectl exec -it "$pod" -- "$shell" || kubectl exec -it "$pod" -- /bin/sh
    fi
}

# ----------------------------------------------------------------------------
# k-events - Show recent events in namespace
#
# Arguments:
#   $1 - Namespace (default: current)
#
# Example:
#   k-events
#   k-events kube-system
# ----------------------------------------------------------------------------
k-events() {
    local namespace="${1:-}"

    if [ -n "$namespace" ]; then
        kubectl get events -n "$namespace" --sort-by='.lastTimestamp' | tail -20
    else
        kubectl get events --sort-by='.lastTimestamp' | tail -20
    fi
}

# ----------------------------------------------------------------------------
# k-resources - Show resource usage for nodes or pods
#
# Arguments:
#   $1 - Resource type: "nodes" or "pods" (default: pods)
#   $2 - Namespace for pods (default: current)
#
# Example:
#   k-resources
#   k-resources nodes
#   k-resources pods kube-system
# ----------------------------------------------------------------------------
k-resources() {
    local type="${1:-pods}"
    local namespace="${2:-}"

    case "$type" in
        nodes|node)
            kubectl top nodes
            ;;
        pods|pod)
            if [ -n "$namespace" ]; then
                kubectl top pods -n "$namespace"
            else
                kubectl top pods
            fi
            ;;
        *)
            echo "Usage: k-resources [nodes|pods] [namespace]"
            return 1
            ;;
    esac
}


# Note: We leave set +u and set +e in place for interactive shells
# to prevent errors with undefined variables or failed commands
