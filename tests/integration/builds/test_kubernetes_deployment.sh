#!/usr/bin/env bash
# Test Kubernetes deployment manifests with kind (Kubernetes in Docker)
#
# This test verifies the Kubernetes manifests work correctly by:
# - Building a container with Docker and Kubernetes tools
# - Creating a kind cluster inside the container (Docker-in-Docker)
# - Applying the manifests for each environment (dev, staging, production)
# - Verifying deployments succeed with correct replica counts
#
# REQUIREMENTS:
# - Docker with privileged mode support (for Docker-in-Docker)
# - At least 4GB RAM available for Docker
# - May take 5-10 minutes to complete (builds image + creates cluster)
#
# NOTE: This test uses --privileged containers which may not work in all
# CI environments. If running in CI, ensure the runner supports privileged mode.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the test framework
source "$SCRIPT_DIR/../../framework.sh"

# Initialize the test framework
init_test_framework

# For standalone testing, we build from containers directory
export BUILD_CONTEXT="$CONTAINERS_DIR"

# Define test suite
test_suite "Kubernetes Deployment Manifests"

# Test: Build container with Docker and Kubernetes
test_kubernetes_container_build() {
    # Use pre-built image if provided, otherwise build locally
    if [ -n "${IMAGE_TO_TEST:-}" ]; then
        local image="$IMAGE_TO_TEST"
        echo "Testing pre-built image: $image"
    else
        local image="test-k8s-$$"
        echo "Building image locally: $image"

        # Build with Docker and Kubernetes tools
        assert_build_succeeds "Dockerfile" \
            --build-arg PROJECT_PATH=. \
            --build-arg PROJECT_NAME=test-k8s \
            --build-arg INCLUDE_DOCKER=true \
            --build-arg INCLUDE_KUBERNETES=true \
            -t "$image"
    fi

    # Verify Docker is installed
    assert_executable_in_path "$image" "docker"

    # Verify Kubernetes tools are installed
    assert_executable_in_path "$image" "kubectl"
    assert_executable_in_path "$image" "helm"

    # Store image name for subsequent tests
    export K8S_TEST_IMAGE="$image"
}

# Test: kind can create a cluster
test_kind_cluster_creation() {
    local image="${K8S_TEST_IMAGE:-test-k8s-$$}"
    local container="k8s-test-$$"

    # Start container with Docker-in-Docker support
    # Need --privileged for Docker daemon inside container
    docker run -d \
        --name "$container" \
        --privileged \
        -v "$CONTAINERS_DIR/examples:/workspace/examples:ro" \
        "$image" \
        sleep infinity

    # Add to cleanup list
    TEST_CONTAINERS+=("$container")

    # Start Docker daemon inside the container
    docker exec "$container" sh -c "
        # Start Docker daemon in background
        dockerd > /var/log/docker.log 2>&1 &

        # Wait for Docker to be ready
        for i in {1..30}; do
            if docker info >/dev/null 2>&1; then
                echo 'Docker is ready'
                exit 0
            fi
            echo 'Waiting for Docker...'
            sleep 1
        done
        echo 'Docker failed to start'
        exit 1
    "

    assert_exit_code 0 "Docker daemon should start successfully"

    # Install kind inside the container
    docker exec "$container" sh -c "
        # Download kind binary
        curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
        chmod +x /usr/local/bin/kind

        # Verify kind works
        kind version
    "

    assert_exit_code 0 "kind should be installed successfully"

    # Create a kind cluster
    docker exec "$container" sh -c "
        # Create kind cluster
        kind create cluster --name test-cluster --wait 5m

        # Verify cluster is ready
        kubectl cluster-info
        kubectl get nodes
    "

    assert_exit_code 0 "kind cluster should be created successfully"

    # Export container name for subsequent tests
    export K8S_TEST_CONTAINER="$container"
}

# Test: Development environment deployment
test_development_deployment() {
    local container="${K8S_TEST_CONTAINER}"
    local image="${K8S_TEST_IMAGE:-test-k8s-$$}"

    # Load the test image into kind cluster
    docker exec "$container" sh -c "
        # Save image and load into kind
        kind load docker-image '$image' --name test-cluster
    "

    assert_exit_code 0 "Image should load into kind cluster"

    # Apply development manifests
    docker exec "$container" sh -c "
        cd /workspace/examples/kubernetes

        # Update kustomization to use our test image
        cd overlays/development
        command cat > image-patch.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

images:
  - name: ghcr.io/joshjhall/containers
    newName: ${image}
    newTag: latest
EOF

        # Add image patch to kustomization
        if ! command grep -q 'image-patch.yaml' kustomization.yaml; then
            echo '  - image-patch.yaml' >> kustomization.yaml
        fi

        # Apply the manifests
        kubectl apply -k .

        # Wait for deployment to be ready (timeout 2 minutes)
        kubectl wait --for=condition=available --timeout=120s deployment/dev-devcontainer -n dev || {
            echo 'Deployment not ready, checking status...'
            kubectl get all -n dev
            kubectl describe deployment dev-devcontainer -n dev
            kubectl describe pods -n dev
            kubectl logs -n dev -l app=devcontainer --tail=50 || true
            exit 1
        }

        # Verify pod is running
        kubectl get pods -n dev -l app=devcontainer
    " 2>&1 && deployment_result=$? || deployment_result=$?

    # Check if deployment succeeded
    if [ "$deployment_result" -eq 0 ]; then
        echo "Development deployment succeeded"
    else
        echo "Development deployment failed"
        # Get debug info
        docker exec "$container" sh -c "
            echo '=== Pods ==='
            kubectl get pods -n dev
            echo '=== Deployment ==='
            kubectl describe deployment dev-devcontainer -n dev
            echo '=== Events ==='
            kubectl get events -n dev --sort-by='.lastTimestamp'
        " 2>&1 || true
        return 1
    fi

    assert_exit_code "$deployment_result" "Development deployment should succeed"
}

# Test: Staging environment deployment
test_staging_deployment() {
    local container="${K8S_TEST_CONTAINER}"
    local image="${K8S_TEST_IMAGE:-test-k8s-$$}"

    # Apply staging manifests
    docker exec "$container" sh -c "
        cd /workspace/examples/kubernetes/overlays/staging

        # Update image reference
        command cat > image-patch.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

images:
  - name: ghcr.io/joshjhall/containers
    newName: ${image}
    newTag: latest
EOF

        if ! command grep -q 'image-patch.yaml' kustomization.yaml; then
            echo '  - image-patch.yaml' >> kustomization.yaml
        fi

        # Apply the manifests
        kubectl apply -k .

        # Wait for deployment (2 replicas)
        kubectl wait --for=condition=available --timeout=120s deployment/staging-devcontainer -n staging || {
            echo 'Deployment not ready, checking status...'
            kubectl get all -n staging
            kubectl describe deployment staging-devcontainer -n staging
            exit 1
        }

        # Verify 2 pods are running
        pod_count=\$(kubectl get pods -n staging -l app=devcontainer --no-headers | command wc -l)
        if [ \"\$pod_count\" -lt 2 ]; then
            echo \"Expected 2 pods, found \$pod_count\"
            exit 1
        fi

        echo 'Staging deployment succeeded with 2 replicas'
    " 2>&1

    assert_exit_code 0 "Staging deployment should succeed with 2 replicas"
}

# Test: Production environment deployment
test_production_deployment() {
    local container="${K8S_TEST_CONTAINER}"
    local image="${K8S_TEST_IMAGE:-test-k8s-$$}"

    # Apply production manifests
    docker exec "$container" sh -c "
        cd /workspace/examples/kubernetes/overlays/production

        # Update image reference
        command cat > image-patch.yaml << 'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

images:
  - name: ghcr.io/joshjhall/containers
    newName: ${image}
    newTag: latest
EOF

        if ! command grep -q 'image-patch.yaml' kustomization.yaml; then
            echo '  - image-patch.yaml' >> kustomization.yaml
        fi

        # Production needs persistent volume, update to use hostPath for testing
        command cat > pvc-patch.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: devcontainer-cache-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: standard
EOF

        if ! command grep -q 'pvc-patch.yaml' kustomization.yaml; then
            command sed -i '/persistentvolumeclaim.yaml/d' kustomization.yaml
            echo '  - pvc-patch.yaml' >> kustomization.yaml
        fi

        # Apply the manifests
        kubectl apply -k .

        # Wait for deployment (3 replicas)
        kubectl wait --for=condition=available --timeout=180s deployment/prod-devcontainer -n production || {
            echo 'Deployment not ready, checking status...'
            kubectl get all -n production
            kubectl describe deployment prod-devcontainer -n production
            kubectl describe pods -n production
            kubectl get pvc -n production
            kubectl describe pvc -n production
            exit 1
        }

        # Verify 3 pods are running
        pod_count=\$(kubectl get pods -n production -l app=devcontainer --field-selector=status.phase=Running --no-headers | command wc -l)
        if [ \"\$pod_count\" -lt 3 ]; then
            echo \"Expected 3 running pods, found \$pod_count\"
            kubectl get pods -n production -l app=devcontainer
            exit 1
        fi

        echo 'Production deployment succeeded with 3 replicas'
    " 2>&1

    assert_exit_code 0 "Production deployment should succeed with 3 replicas"
}

# Test: Network policies are created
test_network_policies() {
    local container="${K8S_TEST_CONTAINER}"

    docker exec "$container" sh -c "
        # Check network policies exist
        policy_count=\$(kubectl get networkpolicy -n production --no-headers | command wc -l)

        if [ \"\$policy_count\" -lt 1 ]; then
            echo 'No network policies found'
            exit 1
        fi

        echo \"Found \$policy_count network policies\"
        kubectl get networkpolicy -n production
    " 2>&1

    assert_exit_code 0 "Network policies should be created"
}

# Test: Resource quotas are applied
test_resource_quotas() {
    local container="${K8S_TEST_CONTAINER}"

    docker exec "$container" sh -c "
        # Check resource quota exists
        kubectl get resourcequota -n production production-quota

        # Check limit range exists
        kubectl get limitrange -n production production-limits
    " 2>&1

    assert_exit_code 0 "Resource quotas and limit ranges should be applied"
}

# Test: Pod disruption budgets are configured
test_pod_disruption_budgets() {
    local container="${K8S_TEST_CONTAINER}"

    docker exec "$container" sh -c "
        # Check staging PDB (minAvailable: 1)
        kubectl get pdb -n staging staging-devcontainer

        # Check production PDB (minAvailable: 2)
        kubectl get pdb -n production prod-devcontainer

        # Verify production PDB settings
        min_available=\$(kubectl get pdb -n production prod-devcontainer -o jsonpath='{.spec.minAvailable}')
        if [ \"\$min_available\" != \"2\" ]; then
            echo \"Expected minAvailable=2, got \$min_available\"
            exit 1
        fi
    " 2>&1

    assert_exit_code 0 "Pod disruption budgets should be configured correctly"
}

# Test: ConfigMaps are customized per environment
test_configmap_customization() {
    local container="${K8S_TEST_CONTAINER}"

    docker exec "$container" sh -c "
        # Check dev environment value
        dev_env=\$(kubectl get configmap -n dev dev-devcontainer-config -o jsonpath='{.data.environment}')
        if [ \"\$dev_env\" != \"development\" ]; then
            echo \"Dev environment should be 'development', got '\$dev_env'\"
            exit 1
        fi

        # Check staging environment value
        staging_env=\$(kubectl get configmap -n staging staging-devcontainer-config -o jsonpath='{.data.environment}')
        if [ \"\$staging_env\" != \"staging\" ]; then
            echo \"Staging environment should be 'staging', got '\$staging_env'\"
            exit 1
        fi

        # Check production environment value
        prod_env=\$(kubectl get configmap -n production prod-devcontainer-config -o jsonpath='{.data.environment}')
        if [ \"\$prod_env\" != \"production\" ]; then
            echo \"Production environment should be 'production', got '\$prod_env'\"
            exit 1
        fi

        echo 'ConfigMaps are correctly customized per environment'
    " 2>&1

    assert_exit_code 0 "ConfigMaps should be customized per environment"
}

# Test: Kustomize builds are valid
test_kustomize_validation() {
    local container="${K8S_TEST_CONTAINER}"

    docker exec "$container" sh -c "
        cd /workspace/examples/kubernetes

        # Validate base kustomization
        kubectl kustomize base > /dev/null
        echo 'Base kustomization is valid'

        # Validate dev overlay
        kubectl kustomize overlays/development > /dev/null
        echo 'Development overlay is valid'

        # Validate staging overlay
        kubectl kustomize overlays/staging > /dev/null
        echo 'Staging overlay is valid'

        # Validate production overlay
        kubectl kustomize overlays/production > /dev/null
        echo 'Production overlay is valid'
    " 2>&1

    assert_exit_code 0 "All kustomizations should be valid"
}

# Run all tests
run_test test_kubernetes_container_build "Container builds with Docker and Kubernetes tools"
run_test test_kind_cluster_creation "kind cluster can be created"
run_test test_kustomize_validation "Kustomize manifests are valid"
run_test test_development_deployment "Development environment deploys successfully"
run_test test_staging_deployment "Staging environment deploys with HA"
run_test test_production_deployment "Production environment deploys with HA"
run_test test_network_policies "Network policies are created"
run_test test_resource_quotas "Resource quotas are applied"
run_test test_pod_disruption_budgets "Pod disruption budgets are configured"
run_test test_configmap_customization "ConfigMaps are customized per environment"

# Generate test report
generate_report
