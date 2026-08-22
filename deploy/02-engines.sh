#!/usr/bin/env bash
# 02-engines.sh — TMO operator + CacheBlend engine + both vLLM arms.
# Ported from setup-tmo-cb-cu13.sh PHASES 4-7 (manifests pulled out to ../config/manifests/).
# Consumes env (from the launchable field): TENSORMESH_API_KEY.
#
# Both the private chart and the private cacheblend-plugin image come from the Tensormesh
# artifact proxy (artifacts.tensormesh.ai) — one revocable tm_... key, username is the
# literal "x-access-token". Public OSS images (lmcache/vllm-openai, lmcache-operator)
# still come from docker.io unauthenticated.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"; MF="$ROOT/config/manifests"
NS_OP=tensormesh-operator; NS_WL=cacheblend-workload
REGISTRY="${TENSORMESH_REGISTRY:-artifacts.tensormesh.ai}"
REG_USER=x-access-token
CHART_VERSION="${CHART_VERSION:-0.5.3}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# --- workload ns (privileged PSS: hostIPC) + private plugin pull secret --------
kubectl get ns "$NS_WL" >/dev/null 2>&1 || kubectl create ns "$NS_WL"
kubectl label ns "$NS_WL" pod-security.kubernetes.io/enforce=privileged --overwrite
kubectl -n "$NS_WL" delete secret cacheblend-plugin-pull --ignore-not-found >/dev/null 2>&1
kubectl -n "$NS_WL" create secret docker-registry cacheblend-plugin-pull \
  --docker-server="$REGISTRY" \
  --docker-username="$REG_USER" --docker-password="$TENSORMESH_API_KEY"

# --- TMO chart (CacheBlend on; engine+coordinator off) ------------------------
log "helm install tensormesh-operator ($CHART_VERSION) from $REGISTRY"
helm registry login "$REGISTRY" --username "$REG_USER" --password-stdin <<<"$TENSORMESH_API_KEY"
helm upgrade --install tensormesh-operator \
  "oci://$REGISTRY/tensormesh-production/charts/tensormesh-operator" \
  --version "$CHART_VERSION" -n "$NS_OP" --create-namespace \
  -f "$MF/tmo-cacheblend-values.yaml" --wait --timeout 15m

# --- gate on webhook caBundle + blend server BEFORE the producers -------------
kubectl -n "$NS_OP" rollout status deploy/tensormesh-operator --timeout=300s
log "waiting for webhook caBundle (cert-manager injection)"
until [ -n "$(kubectl get mutatingwebhookconfiguration tensormesh-operator-mutating-webhook \
      -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null)" ]; do sleep 3; done

log "waiting for blend server pod"
until kubectl -n "$NS_WL" get pod -o name 2>/dev/null | grep -q cacheblend; do sleep 5; done
BLEND=$(kubectl -n "$NS_WL" get pod -o name | grep cacheblend | head -1 || true)
kubectl -n "$NS_WL" wait --for=condition=Ready "$BLEND" --timeout=900s
# Blend server MUST be on the CUDA backend, not the CPU stub (that's the driver tell).
# The banner wording is VERSION-DEPENDENT — match any variant, and BOUND the wait so a
# future wording change degrades into a timeout instead of hanging forever (0.5.3 hung here):
#   <=0.5.2 : "Using backend: lmcache.c_ops"          (lmcache/__init__.py)
#   0.5.3   : "torch_device_type=cuda" / "CudaPinMemoryBackend" / "accelerator available: True"
#             (lmcache.v1.platform._device_detect) — the "Using backend" line is GONE
CUDA_OK='Using backend: lmcache\.c_ops|torch_device_type=cuda|CudaPinMemoryBackend|accelerator available: True'
CPU_BAD='StubCPUDevice|torch_device_type=cpu|accelerator available: False'
ok=0
for try in 1 2; do
  for i in $(seq 1 60); do          # 60 x 5s = 5 min per attempt, then recycle/fail
    L="$(kubectl -n "$NS_WL" logs "$BLEND" 2>/dev/null || true)"
    echo "$L" | grep -qE "$CUDA_OK" && { ok=1; break; }
    echo "$L" | grep -qE "$CPU_BAD" && break
    sleep 5
  done
  [ "$ok" = 1 ] && { log "blend server on the CUDA backend OK"; break; }
  [ "$try" = 2 ] && { echo "FATAL: blend server never reported a CUDA backend (CPU stub / driver?)"; exit 1; }
  log "blend server not on CUDA (attempt $try) — recycling pod"
  kubectl -n "$NS_WL" delete "$BLEND"; sleep 10
  BLEND=$(kubectl -n "$NS_WL" get pod -o name | grep cacheblend | head -1 || true)
  kubectl -n "$NS_WL" wait --for=condition=Ready "$BLEND" --timeout=600s
done

# --- CacheBlend producer (webhook-injected) + verify injection ----------------
log "applying CacheBlend arm"
kubectl apply -f "$MF/engine-cacheblend.yaml"
for i in 1 2 3 4 5; do
  sleep 15
  POD=$(kubectl -n "$NS_WL" get pod -l app=gptoss20b -o name 2>/dev/null | head -1 || true)
  [ -z "$POD" ] && { echo "no CacheBlend pod yet..."; continue; }
  [ "$(kubectl -n "$NS_WL" get "$POD" -o jsonpath='{.spec.hostIPC}')" = "true" ] && { log "webhook injection verified (hostIPC)"; break; }
  [ "$i" = 5 ] && { echo "FATAL: webhook never injected the CacheBlend pod"; exit 1; }
  echo "pod NOT injected (attempt $i) — scale 0->1 to re-admit"
  kubectl -n "$NS_WL" scale deploy/gptoss20b --replicas=0; sleep 10
  kubectl -n "$NS_WL" scale deploy/gptoss20b --replicas=1
done

# --- Baseline arm (vanilla + APC, own GPU) ------------------------------------
log "applying baseline arm"
kubectl apply -f "$MF/engine-baseline.yaml"

kubectl -n "$NS_WL" rollout status deploy/gptoss20b       --timeout=1800s
kubectl -n "$NS_WL" rollout status deploy/gptoss20b-base  --timeout=1800s
log "engines up — CacheBlend=svc/gptoss20b:8000  baseline=svc/gptoss20b-base:8000"

# --- warm-up: land one real query so the instance REGISTERS with lmcache -------
# lmcache reaps IDLE workers (`lmcache-mp-worker-reaper`, 30s interval), so a stack that
# deploys and then sits untouched can lose its registration (~1h observed). Doing it HERE,
# right after the engines come up, means the long NeMo phase never runs against a cold
# instance. The prompt MUST cross server.chunkSize (256) or the MP store never fires and
# the engine looks "up" with a cache path that was never exercised (~2800 tok ≈ 11 chunks).
log "warm-up: registering the engine with lmcache (the MP store must fire)"
python3 -c "
import json
print(json.dumps({'model':'openai/gpt-oss-20b',
                  'prompt':'The quick brown fox jumps over the lazy dog. ' * 300,
                  'max_tokens':8,'temperature':0}))" > /tmp/warm.json

kubectl -n "$NS_WL" port-forward svc/gptoss20b 8010:8000 >/dev/null 2>&1 & PF=$!
sleep 5
S0="$(kubectl -n "$NS_WL" logs "$BLEND" 2>/dev/null | grep -c 'Stored .* tokens' || true)"
if curl -sf http://localhost:8010/v1/models 2>/dev/null | grep -q gpt-oss-20b; then
  T="$(curl -sf -o /dev/null -w '%{time_total}' http://localhost:8010/v1/completions \
        -H 'content-type: application/json' -d @/tmp/warm.json 2>/dev/null || true)"
  [ -n "${T:-}" ] && echo "  served a ~2800-tok completion in ${T}s" \
                  || echo "  WARN: completion not served"
else
  echo "  WARN: model not registered on :8010"
fi
sleep 3
S1="$(kubectl -n "$NS_WL" logs "$BLEND" 2>/dev/null | grep -c 'Stored .* tokens' || true)"
if [ "${S1:-0}" -gt "${S0:-0}" ]; then
  echo "  MP store fired — $((S1 - S0)) new \"Stored\" events on the blend server"
else
  echo "  WARN: no new \"Stored\" events — cache path not exercised (connector down?)"
fi
kill "$PF" 2>/dev/null || true
