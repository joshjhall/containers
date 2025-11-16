#!/usr/bin/env bash
# Canary Deployment Strategy
#
# This script implements a canary deployment pattern where:
# 1. Deploy new version alongside current version
# 2. Route small percentage of traffic to canary (e.g., 10%)
# 3. Monitor canary for issues
# 4. Gradually increase traffic to canary
# 5. If successful, replace main deployment
# 6. If issues detected, rollback canary
#
# Usage:
#   ./canary-deployment.sh <image> <namespace> [canary-percentage]
#
# Example:
#   ./canary-deployment.sh ghcr.io/myorg/app:v1.2.3 production 10

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
IMAGE="${1:-}"
NAMESPACE="${2:-production}"
CANARY_PERCENTAGE="${3:-10}"
SERVICE_NAME="devcontainer"
DEPLOYMENT_MAIN="devcontainer"
DEPLOYMENT_CANARY="devcontainer-canary"

# Validate inputs
if [ -z "$IMAGE" ]; then
    echo -e "${RED}Error: Image not specified${NC}"
    echo "Usage: $0 <image> [namespace] [canary-percentage]"
    exit 1
fi

echo -e "${BLUE}=== Canary Deployment ===${NC}"
echo "Image: $IMAGE"
echo "Namespace: $NAMESPACE"
echo "Canary traffic: ${CANARY_PERCENTAGE}%"
echo ""

# =============================
# Step 1: Deploy canary
# =============================
echo -e "${BLUE}Step 1: Deploying canary version...${NC}"

# Calculate canary replicas (minimum 1)
MAIN_REPLICAS=$(kubectl get deployment "$DEPLOYMENT_MAIN" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "3")

CANARY_REPLICAS=$(( (MAIN_REPLICAS * CANARY_PERCENTAGE + 99) / 100 ))
if [ "$CANARY_REPLICAS" -lt 1 ]; then
    CANARY_REPLICAS=1
fi

echo "Main replicas: $MAIN_REPLICAS"
echo "Canary replicas: $CANARY_REPLICAS"

# Create canary deployment
command cat > /tmp/deployment-canary.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_CANARY
  namespace: $NAMESPACE
  labels:
    app: devcontainer
    variant: canary
spec:
  replicas: $CANARY_REPLICAS
  selector:
    matchLabels:
      app: devcontainer
      variant: canary
  template:
    metadata:
      labels:
        app: devcontainer
        variant: canary
      annotations:
        deployment.timestamp: "$(date +%s)"
    spec:
      containers:
      - name: devcontainer
        image: $IMAGE
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2000m"
            memory: "2Gi"
        livenessProbe:
          exec:
            command: ["/bin/sh", "-c", "ps aux | grep -v grep | grep -q sleep"]
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          exec:
            command: ["/bin/sh", "-c", "test -d /workspace"]
          initialDelaySeconds: 5
          periodSeconds: 10
EOF

kubectl apply -f /tmp/deployment-canary.yaml

echo "Waiting for canary deployment to be ready..."
kubectl rollout status deployment/"$DEPLOYMENT_CANARY" -n "$NAMESPACE" --timeout=10m

echo -e "${GREEN}✓ Canary deployment is ready${NC}"
echo ""

# =============================
# Step 2: Configure traffic routing
# =============================
echo -e "${BLUE}Step 2: Configuring traffic routing...${NC}"

# Update service to include both main and canary pods
kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" \
    -p '{"spec":{"selector":{"app":"devcontainer"}}}'

echo "Service now routes to both main and canary pods"
echo "Traffic distribution:"
echo "  Main: ~$((100 - CANARY_PERCENTAGE))%"
echo "  Canary: ~${CANARY_PERCENTAGE}%"
echo ""

# Note: For precise traffic control, use a service mesh like Istio or Linkerd
# Example Istio VirtualService for 10% canary:
# apiVersion: networking.istio.io/v1beta1
# kind: VirtualService
# metadata:
#   name: devcontainer
# spec:
#   hosts:
#   - devcontainer
#   http:
#   - match:
#     - headers:
#         canary:
#           exact: "true"
#     route:
#     - destination:
#         host: devcontainer
#         subset: canary
#       weight: 100
#   - route:
#     - destination:
#         host: devcontainer
#         subset: stable
#       weight: 90
#     - destination:
#         host: devcontainer
#         subset: canary
#       weight: 10

# =============================
# Step 3: Monitor canary
# =============================
echo -e "${BLUE}Step 3: Monitoring canary deployment...${NC}"
echo ""

MONITORING_DURATION="${MONITORING_DURATION:-300}"  # 5 minutes
echo "Monitoring for ${MONITORING_DURATION} seconds..."
echo "Press Ctrl+C to stop early and proceed to next step"

monitor_canary() {
    local start_time
    start_time=$(date +%s)

    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ $elapsed -ge "$MONITORING_DURATION" ]; then
            break
        fi

        # Check canary pods
        local canary_ready
        canary_ready=$(kubectl get pods -n "$NAMESPACE" -l "app=devcontainer,variant=canary" \
            --field-selector=status.phase=Running \
            --no-headers 2>/dev/null | wc -l)

        # Check for pod restarts (indicates issues)
        local canary_restarts
        canary_restarts=$(kubectl get pods -n "$NAMESPACE" -l "app=devcontainer,variant=canary" \
            -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null)

        # Check error rate (example - customize for your metrics)
        # local error_rate=$(curl -s "http://prometheus:9090/api/v1/query?query=..." | jq '.data.result[0].value[1]')

        echo "[$(date +%H:%M:%S)] Canary pods: $canary_ready/$CANARY_REPLICAS ready | Restarts: ${canary_restarts:-0}"

        # Check for issues
        if [ "$canary_ready" -lt "$CANARY_REPLICAS" ]; then
            echo -e "${YELLOW}Warning: Not all canary pods are ready${NC}"
        fi

        sleep 10
    done
}

monitor_canary || true

echo ""
echo -e "${GREEN}✓ Monitoring period complete${NC}"
echo ""

# =============================
# Step 4: Analyze canary metrics
# =============================
echo -e "${BLUE}Step 4: Analyzing canary metrics...${NC}"

# Get canary pod restart count
CANARY_RESTARTS=$(kubectl get pods -n "$NAMESPACE" -l "app=devcontainer,variant=canary" \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
    | awk '{s+=$1} END {print s}')

echo "Total canary restarts: ${CANARY_RESTARTS:-0}"

# Add custom metrics analysis here
# - Error rate
# - Response time
# - Resource usage
# - Custom business metrics

# Simple health check
CANARY_HEALTHY=$(kubectl get pods -n "$NAMESPACE" -l "app=devcontainer,variant=canary" \
    --field-selector=status.phase=Running --no-headers | wc -l)

if [ "$CANARY_HEALTHY" -lt "$CANARY_REPLICAS" ]; then
    echo -e "${RED}✗ Canary health check failed${NC}"
    echo "Only $CANARY_HEALTHY/$CANARY_REPLICAS pods are healthy"

    if [ "${AUTO_ROLLBACK:-true}" = "true" ]; then
        echo "Auto-rolling back canary..."
        kubectl delete deployment "$DEPLOYMENT_CANARY" -n "$NAMESPACE"
        echo -e "${YELLOW}Canary rolled back${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ Canary appears healthy${NC}"
fi

echo ""

# =============================
# Step 5: Decision point
# =============================
if [ "${AUTO_PROMOTE:-false}" != "true" ]; then
    echo -e "${BLUE}Step 5: Promotion decision${NC}"
    echo "Canary is running with ${CANARY_PERCENTAGE}% traffic"
    echo ""
    echo "Options:"
    echo "  1) Promote canary to production (replace main deployment)"
    echo "  2) Increase canary traffic to 25%"
    echo "  3) Increase canary traffic to 50%"
    echo "  4) Rollback canary"
    echo ""
    read -p "Choose option (1-4): " -r DECISION

    case $DECISION in
        1)
            PROMOTE=true
            ;;
        2|3)
            echo "Increasing canary traffic not fully implemented in this example"
            echo "Requires service mesh or manual replica adjustment"
            exit 0
            ;;
        4)
            echo "Rolling back canary..."
            kubectl delete deployment "$DEPLOYMENT_CANARY" -n "$NAMESPACE"
            echo -e "${GREEN}✓ Canary rolled back${NC}"
            exit 0
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
else
    echo -e "${BLUE}Step 5: Auto-promoting canary...${NC}"
    PROMOTE=true
fi

# =============================
# Step 6: Promote canary
# =============================
if [ "${PROMOTE:-false}" = "true" ]; then
    echo -e "${BLUE}Step 6: Promoting canary to production...${NC}"

    # Update main deployment with canary image
    kubectl set image deployment/"$DEPLOYMENT_MAIN" \
        devcontainer="$IMAGE" \
        -n "$NAMESPACE"

    echo "Waiting for main deployment rollout..."
    kubectl rollout status deployment/"$DEPLOYMENT_MAIN" -n "$NAMESPACE" --timeout=10m

    # Delete canary deployment
    kubectl delete deployment "$DEPLOYMENT_CANARY" -n "$NAMESPACE"

    echo -e "${GREEN}✓ Canary promoted to production${NC}"
    echo ""
    echo -e "${GREEN}=== Canary Deployment Complete ===${NC}"
    echo "Main deployment updated to: $IMAGE"
fi
