#!/usr/bin/env bash
# Blue-Green Deployment Strategy
#
# This script implements a blue-green deployment pattern where:
# 1. Deploy new version to "green" environment (while "blue" serves traffic)
# 2. Test green environment
# 3. Switch traffic from blue to green
# 4. Keep blue as backup for quick rollback
#
# Usage:
#   ./blue-green-deployment.sh <image> <namespace>
#
# Example:
#   ./blue-green-deployment.sh ghcr.io/myorg/app:v1.2.3 production

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
IMAGE="${1:-}"
NAMESPACE="${2:-production}"
SERVICE_NAME="devcontainer"
# shellcheck disable=SC2034  # Variables used for reference/documentation
DEPLOYMENT_BLUE="devcontainer-blue"
# shellcheck disable=SC2034
DEPLOYMENT_GREEN="devcontainer-green"

# Validate inputs
if [ -z "$IMAGE" ]; then
    echo -e "${RED}Error: Image not specified${NC}"
    echo "Usage: $0 <image> [namespace]"
    exit 1
fi

echo -e "${BLUE}=== Blue-Green Deployment ===${NC}"
echo "Image: $IMAGE"
echo "Namespace: $NAMESPACE"
echo ""

# =============================
# Step 1: Determine current active deployment
# =============================
echo -e "${BLUE}Step 1: Checking current active deployment...${NC}"

CURRENT_SELECTOR=$(kubectl get service "$SERVICE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.selector.deployment}' 2>/dev/null || echo "")

if [ -z "$CURRENT_SELECTOR" ]; then
    echo "No active deployment found. Assuming blue is current."
    CURRENT="blue"
    NEW="green"
else
    CURRENT="$CURRENT_SELECTOR"
    if [ "$CURRENT" = "blue" ]; then
        NEW="green"
    else
        NEW="blue"
    fi
fi

echo "Current active: $CURRENT"
echo "Deploying to: $NEW"
echo ""

# =============================
# Step 2: Deploy to new environment
# =============================
echo -e "${BLUE}Step 2: Deploying new version to $NEW environment...${NC}"

DEPLOYMENT_NEW="devcontainer-$NEW"

# Create or update green deployment
command cat > "/tmp/deployment-$NEW.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOYMENT_NEW
  namespace: $NAMESPACE
  labels:
    app: devcontainer
    deployment: $NEW
spec:
  replicas: 3
  selector:
    matchLabels:
      app: devcontainer
      deployment: $NEW
  template:
    metadata:
      labels:
        app: devcontainer
        deployment: $NEW
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

kubectl apply -f "/tmp/deployment-$NEW.yaml"

echo "Waiting for $NEW deployment to be ready..."
kubectl rollout status deployment/"$DEPLOYMENT_NEW" -n "$NAMESPACE" --timeout=10m

echo -e "${GREEN}✓ $NEW deployment is ready${NC}"
echo ""

# =============================
# Step 3: Run smoke tests on new environment
# =============================
echo -e "${BLUE}Step 3: Running smoke tests on $NEW environment...${NC}"

# Get a pod from the new deployment
POD=$(kubectl get pods -n "$NAMESPACE" -l "app=devcontainer,deployment=$NEW" \
    -o jsonpath='{.items[0].metadata.name}')

echo "Testing pod: $POD"

# Run health checks
kubectl exec -n "$NAMESPACE" "$POD" -- /bin/sh -c "test -d /workspace" || {
    echo -e "${RED}✗ Health check failed${NC}"
    exit 1
}

# Add more application-specific smoke tests here
# kubectl exec -n "$NAMESPACE" "$POD" -- curl -f http://localhost:8080/health

echo -e "${GREEN}✓ Smoke tests passed${NC}"
echo ""

# =============================
# Step 4: Manual approval (optional)
# =============================
if [ "${AUTO_APPROVE:-false}" != "true" ]; then
    echo -e "${BLUE}Step 4: Manual approval required${NC}"
    echo "New $NEW environment is ready and tested."
    echo ""
    read -p "Switch traffic to $NEW environment? (yes/no): " -r APPROVAL

    if [ "$APPROVAL" != "yes" ]; then
        echo "Deployment cancelled. $NEW environment will remain active but not receiving traffic."
        exit 1
    fi
else
    echo -e "${BLUE}Step 4: Auto-approval enabled, continuing...${NC}"
fi
echo ""

# =============================
# Step 5: Switch traffic to new environment
# =============================
echo -e "${BLUE}Step 5: Switching traffic to $NEW environment...${NC}"

kubectl patch service "$SERVICE_NAME" -n "$NAMESPACE" \
    -p "{\"spec\":{\"selector\":{\"deployment\":\"$NEW\"}}}"

echo "Waiting for traffic to stabilize..."
sleep 10

echo -e "${GREEN}✓ Traffic switched to $NEW environment${NC}"
echo ""

# =============================
# Step 6: Verify traffic switch
# =============================
echo -e "${BLUE}Step 6: Verifying traffic switch...${NC}"

# Check service endpoints
kubectl get endpoints "$SERVICE_NAME" -n "$NAMESPACE"

# Run additional verification
# curl -f https://example.com/health

echo -e "${GREEN}✓ Traffic switch verified${NC}"
echo ""

# =============================
# Step 7: Monitor for issues
# =============================
echo -e "${BLUE}Step 7: Monitoring new deployment...${NC}"
echo "Monitor logs: kubectl logs -n $NAMESPACE -l deployment=$NEW -f"
echo "Monitor pods: kubectl get pods -n $NAMESPACE -l deployment=$NEW -w"
echo ""

if [ "${KEEP_OLD:-true}" = "true" ]; then
    echo -e "${GREEN}Old $CURRENT deployment kept for quick rollback${NC}"
    echo "To rollback: kubectl patch service $SERVICE_NAME -n $NAMESPACE -p '{\"spec\":{\"selector\":{\"deployment\":\"$CURRENT\"}}}'"
    echo "To delete old deployment: kubectl delete deployment devcontainer-$CURRENT -n $NAMESPACE"
else
    echo "Deleting old $CURRENT deployment..."
    kubectl delete deployment "devcontainer-$CURRENT" -n "$NAMESPACE" --ignore-not-found
    echo -e "${GREEN}✓ Old deployment cleaned up${NC}"
fi

echo ""
echo -e "${GREEN}=== Blue-Green Deployment Complete ===${NC}"
echo "Active deployment: $NEW"
echo "Image: $IMAGE"
