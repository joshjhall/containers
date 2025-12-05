# Production Deployment Checklist

Use this checklist before deploying to production. Each item should be verified
and checked off.

## Pre-Deployment

### Security

- [ ] **Secrets Management**

  - [ ] Real secrets are NOT committed to git
  - [ ] Using external secret manager (Vault, AWS Secrets Manager, etc.)
  - [ ] Secret rotation policy is defined and documented
  - [ ] Least-privilege access to secrets is enforced

- [ ] **Image Security**

  - [ ] Container images scanned for vulnerabilities
  - [ ] Using specific version tags (not `:latest`)
  - [ ] Images signed and verified
  - [ ] Using private registry with authentication
  - [ ] Image pull secrets configured if using private registry

- [ ] **Network Security**

  - [ ] NetworkPolicies configured and tested
  - [ ] Default deny-all policy is in place
  - [ ] Only necessary ingress/egress rules are allowed
  - [ ] TLS/HTTPS enforced for all external communication

- [ ] **Pod Security**

  - [ ] Running as non-root user (`runAsNonRoot: true`)
  - [ ] All capabilities dropped (`capabilities: drop: ["ALL"]`)
  - [ ] Read-only root filesystem where possible
  - [ ] No privilege escalation allowed
  - [ ] Pod Security Standards enforced on namespace

- [ ] **RBAC (Role-Based Access Control)**

  - [ ] ServiceAccounts configured with minimal permissions
  - [ ] Roles/ClusterRoles follow least-privilege principle
  - [ ] No use of `cluster-admin` for applications
  - [ ] Regular audit of RBAC permissions

### Resource Management

- [ ] **Resource Limits**

  - [ ] CPU requests and limits configured
  - [ ] Memory requests and limits configured
  - [ ] Requests match actual usage (tested under load)
  - [ ] Limits prevent resource exhaustion

- [ ] **Namespace Configuration**

  - [ ] ResourceQuota applied to namespace
  - [ ] LimitRange configured for default limits
  - [ ] Namespace has appropriate labels

- [ ] **Storage**

  - [ ] PersistentVolumeClaims configured if needed
  - [ ] Storage class appropriate for workload (SSD vs HDD)
  - [ ] Backup strategy defined for persistent data
  - [ ] Volume sizes appropriate and tested

### High Availability

- [ ] **Replicas**

  - [ ] Minimum 3 replicas for production
  - [ ] Replicas tested under load
  - [ ] PodDisruptionBudget configured (minAvailable: 2)

- [ ] **Pod Scheduling**

  - [ ] Anti-affinity rules to spread pods across nodes
  - [ ] Topology spread constraints configured
  - [ ] Node selectors or affinity rules if needed
  - [ ] Tolerations configured if using tainted nodes

- [ ] **Updates and Rollbacks**

  - [ ] RollingUpdate strategy configured
  - [ ] maxUnavailable and maxSurge set appropriately
  - [ ] Rollback procedure documented and tested
  - [ ] Zero-downtime deployment verified

### Health and Observability

- [ ] **Health Checks**

  - [ ] Liveness probe configured and tested
  - [ ] Readiness probe configured and tested
  - [ ] Startup probe configured if needed (for slow-starting apps)
  - [ ] Probe thresholds appropriate for application

- [ ] **Logging**

  - [ ] Centralized logging configured (Fluentd, Logstash, etc.)
  - [ ] Log retention policy defined
  - [ ] Sensitive data not logged
  - [ ] Log levels appropriate (WARN or ERROR in production)

- [ ] **Monitoring**

  - [ ] Metrics exported (Prometheus, CloudWatch, etc.)
  - [ ] Key metrics identified and tracked
  - [ ] Dashboards created for visualization
  - [ ] Service-level objectives (SLOs) defined

- [ ] **Alerting**

  - [ ] Alerts configured for critical metrics
  - [ ] Alert routing and escalation configured
  - [ ] Runbooks exist for each alert
  - [ ] Alert fatigue minimized (no noisy alerts)

### Configuration

- [ ] **Environment Configuration**

  - [ ] ConfigMaps contain appropriate values for production
  - [ ] Environment variables properly set
  - [ ] Feature flags configured correctly
  - [ ] No debug/development features enabled

- [ ] **Image Configuration**

  - [ ] Correct image variant selected
  - [ ] Image version pinned to specific tag
  - [ ] All required features included in image
  - [ ] Image tested in staging environment

- [ ] **Service Configuration**

  - [ ] Service type appropriate (ClusterIP, LoadBalancer, etc.)
  - [ ] Service ports match application configuration
  - [ ] Session affinity configured if needed
  - [ ] External traffic policy set if using LoadBalancer

### Testing

- [ ] **Functional Testing**

  - [ ] Application functionality tested in staging
  - [ ] All critical user flows tested
  - [ ] Integration tests passing
  - [ ] End-to-end tests passing

- [ ] **Performance Testing**

  - [ ] Load testing completed
  - [ ] Performance benchmarks met
  - [ ] Resource usage under load validated
  - [ ] No memory leaks detected

- [ ] **Failure Testing**

  - [ ] Pod failures handled gracefully
  - [ ] Node failures tested (if applicable)
  - [ ] Network partition scenarios tested
  - [ ] Backup and restore tested

- [ ] **Security Testing**

  - [ ] Penetration testing completed
  - [ ] Vulnerability scanning completed
  - [ ] Compliance requirements met
  - [ ] Security audit completed

## Deployment

### Pre-Deployment Actions

- [ ] **Communication**

  - [ ] Deployment window scheduled and communicated
  - [ ] Stakeholders notified
  - [ ] Maintenance window announced if needed
  - [ ] Rollback plan communicated to team

- [ ] **Backup**

  - [ ] Current production state backed up
  - [ ] Database backup completed (if applicable)
  - [ ] Configuration exported and saved
  - [ ] Rollback scripts ready

- [ ] **Cluster Readiness**

  - [ ] Cluster capacity sufficient for deployment
  - [ ] No other maintenance scheduled
  - [ ] All nodes healthy
  - [ ] No pending security patches

### During Deployment

- [ ] **Deployment Execution**

  - [ ] Deployment command reviewed:

    ```bash
    kubectl apply -k examples/kubernetes/overlays/production
    ```

  - [ ] Deployment progress monitored

  - [ ] Rollout status verified:

    ```bash
    kubectl rollout status deployment/prod-devcontainer -n production
    ```

  - [ ] No errors in pod logs

- [ ] **Health Verification**

  - [ ] All pods running and ready
  - [ ] Health checks passing
  - [ ] Endpoints populated in service
  - [ ] No crash loops detected

### Post-Deployment

- [ ] **Smoke Testing**

  - [ ] Critical user flows tested in production
  - [ ] API endpoints responding correctly
  - [ ] No obvious errors or issues
  - [ ] Performance within acceptable range

- [ ] **Monitoring**

  - [ ] Metrics being collected
  - [ ] No alerts firing
  - [ ] Resource usage within expected range
  - [ ] Error rates normal

- [ ] **Documentation**

  - [ ] Deployment notes recorded
  - [ ] Any issues encountered documented
  - [ ] Configuration changes documented
  - [ ] Version deployed recorded

## Post-Deployment (24-48 hours)

- [ ] **Stability Monitoring**

  - [ ] No unexpected restarts
  - [ ] Memory usage stable (no leaks)
  - [ ] CPU usage within expected range
  - [ ] No increase in error rates

- [ ] **Performance Monitoring**

  - [ ] Response times acceptable
  - [ ] Throughput meeting requirements
  - [ ] No performance degradation
  - [ ] Resource utilization optimal

- [ ] **Security Monitoring**

  - [ ] No security alerts
  - [ ] Access logs reviewed
  - [ ] No unauthorized access attempts
  - [ ] Network traffic patterns normal

- [ ] **User Feedback**

  - [ ] No user-reported issues
  - [ ] User experience satisfactory
  - [ ] Support tickets normal
  - [ ] Customer satisfaction maintained

## Rollback Procedure

If issues are detected, follow this rollback procedure:

1. **Assess Severity**

   - Determine if issue requires immediate rollback
   - Check if issue affects all users or subset
   - Evaluate impact on business operations

1. **Communicate**

   - Notify stakeholders of rollback decision
   - Update status page if applicable
   - Alert on-call team

1. **Execute Rollback**

   ```bash
   # Rollback to previous deployment
   kubectl rollout undo deployment/prod-devcontainer -n production

   # Or rollback to specific revision
   kubectl rollout undo deployment/prod-devcontainer -n production --to-revision=2

   # Verify rollback
   kubectl rollout status deployment/prod-devcontainer -n production
   ```

1. **Verify Rollback**

   - Confirm pods are running
   - Test critical functionality
   - Check metrics and logs
   - Verify error rates return to normal

1. **Post-Mortem**

   - Document what went wrong
   - Identify root cause
   - Plan remediation
   - Update checklist if needed

## Emergency Contacts

Document your emergency contacts:

- **On-Call Engineer**: [Name, Phone, Slack]
- **DevOps Lead**: [Name, Phone, Slack]
- **Manager/Director**: [Name, Phone, Slack]
- **Cloud Provider Support**: [Account Number, Support URL]

## Additional Resources

- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)
- [Production Readiness Review](https://gruntwork.io/devops-checklist/)
- [Container Build System Docs](../../docs/)

## Checklist Version

- **Version**: 1.0
- **Last Updated**: 2025-01-16
- **Next Review**: [Date]

______________________________________________________________________

## Sign-Off

- [ ] Deployment Engineer: **\*\*\*\***\_\_**\*\*\*\*** Date: \***\*\_\_\*\***
- [ ] DevOps Lead: **\*\*\*\***\_\_**\*\*\*\*** Date: \***\*\_\_\*\***
- [ ] Manager/Approver: **\*\*\*\***\_\_**\*\*\*\*** Date: \***\*\_\_\*\***
