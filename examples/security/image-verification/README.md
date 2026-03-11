# Image Verification with Sigstore Policy Controller

Enforce container image signatures and attestations in Kubernetes using the
[Sigstore Policy Controller](https://docs.sigstore.dev/policy-controller/overview/).

## Prerequisites

- Kubernetes cluster (1.24+)
- Helm 3
- `kubectl` configured for your cluster

## Install Sigstore Policy Controller

```bash
helm repo add sigstore https://sigstore.github.io/helm-charts
helm repo update

helm install policy-controller sigstore/policy-controller \
  --namespace cosign-system \
  --create-namespace \
  --set webhook.failurePolicy=Fail
```

## Configure Image Policies

1. Edit `cluster-image-policy.yaml` — replace `YOUR_ORG/YOUR_REPO` with your
   GitHub organization and repository name.

1. Apply the policies:

```bash
kubectl apply -f cluster-image-policy.yaml
```

3. Label namespaces to enforce the policy:

```bash
kubectl label namespace default policy.sigstore.dev/include=true
```

## What Gets Enforced

| Check                | Description                                                  |
| -------------------- | ------------------------------------------------------------ |
| **Cosign signature** | Image must be signed by GitHub Actions via Fulcio OIDC       |
| **SLSA provenance**  | Image must have SLSA provenance attestation                  |
| **SBOM attestation** | Image must have CycloneDX SBOM attestation (optional policy) |

## Local Verification

Use the verification script to check images before deployment:

```bash
# Verify all signatures and attestations
./bin/verify-image-signature.sh ghcr.io/YOUR_ORG/YOUR_REPO:v1.0.0-minimal

# View full provenance chain
./bin/track-provenance.sh ghcr.io/YOUR_ORG/YOUR_REPO:v1.0.0-minimal
```

Or verify directly with `cosign`:

```bash
# Verify signature
cosign verify \
  --certificate-identity-regexp='^https://github.com/YOUR_ORG/YOUR_REPO' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  ghcr.io/YOUR_ORG/YOUR_REPO:v1.0.0-minimal

# Verify SLSA provenance
cosign verify-attestation \
  --certificate-identity-regexp='^https://github.com/YOUR_ORG/YOUR_REPO' \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --type=slsaprovenance \
  ghcr.io/YOUR_ORG/YOUR_REPO:v1.0.0-minimal
```

## Combining with OPA Gatekeeper

This project also provides OPA Gatekeeper policies in
`examples/security/opa-gatekeeper/` for trusted registry enforcement. The
Sigstore Policy Controller and OPA Gatekeeper complement each other:

- **OPA Gatekeeper**: Enforces which registries are allowed (allowlist)
- **Sigstore Policy Controller**: Enforces that images are signed and attested

## Troubleshooting

### Pod rejected by policy

Check the policy controller logs:

```bash
kubectl logs -n cosign-system -l app=policy-controller-webhook
```

### Image not signed

Signatures are only applied during tagged releases (`v*` tags). Images from
branch builds are not signed. Use release tags for production deployments.

### Attestation not found

Provenance and SBOM attestations are attached during the release workflow.
Verify the release completed successfully in GitHub Actions.
