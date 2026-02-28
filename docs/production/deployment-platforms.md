# Logging, Registries, and Deployment Platforms

This page covers structured logging, container registry management, and
deployment configurations for various platforms.

## Logging and Monitoring

### Structured Logging

Use structured logging format (JSON) for production:

```python
import logging
import json

logging.basicConfig(
    format='%(message)s',
    level=logging.INFO
)

# Log as JSON
logging.info(json.dumps({
    "level": "info",
    "message": "Request processed",
    "duration_ms": 42,
    "user_id": 123
}))
```

### Log to STDOUT/STDERR

Always log to stdout/stderr, not files:

```bash
# Good: Logs go to container logs
python app.py

# Bad: Logs go to file (not collected)
python app.py > /var/log/app.log 2>&1
```

### Centralized Logging

Forward logs to centralized system:

- **Docker**: Use log drivers

  ```bash
  docker run \
    --log-driver=fluentd \
    --log-opt fluentd-address=localhost:24224 \
    myapp:prod
  ```

- **Kubernetes**: Use DaemonSet log collectors (Fluentd, Filebeat)

### Metrics and Monitoring

Expose metrics for Prometheus/monitoring:

```python
from prometheus_client import Counter, start_http_server

requests_total = Counter('http_requests_total', 'Total HTTP requests')

# Start metrics server on :9090
start_http_server(9090)
```

______________________________________________________________________

## Container Registries

### Push to Production Registry

```bash
# Tag for registry
docker tag myapp:prod registry.example.com/myapp:1.0.0
docker tag myapp:prod registry.example.com/myapp:latest

# Push
docker push registry.example.com/myapp:1.0.0
docker push registry.example.com/myapp:latest
```

### Image Signing (Content Trust)

Enable Docker Content Trust:

```bash
# Enable DCT
export DOCKER_CONTENT_TRUST=1

# Sign and push
docker push registry.example.com/myapp:1.0.0
```

### Image Scanning in Registry

Configure automatic scanning:

**Docker Hub**:

- Enable automatic vulnerability scanning in repository settings

**AWS ECR**:

```bash
aws ecr put-image-scanning-configuration \
  --repository-name myapp \
  --image-scanning-configuration scanOnPush=true
```

**Google Artifact Registry**:

- Enable vulnerability scanning in registry settings

______________________________________________________________________

## Deployment Platforms

### Docker Compose (Simple Production)

```yaml
version: '3.8'

services:
  app:
    image: registry.example.com/myapp:1.0.0
    restart: unless-stopped
    environment:
      - NODE_ENV=production
    env_file:
      - .env.production
    secrets:
      - db_password
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:8080/health']
      interval: 30s
      timeout: 3s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '10m'
        max-file: '3'
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 512M
        reservations:
          cpus: '0.5'
          memory: 256M

secrets:
  db_password:
    external: true
```

### Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
        - name: myapp
          image: registry.example.com/myapp:1.0.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          env:
            - name: NODE_ENV
              value: 'production'
          envFrom:
            - secretRef:
                name: myapp-secrets
          resources:
            requests:
              memory: '256Mi'
              cpu: '250m'
            limits:
              memory: '512Mi'
              cpu: '500m'
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
```

### AWS ECS/Fargate

```json
{
  "family": "myapp",
  "taskRoleArn": "arn:aws:iam::123456789:role/myapp-task",
  "executionRoleArn": "arn:aws:iam::123456789:role/myapp-execution",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "containerDefinitions": [
    {
      "name": "myapp",
      "image": "registry.example.com/myapp:1.0.0",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f http://localhost:8080/health || exit 1"
        ],
        "interval": 30,
        "timeout": 5,
        "retries": 3
      },
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/myapp",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "secrets": [
        {
          "name": "DATABASE_URL",
          "valueFrom": "arn:aws:secretsmanager:us-east-1:123456789:secret:myapp-db"
        }
      ]
    }
  ]
}
```
