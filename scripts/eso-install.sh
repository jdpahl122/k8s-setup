#!/usr/bin/env bash
set -euo pipefail

# Installs External Secrets Operator and the Vault auth ServiceAccount/RBAC.
# Idempotent. Run AFTER Vault is up; run scripts/vault-configure-eso.sh next to
# create the Vault policy/role and wire up the ClusterSecretStore.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_VERSION="2.7.0"

echo "==> Adding external-secrets helm repo"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null

echo "==> Installing External Secrets Operator (chart ${CHART_VERSION})"
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace \
  --version "${CHART_VERSION}" \
  --set installCRDs=true \
  --wait --timeout 5m

echo "==> Applying Vault auth ServiceAccount + RBAC"
kubectl apply -f "${REPO_ROOT}/apps/external-secrets/vault-auth.yaml"

echo "  ESO installed. Next: scripts/vault-configure-eso.sh"
