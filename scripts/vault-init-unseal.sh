#!/usr/bin/env bash
set -euo pipefail

# Initializes Vault (once) and unseals it. On first run it writes the unseal
# keys + root token to .vault/init.json (gitignored, chmod 600) — these are the
# ONLY copy, so back them up somewhere safe. On later runs (e.g. after a WSL2 or
# pod restart) it reuses that file to unseal again. Never commits any secret.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VAULT_DIR="${REPO_ROOT}/.vault"
INIT_FILE="${VAULT_DIR}/init.json"

vstatus() {
  kubectl exec -n vault vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" \
    vault status -format=json 2>/dev/null || true
}
jq_field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"; }

echo "==> Checking Vault status"
INITIALIZED="$(vstatus | jq_field initialized)"

if [ "${INITIALIZED}" != "True" ] && [ "${INITIALIZED}" != "true" ]; then
  echo "==> Vault is uninitialized — running operator init (5 keys, threshold 3)"
  if [ -f "${INIT_FILE}" ]; then
    echo "ERROR: ${INIT_FILE} already exists but Vault reports uninitialized." >&2
    echo "       Refusing to overwrite existing keys. Investigate manually." >&2
    exit 1
  fi
  mkdir -p "${VAULT_DIR}"
  chmod 700 "${VAULT_DIR}"
  kubectl exec -n vault vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" \
    vault operator init -key-shares=5 -key-threshold=3 -format=json >"${INIT_FILE}"
  chmod 600 "${INIT_FILE}"
  echo "  init keys written to ${INIT_FILE} (gitignored) — BACK THIS UP"
else
  echo "  Vault already initialized"
fi

if [ ! -f "${INIT_FILE}" ]; then
  echo "ERROR: ${INIT_FILE} missing — cannot unseal (keys unavailable)." >&2
  exit 1
fi

SEALED="$(vstatus | jq_field sealed)"
if [ "${SEALED}" = "True" ] || [ "${SEALED}" = "true" ]; then
  echo "==> Unsealing (3 of 5 keys)"
  while IFS= read -r key; do
    kubectl exec -n vault vault-0 -- env VAULT_ADDR="http://127.0.0.1:8200" \
      vault operator unseal "${key}" >/dev/null
  done < <(python3 -c "import json; print('\n'.join(json.load(open('${INIT_FILE}'))['unseal_keys_b64'][:3]))")
  echo "  unsealed"
else
  echo "  Vault already unsealed"
fi

echo "==> Waiting for vault-0 to become Ready"
kubectl wait --for=condition=Ready pod/vault-0 -n vault --timeout=60s
echo "  Vault is unsealed and Ready"
