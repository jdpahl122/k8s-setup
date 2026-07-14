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

echo "Wrote CA cert to ${OUT}"
echo ""
echo "Trust it so browsers stop warning:"
echo ""
echo "  Windows (run in an Administrator PowerShell, from this repo dir):"
echo "    Import-Certificate -FilePath (wslpath -w '${OUT}') \\"
echo "      -CertStoreLocation Cert:\\LocalMachine\\Root"
echo ""
echo "  Or double-click local-ca.crt in Explorer -> Install Certificate"
echo "    -> Local Machine -> 'Trusted Root Certification Authorities'."
echo ""
echo "  Firefox uses its own store: Settings -> Certificates -> Import,"
echo "  and check 'Trust this CA to identify websites'."
echo ""
echo "Restart the browser afterward. curl users: curl --cacert ${OUT} https://ollama.localtest.me"
