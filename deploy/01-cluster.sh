#!/usr/bin/env bash
# 01-cluster.sh — cluster readiness + cert-manager.
# On the 4x RTX PRO 6000 launchable the driver is already R580 (native Blackwell),
# so there is NO driver upgrade / reboot here (unlike the old bare cu13 script).
set -eu

log() { echo -e "\n\033[1;32m==> $*\033[0m"; }
die() { echo -e "\n\033[1;31mERROR: $*\033[0m" >&2; exit 1; }

# --- driver sanity (no upgrade; just fail fast on a too-old base image) -------
until nvidia-smi -L >/dev/null 2>&1; do echo "waiting for GPU..."; sleep 5; done
DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)
[ "${DRV:-0}" -ge 580 ] || die "driver ${DRV}.x < 580 — need an R580/CUDA-13 base image for the cu130 engine. (This launchable does not upgrade drivers.)"
log "driver $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) (CUDA 13) OK"
nvidia-smi -L

# --- k8s (microk8s provided by Brev single-node-k8s mode) ---------------------
until sudo microk8s status --wait-ready --timeout 30 >/dev/null 2>&1; do echo "waiting for microk8s..."; sleep 5; done
if ! kubectl get nodes >/dev/null 2>&1; then
  mkdir -p "$HOME/.kube" && sudo microk8s config > "$HOME/.kube/config" && chmod 600 "$HOME/.kube/config"
fi
until kubectl get nodes >/dev/null 2>&1; do echo "waiting for kubectl/api..."; sleep 5; done
kubectl get nodes

# --- cert-manager (webhook serving cert for the CacheBlend mutating webhook) --
log "cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl -n cert-manager rollout status deploy/$d --timeout=300s
done
