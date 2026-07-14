# k8s-setup

Local Kubernetes (k3s) cluster on WSL2 with NVIDIA GPU support, plus workloads
deployed on top of it.

- **Cluster:** k3s running directly in WSL2 (systemd), single node
- **GPU:** NVIDIA RTX 2070 (8 GB), exposed as `nvidia.com/gpu`
- **Node:** `officedesktop`

## Cluster setup

`setup-cluster.sh` bootstraps the whole cluster. Run it once on a fresh WSL2
machine:

```bash
./setup-cluster.sh
```

It performs, in order:

1. Installs the **NVIDIA container toolkit** (before k3s, so k3s auto-detects it)
2. Installs **k3s** (traefik and servicelb disabled)
3. Waits for the node to become `Ready`
4. Relies on k3s auto-detection of `nvidia-container-runtime` (creates the
   `nvidia` RuntimeClass automatically — no custom containerd template)
5. Writes kubeconfig to `~/.kube/config`
6. Deploys the **NVIDIA device plugin** (pinned to `runtimeClassName: nvidia`)
   and waits for `nvidia.com/gpu` to become allocatable, then installs Helm

Verify the GPU is advertised:

```bash
kubectl get node -o jsonpath='{.items[0].status.allocatable}' | tr ',' '\n' | grep nvidia
# "nvidia.com/gpu":"1"
```

### GPU workload requirements

Any pod that needs the GPU on this cluster **must** set both:

- `runtimeClassName: nvidia` (the default runtime is `runc`, which can't see the GPU)
- `resources.limits."nvidia.com/gpu": 1`

## Workloads

### Ollama (GPU LLM inference)

Deployed as a Kustomize app in `apps/ollama/`:

| File | Purpose |
|------|---------|
| `namespace.yaml` | `ollama` namespace |
| `pvc.yaml` | 50Gi `local-path` PVC for model weights (`/root/.ollama`) |
| `deployment.yaml` | Ollama server, pinned to the `nvidia` RuntimeClass + 1 GPU |
| `service.yaml` | ClusterIP `ollama:11434` |

Deploy / update:

```bash
kubectl apply -k apps/ollama
```

Notes on the single-GPU sizing:

- `replicas: 1` with a `Recreate` rollout strategy — there is only one GPU, so a
  rolling update would deadlock (the new pod can't claim a device the old pod
  still holds). `Recreate` releases the GPU first.
- `OLLAMA_MAX_LOADED_MODELS=1` and `OLLAMA_KEEP_ALIVE=1h` — 8 GB of VRAM fits one
  small/quantized model at a time; keeping it resident avoids reloading weights
  on every request.

#### Access

**From the WSL2 host** (port-forward the service):

```bash
kubectl port-forward -n ollama svc/ollama 11434:11434
```

Then hit the API on `localhost:11434`:

```bash
# Generate a completion
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5:0.5b","prompt":"hello","stream":false}'

# List installed models
curl http://localhost:11434/api/tags
```

**In-cluster**, other workloads reach it at:

```
http://ollama.ollama.svc.cluster.local:11434
```

#### Managing models

Pull models into the pod (they persist on the PVC). Mind the 8 GB VRAM budget —
good fits: `qwen2.5:0.5b`, `llama3.2:3b`, `qwen2.5:3b`, `phi3:mini`.

```bash
# Pull a model
kubectl exec -n ollama deploy/ollama -- ollama pull llama3.2:3b

# List models and their GPU/CPU placement
kubectl exec -n ollama deploy/ollama -- ollama list
kubectl exec -n ollama deploy/ollama -- ollama ps   # PROCESSOR column shows "100% GPU"

# Interactive run
kubectl exec -it -n ollama deploy/ollama -- ollama run llama3.2:3b
```

#### Verify GPU usage

```bash
# GPU is visible inside the pod
kubectl exec -n ollama deploy/ollama -- nvidia-smi

# A loaded model should report "100% GPU" placement
kubectl exec -n ollama deploy/ollama -- ollama ps
```

### Secrets: Vault + External Secrets Operator

Secret storage is **HashiCorp Vault** (standalone, file storage), and workloads
consume secrets via the **External Secrets Operator (ESO)** with Vault as the
backend. No secret values are ever written into manifests — manifests reference
only Vault *paths*, and ESO authenticates to Vault with the **kubernetes auth
method** (short-lived bound ServiceAccount tokens, no static token anywhere).

Files:

| File | Purpose |
|------|---------|
| `apps/vault/values.yaml` | Helm values for Vault (standalone, file storage, PVC) |
| `apps/external-secrets/vault-auth.yaml` | Auth ServiceAccount + RBAC for ESO→Vault |
| `apps/external-secrets/cluster-secret-store.yaml` | `ClusterSecretStore` → Vault (paths only, no values) |
| `apps/external-secrets/example-externalsecret.yaml` | Demo: sync `secret/demo` → k8s Secret |
| `scripts/vault-install.sh` | `helm install` Vault |
| `scripts/vault-init-unseal.sh` | Init + unseal (also re-run to unseal after a restart) |
| `scripts/eso-install.sh` | `helm install` ESO + apply auth SA/RBAC |
| `scripts/vault-configure-eso.sh` | Enable KV/auth, write policy+role, wire the store |

#### First-time setup

Run in order:

```bash
./scripts/vault-install.sh        # 1. install Vault (comes up sealed)
./scripts/vault-init-unseal.sh    # 2. init + unseal
./scripts/eso-install.sh          # 3. install ESO + auth SA/RBAC
./scripts/vault-configure-eso.sh  # 4. KV engine, k8s auth, policy/role, ClusterSecretStore
```

> **⚠️ Unseal keys + root token** are written to `.vault/init.json` (chmod 600,
> **gitignored**). This is the only copy — back it up somewhere safe. Losing it
> means losing access to Vault; committing it defeats the entire point.

#### After a restart (WSL2 reboot / pod restart)

Vault comes back **sealed** and must be unsealed manually — this is expected for
a standalone server. Just re-run:

```bash
./scripts/vault-init-unseal.sh    # detects it's already initialized, only unseals
```

#### Using it — store a secret, consume it in a workload

1. **Write a secret to Vault** (nothing goes into git):

   ```bash
   ROOT_TOKEN=$(python3 -c "import json;print(json.load(open('.vault/init.json'))['root_token'])")
   kubectl exec -n vault vault-0 -- \
     env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" \
     vault kv put secret/myapp api_key=abc123 db_password=hunter2
   ```

2. **Create an `ExternalSecret`** referencing the path (see
   `apps/external-secrets/example-externalsecret.yaml` as a template). ESO writes
   a native k8s `Secret` your pods mount as env vars or files:

   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: myapp-secrets
     namespace: default
   spec:
     refreshInterval: "1m"
     secretStoreRef:
       kind: ClusterSecretStore
       name: vault-backend
     target:
       name: myapp-secrets
       creationPolicy: Owner
     dataFrom:
       - extract:
           key: myapp          # pulls every key/value under secret/myapp
   ```

Updates in Vault propagate to the k8s Secret within `refreshInterval` (verified:
rotating a Vault value re-syncs automatically).

#### Vault UI

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# open http://localhost:8200 — log in with the root token from .vault/init.json
```

#### Production differences (this is a local mirror)

- **Auto-unseal**: production uses AWS KMS auto-unseal (via IRSA) instead of
  manual unseal; wire `seal "awskms"` into the server config.
- **TLS**: `global.tlsDisable` is `true` here for local convenience — enable TLS
  (cert-manager) in production.
- **HA**: production runs 3+ Raft nodes rather than a single standalone server.

### Ingress + TLS (local HTTPS access)

Services are reachable over HTTPS at `*.localtest.me` hostnames (that domain
resolves to `127.0.0.1` via public DNS, so **no hosts-file editing is needed**):

| URL | Backend |
|-----|---------|
| `https://ollama.localtest.me` | Ollama API (`ollama:11434`) |
| `https://vault.localtest.me` | Vault UI/API (`vault:8200`) |

Stack:

- **ingress-nginx** — runs with **`hostNetwork: true`** and binds ports 80/443
  (servicelb is disabled, so a LoadBalancer Service can't get an IP). `hostNetwork`
  is required on NAT-mode WSL2: plain `hostPort` only creates iptables DNAT rules
  (no listening socket), and WSL2's localhost→Windows forwarding relays *real
  listening sockets* only — with `hostPort` alone the Windows browser gets
  `ERR_CONNECTION_REFUSED` even though it works inside WSL2. `hostNetwork` makes
  nginx bind real `0.0.0.0:80/443` sockets, which WSL2 forwards to the host.
- **cert-manager** — a local self-signed **CA ClusterIssuer** (`local-ca`) issues
  a TLS cert per ingress host. Trust the CA once and every `*.localtest.me` cert
  is trusted.

Files:

| File | Purpose |
|------|---------|
| `apps/cert-manager/values.yaml` | Helm values for cert-manager |
| `apps/cert-manager/local-ca.yaml` | self-signed → CA cert → `local-ca` ClusterIssuer |
| `apps/ingress-nginx/values.yaml` | Helm values (hostPort 80/443, default class) |
| `apps/ollama/ingress.yaml` | Ollama Ingress + TLS (streaming-friendly timeouts) |
| `apps/vault/ingress.yaml` | Vault Ingress + TLS |
| `scripts/ingress-tls-install.sh` | installs cert-manager + ingress-nginx + ingresses |
| `scripts/export-ca-cert.sh` | exports the CA cert + prints trust instructions |

#### Setup

```bash
./scripts/ingress-tls-install.sh   # cert-manager, ingress-nginx, ingresses, certs
./scripts/export-ca-cert.sh        # -> ./local-ca.crt + how to trust it
```

Until the CA is trusted, browsers show a warning (the cert is valid, just signed
by an untrusted local CA). `curl` works immediately with `--cacert local-ca.crt`.

#### Troubleshooting: `ERR_CONNECTION_REFUSED` from the Windows browser

If it works inside WSL2 (`curl --cacert local-ca.crt https://ollama.localtest.me`)
but the Windows browser refuses:

1. Confirm the controller is listening on real sockets (not just iptables):
   ```bash
   ss -tlnp | grep -E ':(80|443)\s'   # expect 0.0.0.0:80 and 0.0.0.0:443
   ```
   If empty, the controller isn't running with `hostNetwork: true` — re-apply
   `apps/ingress-nginx/values.yaml`.
2. If sockets exist but Windows still refuses, WSL2's localhost forwarding may be
   stale. From a Windows terminal: `wsl --shutdown`, then restart WSL and re-run
   `./scripts/vault-init-unseal.sh` (Vault comes back sealed after a restart).

#### Trusting the CA

`export-ca-cert.sh` writes `./local-ca.crt` (gitignored) and prints the exact
commands. Summary:

- **Windows / Chrome / Edge** (Admin PowerShell): import `local-ca.crt` into
  `LocalMachine\Root`, or double-click → Install → Local Machine → *Trusted Root
  Certification Authorities*.
- **Firefox**: Settings → Certificates → Import, tick *Trust this CA to identify
  websites*.

Restart the browser afterward.

#### Adding another app

1. Add an `Ingress` (copy `apps/ollama/ingress.yaml`) with a
   `cert-manager.io/cluster-issuer: local-ca` annotation, `ingressClassName:
   nginx`, and a `tls` block for `myapp.localtest.me`.
2. `kubectl apply` it — cert-manager auto-issues the cert from the local CA; no
   hosts-file change needed.
