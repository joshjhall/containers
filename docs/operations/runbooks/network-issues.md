# Network Issues

Debug and resolve container network connectivity problems.

## Symptoms

- Container cannot reach external services
- DNS resolution failures
- Package downloads fail with timeout
- Service-to-service communication fails

## Quick Checks

```bash
# Test DNS resolution
docker run --rm debian:bookworm-slim nslookup google.com

# Test external connectivity
docker run --rm debian:bookworm-slim curl -I https://google.com

# Check Docker networks
docker network ls

# Inspect container network
docker inspect <container_id> --format='{{json .NetworkSettings.Networks}}'
```

## Common Causes

### 1. DNS Resolution Failure

**Symptom**: "Could not resolve host" errors

**Check**:

```bash
# Test DNS
docker run --rm debian:bookworm-slim cat /etc/resolv.conf
docker run --rm debian:bookworm-slim nslookup deb.debian.org
```

**Fix**:

```bash
# Configure Docker DNS
# /etc/docker/daemon.json
{
  "dns": ["8.8.8.8", "8.8.4.4"]
}

# Or per-container
docker run --dns 8.8.8.8 <image>
```

### 2. Proxy Not Configured

**Symptom**: Timeouts when corporate proxy is required

**Check**:

```bash
# Check proxy settings
docker run --rm <image> env | grep -i proxy
```

**Fix**:

```bash
# Set proxy in docker-compose.yml
services:
  app:
    environment:
      - HTTP_PROXY=http://proxy.corp:8080
      - HTTPS_PROXY=http://proxy.corp:8080
      - NO_PROXY=localhost,127.0.0.1,.internal

# Or in build
docker build --build-arg HTTP_PROXY=http://proxy:8080 .
```

### 3. Firewall Blocking Traffic

**Symptom**: Connection refused or timeout

**Check**:

```bash
# Test specific port
docker run --rm debian:bookworm-slim nc -zv github.com 443

# Check iptables (on host)
sudo iptables -L -n | grep DOCKER
```

**Fix**: Configure firewall to allow Docker traffic

### 4. Docker Network Exhausted

**Symptom**: "network not found" or IP allocation fails

**Check**:

```bash
# List all networks
docker network ls

# Check network allocation
docker network inspect bridge | grep Subnet
```

**Fix**:

```bash
# Remove unused networks
docker network prune

# Create new network with larger subnet
docker network create --subnet=172.20.0.0/16 mynet
```

### 5. Container Network Mode

**Symptom**: Network works differently than expected

**Check**:

```bash
docker inspect <container_id> --format='{{.HostConfig.NetworkMode}}'
```

**Fix**: Use appropriate network mode for your use case

## Diagnostic Steps

### Step 1: Basic Connectivity

```bash
# Ping test
docker run --rm debian:bookworm-slim ping -c 3 8.8.8.8

# DNS test
docker run --rm debian:bookworm-slim nslookup google.com

# HTTP test
docker run --rm debian:bookworm-slim curl -v https://google.com
```

### Step 2: Check Network Configuration

```bash
# View container's network settings
docker exec <container_id> cat /etc/resolv.conf
docker exec <container_id> ip addr
docker exec <container_id> ip route
```

### Step 3: Test Specific Endpoints

```bash
# Test apt mirrors
docker run --rm debian:bookworm-slim curl -I http://deb.debian.org

# Test GitHub
docker run --rm debian:bookworm-slim curl -I https://api.github.com

# Test Python packages
docker run --rm debian:bookworm-slim curl -I https://pypi.org
```

### Step 4: Compare With Host

```bash
# Test from host (should work)
curl -I https://google.com

# Test from container (should match)
docker run --network host debian:bookworm-slim curl -I https://google.com
```

### Step 5: Check for MTU Issues

```bash
# Check MTU settings
docker network inspect bridge | grep MTU

# Test with different MTU
docker run --rm --network-opt com.docker.network.driver.mtu=1400 \
  debian:bookworm-slim ping -c 3 google.com
```

## Resolution

### Fix DNS Resolution

```bash
# Method 1: Docker daemon config
# /etc/docker/daemon.json
{
  "dns": ["8.8.8.8", "8.8.4.4", "1.1.1.1"]
}
sudo systemctl restart docker

# Method 2: Per-container
docker run --dns 8.8.8.8 <image>

# Method 3: Docker Compose
services:
  app:
    dns:
      - 8.8.8.8
      - 8.8.4.4
```

### Configure Proxy

```bash
# Build-time proxy
docker build \
  --build-arg HTTP_PROXY=$HTTP_PROXY \
  --build-arg HTTPS_PROXY=$HTTPS_PROXY \
  --build-arg NO_PROXY=$NO_PROXY \
  .

# Runtime proxy (docker-compose.yml)
services:
  app:
    environment:
      - HTTP_PROXY=${HTTP_PROXY}
      - HTTPS_PROXY=${HTTPS_PROXY}
      - NO_PROXY=${NO_PROXY}
```

### Use Host Network (Debugging Only)

```bash
# Bypass Docker networking for debugging
docker run --network host <image>
```

### Reset Docker Networking

```bash
# Stop all containers
docker stop $(docker ps -q)

# Remove all networks
docker network prune -f

# Restart Docker
sudo systemctl restart docker
```

### Kubernetes Network Issues

```bash
# Check pod DNS
kubectl exec <pod> -- cat /etc/resolv.conf

# Test service discovery
kubectl exec <pod> -- nslookup kubernetes.default

# Check network policies
kubectl get networkpolicies -A
```

## Network Debugging Tools

### In Container

```bash
# Install network tools (during debug)
apt-get update && apt-get install -y \
  curl \
  dnsutils \
  iputils-ping \
  netcat-openbsd \
  tcpdump

# DNS lookup
nslookup example.com

# TCP connection test
nc -zv example.com 443

# HTTP test with timing
curl -w "\nDNS: %{time_namelookup}s\nConnect: %{time_connect}s\nTotal: %{time_total}s\n" \
  -o /dev/null -s https://example.com
```

### From Host

```bash
# Watch Docker network traffic
sudo tcpdump -i docker0

# Check iptables rules
sudo iptables -L -n -v | grep -A5 DOCKER
```

## Common Error Messages

### "Temporary failure in name resolution"

DNS server unreachable. Configure Docker DNS.

### "Connection timed out"

Network unreachable or firewall blocking. Check connectivity and firewall rules.

### "SSL: CERTIFICATE_VERIFY_FAILED"

Corporate proxy intercepting HTTPS. Configure proxy CA certificates.

### "Network is unreachable"

Docker network misconfigured. Restart Docker or recreate network.

## Prevention

1. **Configure DNS** in Docker daemon
2. **Document proxy settings** for corporate environments
3. **Test network** as part of container startup
4. **Monitor connectivity** in health checks
5. **Use network policies** to document expected connections

## Escalation

If network issues persist:

1. Document the specific error message
2. Include results of diagnostic steps
3. Note network environment (corporate, VPN, etc.)
4. Provide Docker and OS versions
5. Open GitHub issue with `bug` label
