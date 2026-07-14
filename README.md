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
