#!/usr/bin/env bash
# 05-tryit-ui.sh — launch the Try-It web UI (ui/webui in this repo) against the stack.
#
# How it works:
#   * app.py's _detect_existing() probes RETRIEVER_URL/v1/health; when it answers, the
#     UI marks the stack live and lands on the ingest + query playground (Try It).
#   * INFERENCE_MODE=host makes it trust our BASELINE/CACHEBLEND URLs verbatim instead
#     of spawning its own k8s port-forwards.
#   * We pre-forward all three services (plus the lmcache server :8080, which feeds the
#     Blend% column) on localhost, so its self-healing forward sees healthy endpoints.
# Ports: engines on 8010/8011 (NOT the upstream 8001/8002 — 8001 is Headlamp on Brev).
set -eu

NS_R="${NS_R:-retriever}"; NS_W="${NS_W:-cacheblend-workload}"; RELEASE="${RELEASE:-retriever}"
UI_PORT="${UI_PORT:-8000}"
VENV="${VENV:-$HOME/deploy-ui-venv}"
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
WEBUI="$ROOT/ui/webui"
[ -f "$WEBUI/app.py" ] || { echo "FATAL: $WEBUI/app.py not found"; exit 1; }
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# --- venv --------------------------------------------------------------------------
log "UI venv"
python3 -c "import ensurepip" >/dev/null 2>&1 || {
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip; }
[ -x "$VENV/bin/pip" ] || { rm -rf "$VENV"; python3 -m venv --system-site-packages "$VENV"; }
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet fastapi "uvicorn[standard]" requests huggingface_hub psutil

# --- port-forwards: retriever 7670, baseline 8011, cacheblend 8010, lmcache 8080 -----
log "port-forwards (nohup, survive this shell)"
pgrep -f "port-forward.*${RELEASE}-nemo-retriever" >/dev/null || \
  nohup kubectl -n "$NS_R" port-forward "svc/${RELEASE}-nemo-retriever" 7670:7670 >/dev/null 2>&1 &
pgrep -f "port-forward.*gptoss20b-base" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/gptoss20b-base 8011:8000 >/dev/null 2>&1 &
pgrep -f "port-forward svc/gptoss20b 8010" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/gptoss20b 8010:8000 >/dev/null 2>&1 &
# blend server HTTP (:8080) — source of the real lmcache_mp_* counters for Blend%
pgrep -f "port-forward svc/tensormesh-cacheblend" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/tensormesh-cacheblend 8080:8080 >/dev/null 2>&1 &
sleep 4
curl -sf http://localhost:7670/v1/health >/dev/null || echo "  WARN: retriever not answering on :7670 yet"

# --- launch the UI (foreground — Ctrl-C stops it; forwards keep running) --------------
export KUBECONFIG="$HOME/.kube/config"
export INFERENCE_MODE=host                       # trust the URLs below, no k8s forwards
export RETRIEVER_URL="http://localhost:7670"
export BASELINE_LLM_URL="http://localhost:8011"
export CACHEBLEND_LLM_URL="http://localhost:8010"
export LLM_MODEL="openai/gpt-oss-20b"

log "Try-It UI on http://localhost:${UI_PORT}  (compare: /compare · benchmark: /benchmark)"
echo "  from your laptop:  ssh -L ${UI_PORT}:localhost:${UI_PORT} <box>   then open http://localhost:${UI_PORT}"
cd "$WEBUI"
if [ "${UI_BACKGROUND:-0}" = "1" ]; then
  # bootstrap mode: background the UI so the lifecycle script can finish and the
  # instance reports ready — the tryit-ui secure link (CTA) then points at a live page.
  pkill -f "uvicorn app:app" 2>/dev/null || true
  nohup setsid "$VENV/bin/uvicorn" app:app --host 0.0.0.0 --port "$UI_PORT" \
    > "$HOME/tryit-ui.log" 2>&1 &
  sleep 5
  curl -sf "http://localhost:${UI_PORT}/" >/dev/null \
    && log "UI backgrounded and answering (log: ~/tryit-ui.log)" \
    || echo "  WARN: UI not answering yet — check ~/tryit-ui.log"
else
  exec "$VENV/bin/uvicorn" app:app --host 0.0.0.0 --port "$UI_PORT"
fi
