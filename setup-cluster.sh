#!/usr/bin/env bash
set -euo pipefail

echo "==> [1/6] Installing NVIDIA container toolkit"
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update -q
sudo apt-get install -y nvidia-container-toolkit

# Required for containerd (not Docker) — disable cgroup isolation
sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups=false --in-place

echo "==> [2/6] Installing k3s"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644" sh -

echo "==> [3/6] Waiting for k3s to be ready"
sudo systemctl enable k3s
until sudo k3s kubectl get nodes 2>/dev/null | grep -q "Ready"; do
  echo "  waiting for node to become Ready..."
  sleep 5
done
echo "  node is Ready"

echo "==> [4/6] NVIDIA containerd runtime (auto-detected by k3s)"
# NOTE: k3s v1.27+ automatically detects nvidia-container-runtime on PATH and
# generates a containerd config with an "nvidia" runtime + a RuntimeClass named
# "nvidia" — no custom config.toml.tmpl needed. Since the toolkit was installed
# in step 1 (before k3s in step 2), this already happened.
#
# Do NOT drop in a full-replacement config.toml.tmpl here: k3s's generated config
# also carries the CNI bin_dir/conf_dir settings, and replacing the whole file
# strips them, leaving the node stuck at "cni plugin not initialized".
# If you ever need to customize it, base the .tmpl on k3s's shipped template
# using the {{ template "base" . }} inheritance directive instead of replacing it.
echo "  skipping custom template — relying on k3s auto-detection"

echo "==> [5/6] Setting up kubeconfig"
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
sed -i 's/127.0.0.1/localhost/g' ~/.kube/config

echo "==> [6/6] Deploying NVIDIA device plugin"
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

# The plugin pod must run WITH the nvidia runtime to enumerate the GPU; k3s's
# default runtime is runc, so without this it logs "No devices found" and the
# node never advertises nvidia.com/gpu. Pin it to the auto-created RuntimeClass.
kubectl patch daemonset nvidia-device-plugin-daemonset -n kube-system --type merge \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"nvidia"}}}}'

echo "  waiting for GPU to be advertised..."
until kubectl get node -o jsonpath='{.items[0].status.allocatable}' 2>/dev/null | grep -q "nvidia.com/gpu"; do
  sleep 3
done
echo "  nvidia.com/gpu is now allocatable"

echo "==> Installing helm"
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo ""
echo "==> Done! Verifying cluster"
kubectl get nodes -o wide
kubectl get pods -n kube-system
echo ""
echo "GPU resource on node:"
kubectl get node -o jsonpath='{.items[0].status.allocatable}' | tr ',' '\n' | grep -i nvidia || echo "  (GPU may take a minute to appear — re-run: kubectl get node -o jsonpath='{.items[0].status.allocatable}')"
