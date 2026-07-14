#!/usr/bin/env bash
set -euo pipefail

# Configures Vault for External Secrets Operator, then applies the
# ClusterSecretStore + demo ExternalSecret and verifies the sync.
# Idempotent. Requires: Vault unsealed, ESO installed (eso-install.sh),
# and .vault/init.json present (for the root token).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INIT_FILE="${REPO_ROOT}/.vault/init.json"

if [ ! -f "${INIT_FILE}" ]; then
  echo "ERROR: ${INIT_FILE} missing — run scripts/vault-init-unseal.sh first." >&2
  exit 1
fi
ROOT_TOKEN="$(python3 -c "import json; print(json.load(open('${INIT_FILE}'))['root_token'])")"

# Run a vault CLI command inside vault-0, authenticated as root.
vex() {
  kubectl exec -n vault vault-0 -- \
    env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" "$@"
}

echo "==> Enabling KV v2 secrets engine at secret/"
vex vault secrets enable -path=secret kv-v2 2>/dev/null || echo "  (already enabled)"

echo "==> Enabling kubernetes auth method"
vex vault auth enable kubernetes 2>/dev/null || echo "  (already enabled)"

echo "==> Configuring kubernetes auth (uses vault-0's own SA token as reviewer)"
vex vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token

echo "==> Writing eso-read policy"
kubectl exec -i -n vault vault-0 -- \
  env VAULT_ADDR="http://127.0.0.1:8200" VAULT_TOKEN="${ROOT_TOKEN}" \
  vault policy write eso-read - <<'EOF'
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["read", "list"]
}
EOF

echo "==> Creating kubernetes auth role 'external-secrets'"
vex vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names="vault-eso-auth" \
  bound_service_account_namespaces="external-secrets" \
  policies="eso-read" \
  ttl="1h"

echo "==> Seeding demo secret at secret/demo (for the example ExternalSecret)"
vex vault kv put secret/demo username="demo" password="s3cr3t"

echo "==> Applying ClusterSecretStore + demo ExternalSecret"
kubectl apply -f "${REPO_ROOT}/apps/external-secrets/cluster-secret-store.yaml"
kubectl apply -f "${REPO_ROOT}/apps/external-secrets/example-externalsecret.yaml"

echo "==> Waiting for the demo secret to sync"
kubectl wait --for=condition=Ready externalsecret/demo-credentials -n default --timeout=90s
echo "  synced. k8s Secret default/demo-credentials now holds the Vault values."
