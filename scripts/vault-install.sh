#!/usr/bin/env bash
set -euo pipefail

# Installs HashiCorp Vault in standalone mode (file storage) into the vault ns.
# Idempotent: safe to re-run (helm upgrade --install). Does NOT initialize or
# unseal — run scripts/vault-init-unseal.sh next.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CHART_VERSION="0.34.0"

echo "==> Adding hashicorp helm repo"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

echo "==> Installing Vault (chart ${CHART_VERSION}, standalone/file storage)"
# No --wait: the vault-0 readiness probe stays failing until Vault is unsealed,
# so we only wait for the pod to reach Running, then hand off to init/unseal.
helm upgrade --install vault hashicorp/vault \
  --namespace vault --create-namespace \
  --version "${CHART_VERSION}" \
  -f "${REPO_ROOT}/apps/vault/values.yaml"

echo "==> Waiting for vault-0 pod to reach Running (it will be 0/1 until unsealed)"
until [ "$(kubectl get pod vault-0 -n vault -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do
  echo "  waiting for vault-0..."
  sleep 4
done

echo "  vault-0 is Running (sealed). Next: scripts/vault-init-unseal.sh"
