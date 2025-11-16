# Kubernetes Deployment Guide

This directory contains production-ready Kubernetes manifests for deploying the
container build system in Kubernetes clusters.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Directory Structure](#directory-structure)
- [Deployment Environments](#deployment-environments)
- [Customization Guide](#customization-guide)
- [Security Best Practices](#security-best-practices)
- [Monitoring and Observability](#monitoring-and-observability)
- [Troubleshooting](#troubleshooting)
- [Production Checklist](#production-checklist)

## Overview

These Kubernetes manifests use **Kustomize** (built into kubectl) to provide:

- **Base configuration**: Common resources shared across all environments
- **Environment overlays**: Customizations for development, staging, and
  production
- **Security policies**: NetworkPolicies, PodDisruptionBudgets, SecurityContexts
- **Resource management**: ResourceQuotas, LimitRanges
- **Production-grade configurations**: High availability, graceful shutdown,
  health checks

## Prerequisites

### Required

- **Kubernetes cluster** (v1.19+)
  - Local: Minikube, kind, k3s, Docker Desktop
  - Cloud: EKS, GKE, AKS, DigitalOcean Kubernetes
- **kubectl** (v1.19+) -
  [Installation guide](https://kubernetes.io/docs/tasks/tools/)
- **Kustomize** (built into kubectl 1.14+)

### Optional

- **Helm** (v3+) - For Helm chart deployment (coming soon)
- **Network policy controller** - Calico, Cilium, or Weave (for NetworkPolicy
  support)
- **Metrics server** - For resource metrics and autoscaling
- **Ingress controller** - NGINX, Traefik, or cloud provider ingress

### Verify Your Cluster

```bash
# Check kubectl is configured
kubectl version

# Check cluster connection
kubectl cluster-info

# Check current context
kubectl config current-context

# View available contexts
kubectl config get-contexts

# Switch context if needed
kubectl config use-context my-cluster
```

## Quick Start

### Development Environment

```bash
# Deploy to development namespace
kubectl apply -k examples/kubernetes/overlays/development

# Check deployment status
kubectl get all -n dev

# View pod logs
kubectl logs -n dev -l app=devcontainer

# Access the container (exec into pod)
kubectl exec -it -n dev deployment/dev-devcontainer -- /bin/bash

# Port forward to access services locally
kubectl port-forward -n dev service/dev-devcontainer 8080:8080

# Clean up
kubectl delete -k examples/kubernetes/overlays/development
```

### Staging Environment

```bash
# Deploy to staging namespace
kubectl apply -k examples/kubernetes/overlays/staging

# Check deployment status
kubectl get all -n staging

# View pod logs from all replicas
kubectl logs -n staging -l app=devcontainer --all-containers=true

# Clean up
kubectl delete -k examples/kubernetes/overlays/staging
```

### Production Environment

```bash
# Deploy to production namespace
kubectl apply -k examples/kubernetes/overlays/production

# Check deployment status
kubectl get all -n production

# Check pod disruption budget
kubectl get pdb -n production

# Check network policies
kubectl get networkpolicy -n production

# Clean up (BE CAREFUL IN PRODUCTION!)
# kubectl delete -k examples/kubernetes/overlays/production
```

## Directory Structure

```
examples/kubernetes/
├── base/                           # Base configuration (shared)
│   ├── deployment.yaml            # Pod deployment specification
│   ├── service.yaml               # Service for network access
│   ├── configmap.yaml             # Configuration data
│   ├── secrets.yaml               # Sensitive data (template only)
│   └── kustomization.yaml         # Kustomize base config
│
├── overlays/                      # Environment-specific customizations
│   ├── development/               # Development environment
│   │   ├── kustomization.yaml    # Dev-specific patches
│   │   └── service-nodeport.yaml # NodePort service for local access
│   │
│   ├── staging/                   # Staging environment
│   │   ├── kustomization.yaml    # Staging-specific patches
│   │   └── poddisruptionbudget.yaml  # HA configuration
│   │
│   └── production/                # Production environment
│       ├── kustomization.yaml    # Production patches
│       ├── poddisruptionbudget.yaml  # HA configuration
│       ├── networkpolicy.yaml    # Network security policies
│       ├── resourcequota.yaml    # Namespace resource limits
│       ├── limitrange.yaml       # Container resource defaults
│       └── persistentvolumeclaim.yaml  # Persistent storage
│
├── README.md                      # This file
└── PRODUCTION-CHECKLIST.md        # Pre-deployment checklist
```

## Deployment Environments

### Development

**Purpose**: Local development and testing

**Characteristics**:

- **1 replica** - Minimal resource usage
- **Low resources** - 100m CPU, 256Mi memory requests
- **NodePort service** - Easy access from host machine
- **Debug mode enabled** - Verbose logging
- **Latest image tag** - Auto-pull newest changes

**Use cases**:

- Local development
- Testing configuration changes
- Debugging issues

**Access**:

```bash
# Via NodePort (replace <node-ip> with your node's IP)
curl http://<node-ip>:30080

# Via port-forward (works on any cluster)
kubectl port-forward -n dev service/dev-devcontainer 8080:8080
curl http://localhost:8080

# Via kubectl exec
kubectl exec -it -n dev deployment/dev-devcontainer -- /bin/bash
```

### Staging

**Purpose**: Pre-production testing

**Characteristics**:

- **2 replicas** - Test high availability
- **Medium resources** - 250m CPU, 512Mi memory requests
- **PodDisruptionBudget** - Min 1 pod available
- **Pinned image version** - Specific version tags
- **INFO logging** - Balanced verbosity

**Use cases**:

- Integration testing
- Performance testing
- UAT (User Acceptance Testing)
- Pre-production validation

### Production

**Purpose**: Production workloads

**Characteristics**:

- **3 replicas** - High availability
- **High resources** - 500m CPU, 512Mi memory requests
- **PodDisruptionBudget** - Min 2 pods available
- **NetworkPolicies** - Restricted network access
- **Pod anti-affinity** - Spread across nodes/zones
- **Persistent storage** - Data survives pod restarts
- **Read-only root filesystem** - Enhanced security
- **Resource quotas** - Prevent resource exhaustion
- **Graceful shutdown** - 30s termination grace period

**Use cases**:

- Production applications
- Critical workloads
- Customer-facing services

## Customization Guide

### Changing the Container Image

Edit the appropriate `kustomization.yaml`:

```yaml
images:
  - name: ghcr.io/joshjhall/containers
    newTag: node-dev-4.9.2 # Change to desired variant
```

Available variants:

- `minimal-VERSION` - Base system only
- `python-dev-VERSION` - Python development
- `node-dev-VERSION` - Node.js development
- `rust-dev-VERSION` - Rust development
- `golang-dev-VERSION` - Go development
- `ruby-dev-VERSION` - Ruby development
- `r-dev-VERSION` - R development
- `java-dev-VERSION` - Java development

### Adjusting Resources

Edit resource requests/limits in the overlay's `kustomization.yaml`:

```yaml
patches:
  - target:
      kind: Deployment
      name: devcontainer
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/cpu
        value: "1000m"  # 1 CPU core
      - op: replace
        path: /spec/template/spec/containers/0/resources/requests/memory
        value: "2Gi"    # 2 GB memory
```

**Resource guidelines**:

- **CPU**: 100m = 0.1 core, 1000m = 1 core
- **Memory**: 256Mi, 512Mi, 1Gi, 2Gi, 4Gi, etc.
- **Requests**: Guaranteed resources (scheduler uses this)
- **Limits**: Maximum allowed (throttling happens here)

### Adding Environment Variables

Add to `configMapGenerator` in `kustomization.yaml`:

```yaml
configMapGenerator:
  - name: devcontainer-config
    behavior: merge
    literals:
      - MY_VAR=value
      - ANOTHER_VAR=another_value
```

Or reference in deployment:

```yaml
env:
  - name: MY_VAR
    valueFrom:
      configMapKeyRef:
        name: devcontainer-config
        key: MY_VAR
```

### Managing Secrets

**Never commit real secrets to git!**

Option 1: Create secret manually:

```bash
kubectl create secret generic devcontainer-secrets \
  --from-literal=db-password=MySecretPassword123 \
  --from-file=ssh-key=~/.ssh/id_rsa \
  -n production
```

Option 2: Use external secret management:

- [External Secrets Operator](https://external-secrets.io/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [HashiCorp Vault](https://www.vaultproject.io/docs/platform/k8s)

Option 3: Use cloud provider secret managers:

- AWS Secrets Manager
- Azure Key Vault
- GCP Secret Manager

See `base/secrets.yaml` for detailed examples.

### Exposing Services

#### ClusterIP (default)

Only accessible within cluster:

```yaml
spec:
  type: ClusterIP
```

#### NodePort

Accessible on node IP:

```yaml
spec:
  type: NodePort
  ports:
    - port: 8080
      nodePort: 30080 # 30000-32767 range
```

Access: `http://<node-ip>:30080`

#### LoadBalancer

Creates cloud load balancer:

```yaml
spec:
  type: LoadBalancer
```

Get external IP:

```bash
kubectl get service -n production prod-devcontainer
```

#### Ingress

Route HTTP/HTTPS traffic:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: devcontainer-ingress
spec:
  rules:
    - host: devcontainer.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: devcontainer
                port:
                  number: 8080
```

## Security Best Practices

### 1. Run as Non-Root User

Already configured in base deployment:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
```

### 2. Read-Only Root Filesystem

Enabled in production overlay:

```yaml
securityContext:
  readOnlyRootFilesystem: true
```

**Note**: Some dev tools may need write access. Use volume mounts for writable
directories.

### 3. Drop All Capabilities

```yaml
securityContext:
  capabilities:
    drop: ['ALL']
```

### 4. Network Policies

Implemented in production overlay. Customize for your needs:

```bash
# View network policies
kubectl get networkpolicy -n production

# Describe a policy
kubectl describe networkpolicy devcontainer-ingress -n production
```

### 5. Resource Limits

Always set resource limits to prevent resource exhaustion:

```yaml
resources:
  requests: # Guaranteed
    cpu: '500m'
    memory: '512Mi'
  limits: # Maximum
    cpu: '2000m'
    memory: '2Gi'
```

### 6. Pod Security Standards

Apply pod security standards to namespaces:

```bash
# Enforce restricted pod security
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted
```

### 7. Secrets Management

**Never commit secrets to git!**

Use:

- Kubernetes secrets with encryption at rest
- External secret managers (Vault, AWS Secrets Manager)
- Sealed Secrets for GitOps

### 8. Image Security

- Use specific version tags (never `:latest` in production)
- Scan images for vulnerabilities
- Use private registries with authentication
- Verify image signatures

## Monitoring and Observability

### Health Checks

Already configured in base deployment:

**Liveness probe** - Restart container if unhealthy:

```yaml
livenessProbe:
  exec:
    command: ['/bin/sh', '-c', 'ps aux | grep -v grep | grep -q sleep']
  initialDelaySeconds: 10
  periodSeconds: 30
```

**Readiness probe** - Remove from service if not ready:

```yaml
readinessProbe:
  exec:
    command: ['/bin/sh', '-c', 'test -d /workspace']
  initialDelaySeconds: 5
  periodSeconds: 10
```

### Logging

View logs:

```bash
# Single pod
kubectl logs -n production pod/prod-devcontainer-xxxxx

# All pods matching label
kubectl logs -n production -l app=devcontainer --all-containers=true

# Follow logs (stream)
kubectl logs -n production -l app=devcontainer -f

# Previous container (if pod restarted)
kubectl logs -n production pod/prod-devcontainer-xxxxx --previous
```

### Metrics

View resource usage:

```bash
# Pod metrics (requires metrics-server)
kubectl top pods -n production

# Node metrics
kubectl top nodes

# Detailed pod information
kubectl describe pod -n production prod-devcontainer-xxxxx
```

### Events

View cluster events:

```bash
# All events in namespace
kubectl get events -n production

# Watch events
kubectl get events -n production --watch

# Events for specific pod
kubectl describe pod -n production prod-devcontainer-xxxxx
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl get pods -n production

# Describe pod for events
kubectl describe pod -n production prod-devcontainer-xxxxx

# Check logs
kubectl logs -n production prod-devcontainer-xxxxx

# Check previous logs if pod restarted
kubectl logs -n production prod-devcontainer-xxxxx --previous
```

Common issues:

- Image pull errors: Check image tag and registry access
- Resource limits: Check if resources exceed namespace quotas
- Volume mount errors: Check PVC status and storage class
- Security context errors: Check pod security policies

### Service Not Accessible

```bash
# Check service
kubectl get service -n production

# Describe service
kubectl describe service -n production prod-devcontainer

# Check endpoints (pods backing the service)
kubectl get endpoints -n production prod-devcontainer

# Test service from within cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
# Inside pod:
wget -O- http://prod-devcontainer.production.svc.cluster.local:8080
```

Common issues:

- No endpoints: Pod labels don't match service selector
- Network policy: Traffic blocked by NetworkPolicy
- Port mismatch: Service port ≠ container port

### Network Policy Issues

```bash
# Check network policies
kubectl get networkpolicy -n production

# Describe policy
kubectl describe networkpolicy -n production devcontainer-ingress

# Test connectivity
kubectl run -it --rm debug --image=nicolaka/netshoot --restart=Never -n production -- sh
# Inside pod: Try connecting to service
curl http://prod-devcontainer:8080
```

### Resource Quota Exceeded

```bash
# Check resource quotas
kubectl get resourcequota -n production

# Describe quota
kubectl describe resourcequota -n production production-quota

# View current usage
kubectl describe namespace production
```

### Persistent Volume Issues

```bash
# Check PVCs
kubectl get pvc -n production

# Describe PVC
kubectl describe pvc -n production devcontainer-cache-pvc

# Check PVs
kubectl get pv

# Check storage classes
kubectl get storageclass
```

### Debugging Inside Container

```bash
# Exec into running container
kubectl exec -it -n production deployment/prod-devcontainer -- /bin/bash

# Run debug commands
ps aux
df -h
env
netstat -tuln
```

## Production Checklist

Before deploying to production, review the
[PRODUCTION-CHECKLIST.md](./PRODUCTION-CHECKLIST.md) file.

Key items:

- [ ] Secrets are managed externally (not committed to git)
- [ ] Image tags are pinned to specific versions
- [ ] Resource limits are set appropriately
- [ ] Health checks are configured and tested
- [ ] Network policies are in place
- [ ] Monitoring and alerting configured
- [ ] Backup and disaster recovery plan exists
- [ ] Security scanning completed
- [ ] Load testing completed
- [ ] Rollback procedure documented

## Testing

### Automated Integration Tests

An automated integration test validates all Kubernetes manifests using **kind**
(Kubernetes in Docker):

```bash
# Run the Kubernetes deployment test
./tests/run_integration_tests.sh kubernetes_deployment

# Or run all integration tests (includes Kubernetes test)
./tests/run_integration_tests.sh
```

**What the test does:**

1. Builds a container with Docker and Kubernetes tools
2. Creates a kind cluster inside the container (DinD)
3. Applies manifests for all three environments (dev, staging, production)
4. Verifies:
   - Deployments succeed
   - Correct replica counts (1 for dev, 2 for staging, 3 for production)
   - Network policies are created
   - Resource quotas are applied
   - ConfigMaps are customized per environment
   - PodDisruptionBudgets are configured

**Requirements:**

- Docker with privileged mode support
- At least 4GB RAM available for Docker
- Test takes 5-10 minutes (builds image + creates cluster)

**Note**: The test uses `--privileged` containers for Docker-in-Docker, which
may not work in all CI environments.

### Manual Testing with kind

If you want to manually test with kind:

```bash
# Install kind
curl -Lo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.20.0/kind-linux-amd64
chmod +x /usr/local/bin/kind

# Create a kind cluster
kind create cluster --name test-cluster

# Build your container
docker build -t myproject:test .

# Load image into kind
kind load docker-image myproject:test --name test-cluster

# Deploy to development
kubectl apply -k examples/kubernetes/overlays/development

# Check status
kubectl get all -n dev

# Clean up
kubectl delete -k examples/kubernetes/overlays/development
kind delete cluster --name test-cluster
```

## Additional Resources

### Kubernetes Documentation

- [Kubernetes Concepts](https://kubernetes.io/docs/concepts/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [Kustomize Documentation](https://kustomize.io/)
- [kind Documentation](https://kind.sigs.k8s.io/)

### Container Documentation

- [Container Build System README](../../README.md)
- [Feature Documentation](../../docs/)
- [Docker Compose Examples](../compose/)
- [Integration Tests](../../tests/integration/)

### Learning Resources

- [Kubernetes Basics Tutorial](https://kubernetes.io/docs/tutorials/kubernetes-basics/)
- [Play with Kubernetes](https://labs.play-with-k8s.com/)
- [Kubernetes the Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)

## Support

For issues and questions:

- [GitHub Issues](https://github.com/joshjhall/containers/issues)
- [Documentation](https://github.com/joshjhall/containers/tree/main/docs)

## License

This project is licensed under the MIT License - see the
[LICENSE](../../LICENSE) file for details.
