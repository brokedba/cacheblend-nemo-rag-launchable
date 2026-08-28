#!/usr/bin/env bash
# 05-tryit-ui.sh — launch the NeMo Retriever web UI in "Try It" mode against OUR stack.
#
# MANUAL step for now: NOT called by bootstrap.sh (commented there). Run it yourself
# on the box after the deploy is green:   bash ~/cnrl/deploy/05-tryit-ui.sh
#
# How it works — no changes to the upstream UI:
#   * app.py's _detect_existing() probes RETRIEVER_URL/v1/health; when it answers, the
#     UI marks the stack live and lands on the ingest + query playground (Try It).
#   * INFERENCE_MODE=host makes it trust our BASELINE/CACHEBLEND URLs verbatim instead
#     of spawning its own k8s port-forwards (which assume a k3s kubeconfig path).
#   * We pre-forward all three services on localhost, so its self-healing forward sees
#     a healthy endpoint and stays quiet.
# Upstream defaults we MUST override: engines on 8001/8002 (8001 is Headlamp on Brev),
# LLM_MODEL=meta-llama/..., KUBECONFIG=/etc/rancher/k3s/k3s.yaml.
set -eu

NS_R="${NS_R:-retriever}"; NS_W="${NS_W:-cacheblend-workload}"; RELEASE="${RELEASE:-retriever}"
NEMO_DIR="${NEMO_DIR:-/tmp/nemo-retriever}"
NEMO_REPO="${NEMO_REPO:-https://github.com/yiwzhao/NeMo-Retriever.git}"
NEMO_BRANCH="${NEMO_BRANCH:-brev-launchable}"
UI_PORT="${UI_PORT:-8000}"
VENV="${VENV:-$HOME/deploy-ui-venv}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# --- webui source (same clone 03-nemo.sh made; re-clone if the box was recycled) -----
[ -d "$NEMO_DIR/.git" ] || git clone --depth 1 -b "$NEMO_BRANCH" "$NEMO_REPO" "$NEMO_DIR"
WEBUI="$NEMO_DIR/deploy/brev/webui"
[ -f "$WEBUI/app.py" ] || { echo "FATAL: $WEBUI/app.py not found"; exit 1; }

# --- venv (mirrors upstream setup.sh) -------------------------------------------------
log "UI venv"
python3 -c "import ensurepip" >/dev/null 2>&1 || {
  sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip; }
[ -x "$VENV/bin/pip" ] || { rm -rf "$VENV"; python3 -m venv --system-site-packages "$VENV"; }
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet fastapi "uvicorn[standard]" requests huggingface_hub psutil

# --- port-forwards: retriever 7670, baseline 8011, cacheblend 8010 --------------------
# (8001/8002 upstream defaults are avoided: 8001 is Headlamp on the Brev image)
log "port-forwards (nohup, survive this shell)"
pgrep -f "port-forward.*${RELEASE}-nemo-retriever" >/dev/null || \
  nohup kubectl -n "$NS_R" port-forward "svc/${RELEASE}-nemo-retriever" 7670:7670 >/dev/null 2>&1 &
pgrep -f "port-forward.*gptoss20b-base" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/gptoss20b-base 8011:8000 >/dev/null 2>&1 &
pgrep -f "port-forward svc/gptoss20b 8010" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/gptoss20b 8010:8000 >/dev/null 2>&1 &
sleep 4
curl -sf http://localhost:7670/v1/health >/dev/null || echo "  WARN: retriever not answering on :7670 yet"

# --- launch the UI (foreground — Ctrl-C stops it; forwards keep running) --------------
export KUBECONFIG="$HOME/.kube/config"          # upstream default is the k3s path
export INFERENCE_MODE=host                       # trust the URLs below, no k8s forwards
export RETRIEVER_URL="http://localhost:7670"
export BASELINE_LLM_URL="http://localhost:8011"
export CACHEBLEND_LLM_URL="http://localhost:8010"
export LLM_MODEL="openai/gpt-oss-20b"            # upstream default is Llama-3.1-8B

log "Try-It UI on http://localhost:${UI_PORT}  (compare: /compare · benchmark: /benchmark)"
echo "  from your laptop:  ssh -L ${UI_PORT}:localhost:${UI_PORT} <box>   then open http://localhost:${UI_PORT}"
cd "$WEBUI"
exec "$VENV/bin/uvicorn" app:app --host 0.0.0.0 --port "$UI_PORT"
