#!/usr/bin/env bash
# 03-nemo.sh — NeMo Retriever on the SAME microk8s cluster (added on top of the engines).
# Reuses the NeMo Retriever chart + values; the upstream k3s bootstrap is NOT used
# (Brev microk8s already provides the GPU runtime). Consumes env: NGC_API_KEY.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"; MF="$ROOT/config/manifests"
NS=retriever; RELEASE=retriever
NEMO_REPO="${NEMO_REPO:-https://github.com/yiwzhao/NeMo-Retriever.git}"   # NeMo Retriever chart source (overridable)
NEMO_BRANCH="${NEMO_BRANCH:-brev-launchable}"
NEMO_DIR="${NEMO_DIR:-/tmp/nemo-retriever}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# --- GPU time-slicing so the 4 NIMs fit on the retrieval GPU(s) ---------------
# NOTE (open item): node-wide slicing — see manifests/gpu-timeslicing.yaml header.
# For a clean engine A/B this must be scoped to the NeMo GPU only; TODO before benchmarking.
log "applying GPU time-slicing config"
kubectl apply -f "$MF/gpu-timeslicing.yaml"
# point the GPU-Operator device-plugin at it (microk8s ships the operator via Brev).
kubectl -n gpu-operator patch clusterpolicy/cluster-policy --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}' 2>/dev/null \
  || echo "  (could not patch clusterpolicy — verify the device-plugin picks up the time-slicing config)"
log "waiting for time-sliced nvidia.com/gpu units"
for i in $(seq 1 30); do
  kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' | grep -qE '[2-9]|[0-9]{2,}' && break
  sleep 10
done
kubectl get nodes -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}'; echo

# --- NIM Operator (reconciles NIMCache/NIMService CRDs) -----------------------
log "installing NVIDIA NIM Operator"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create ns nim-operator --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install nim-operator nvidia/k8s-nim-operator -n nim-operator --wait --timeout 10m
for i in $(seq 1 30); do
  kubectl get crd nimservices.apps.nvidia.com >/dev/null 2>&1 && kubectl get crd nimcaches.apps.nvidia.com >/dev/null 2>&1 && break
  sleep 5
done

# --- NeMo Retriever core chart (cloned from $NEMO_REPO at runtime) ------------
log "cloning NeMo Retriever chart ($NEMO_BRANCH)"
[ -d "$NEMO_DIR/.git" ] || git clone --depth 1 -b "$NEMO_BRANCH" "$NEMO_REPO" "$NEMO_DIR"

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f -
log "helm install NeMo Retriever (core RAG) into ns/$NS"
helm upgrade --install "$RELEASE" "$NEMO_DIR/nemo_retriever/helm" \
  -n "$NS" -f "$ROOT/config/nemo/values-brev-core.yaml" \
  --set ngcImagePullSecret.create=true --set ngcImagePullSecret.password="$NGC_API_KEY" \
  --set ngcApiSecret.create=true --set ngcApiSecret.password="$NGC_API_KEY" \
  --wait --timeout 30m || echo "  helm --wait timed out (NIM weight downloads are slow) — continuing to status"

kubectl get nimcache,nimservice,pods -n "$NS" || true
log "NeMo Retriever service = svc/${RELEASE}-nemo-retriever:7670 (ns/$NS)"
