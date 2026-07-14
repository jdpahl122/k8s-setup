#!/usr/bin/env bash
set -euo pipefail

# Exports the local CA public certificate to ./local-ca.crt (gitignored) so you
# can trust it in Windows / your browser and get green-lock HTTPS for the
# *.localtest.me ingress hosts. Only the public cert is exported, never the key.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT="${REPO_ROOT}/local-ca.crt"

kubectl get secret local-ca-key-pair -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d >"${OUT}"

WIN_PATH="$(wslpath -w "${OUT}")"

echo "Wrote CA cert to ${OUT}"
echo ""
echo "Trust it so Chrome/Edge stop warning (CurrentUser store — NO admin needed)."
echo "Run this straight from WSL2 (interop calls Windows PowerShell):"
echo ""
echo "  powershell.exe -NoProfile -Command \\"
echo "    \"Import-Certificate -FilePath '${WIN_PATH}' -CertStoreLocation Cert:\\CurrentUser\\Root\""
echo ""
echo "Then FULLY quit and reopen the browser (close all windows)."
echo ""
echo "  Firefox uses its own store: Settings -> Privacy & Security -> Certificates"
echo "    -> View Certificates -> Import, tick 'Trust this CA to identify websites'."
echo ""
echo "  curl users: curl --cacert ${OUT} https://ollama.localtest.me"
echo ""
echo "  To undo later:"
echo "    powershell.exe -Command \"certutil -user -delstore Root k8s-setup-local-ca\""
