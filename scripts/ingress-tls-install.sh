#!/usr/bin/env bash
set -euo pipefail

# Installs cert-manager + ingress-nginx and wires up local TLS ingress for the
# Ollama and Vault services. Idempotent (helm upgrade --install / kubectl apply).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CERT_MANAGER_VERSION="v1.21.0"
INGRESS_NGINX_VERSION="4.15.1"

echo "==> Adding helm repos"
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update jetstack ingress-nginx >/dev/null

echo "==> Installing cert-manager (${CERT_MANAGER_VERSION})"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  -f "${REPO_ROOT}/apps/cert-manager/values.yaml" \
  --wait --timeout 5m

echo "==> Creating local CA issuer chain"
kubectl apply -f "${REPO_ROOT}/apps/cert-manager/local-ca.yaml"
echo "  waiting for the local CA certificate to be issued"
kubectl wait --for=condition=Ready certificate/local-ca -n cert-manager --timeout=90s

echo "==> Installing ingress-nginx (${INGRESS_NGINX_VERSION}, hostPort 80/443)"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --version "${INGRESS_NGINX_VERSION}" \
  -f "${REPO_ROOT}/apps/ingress-nginx/values.yaml" \
  --wait --timeout 5m

echo "==> Applying ingresses (Ollama + Vault)"
kubectl apply -k "${REPO_ROOT}/apps/ollama"
kubectl apply -f "${REPO_ROOT}/apps/vault/ingress.yaml"

echo "==> Waiting for ingress TLS certs to be issued"
kubectl wait --for=condition=Ready certificate/ollama-tls -n ollama --timeout=120s
kubectl wait --for=condition=Ready certificate/vault-tls -n vault --timeout=120s

echo ""
echo "==> Done. Endpoints (once you trust the CA — see scripts/export-ca-cert.sh):"
echo "     https://ollama.localtest.me"
echo "     https://vault.localtest.me"
