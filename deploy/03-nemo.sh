#!/usr/bin/env bash
# 03-nemo.sh — NeMo Retriever on the SAME microk8s cluster (added on top of the engines).
# Reuses the NeMo Retriever chart + values; the upstream k3s bootstrap is NOT used
# (Brev microk8s already provides the GPU runtime). Consumes env: NGC_API_KEY.
set -eu

# Guard here too (not just in bootstrap.sh) so running this step standalone fails fast:
# set -u does NOT catch a set-but-EMPTY var, and an empty key surfaces later as a confusing
# chart error ("ngcImagePullSecret.password required when create=true").
: "${NGC_API_KEY:?empty or unset — export your NGC Catalog key (nvapi-...) before running this step}"
# Shape check: a wrong-but-non-empty value (e.g. pasting the key's *description* from the NGC
# console) installs fine and only surfaces ~20 min later as 401 Unauthorized on the NIM pulls.
case "$NGC_API_KEY" in
  nvapi-*) : ;;
  *) echo "FATAL: NGC_API_KEY must start with 'nvapi-' (got ${#NGC_API_KEY} chars). Paste the KEY, not its description."; exit 1 ;;
esac

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"; MF="$ROOT/config/manifests"
NS=retriever; RELEASE=retriever
NEMO_REPO="${NEMO_REPO:-https://github.com/yiwzhao/NeMo-Retriever.git}"   # NeMo Retriever chart source (overridable)
NEMO_BRANCH="${NEMO_BRANCH:-brev-launchable}"
NEMO_DIR="${NEMO_DIR:-/tmp/nemo-retriever}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# --- GPU time-slicing so the 4 NIMs can schedule ------------------------------
# The GPU Operator namespace and ClusterPolicy name are DISCOVERED, not assumed — Brev's
# microk8s image uses `gpu-operator-resources`, not `gpu-operator`.
GPU_NS="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
          | awk '/nvidia-device-plugin/{print $1; exit}')"
[ -n "$GPU_NS" ] || { echo "FATAL: no nvidia-device-plugin pod found — is the GPU Operator installed?"; exit 1; }
CP="$(kubectl get clusterpolicy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
log "GPU Operator ns=$GPU_NS clusterpolicy=${CP:-<none>}"

GPU_BEFORE="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"
log "applying GPU time-slicing config (allocatable now: ${GPU_BEFORE:-?})"
kubectl -n "$GPU_NS" apply -f "$MF/gpu-timeslicing.yaml"

if [ -n "$CP" ]; then
  kubectl patch clusterpolicy "$CP" --type merge \
    -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
else
  # No ClusterPolicy (standalone device plugin): point it at the ConfigMap directly.
  kubectl -n "$GPU_NS" set env ds/nvidia-device-plugin-daemonset CONFIG_FILE=/config/any || \
    echo "  (no clusterpolicy and could not configure the standalone device plugin — check it manually)"
fi

# Expected units = physical GPUs x replicas. Comparing against EXPECTED (not "more than
# before") makes this idempotent — on a re-run where slicing is already applied it exits
# immediately instead of waiting out the whole loop.
PHYS="$(nvidia-smi -L | grep -c '^GPU')"
REPLICAS="$(awk '/replicas:/{print $2; exit}' "$MF/gpu-timeslicing.yaml")"
EXPECT=$(( PHYS * ${REPLICAS:-1} ))
log "waiting for allocatable nvidia.com/gpu to reach $EXPECT (${PHYS} GPUs x ${REPLICAS:-1})"
for i in $(seq 1 30); do
  NOW="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}')"
  [ -n "$NOW" ] && [ "${NOW:-0}" -ge "$EXPECT" ] && break
  sleep 10
done
echo "allocatable nvidia.com/gpu: ${NOW:-unknown} (expected $EXPECT)"

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
