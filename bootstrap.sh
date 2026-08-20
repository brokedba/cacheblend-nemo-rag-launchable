#!/usr/bin/env bash
# bootstrap.sh — converged RAG backend deploy: TMO CacheBlend engines + NeMo Retriever,
# on one microk8s cluster. Meant to be run by the NVIDIA-owned launchable after it
# `git clone`s this repo; the launchable injects the tokens as env vars (nothing baked here).
#
# Required env (set via the launchable's env-var field):
#   CB_PLUGIN_TOKEN   Docker Hub read token for tensormesh/cacheblend-plugin
#   TMO_GHCR_TOKEN    GHCR read:packages token for the chart
#   TMO_GHCR_USER     GHCR username
#   NGC_API_KEY       NVIDIA NGC key for the NeMo Retriever NIMs
set -eu

: "${CB_PLUGIN_TOKEN:?set via launchable env field}"
: "${TMO_GHCR_TOKEN:?set via launchable env field}"
: "${TMO_GHCR_USER:?set via launchable env field}"
: "${NGC_API_KEY:?set via launchable env field}"
export CB_PLUGIN_TOKEN TMO_GHCR_TOKEN TMO_GHCR_USER NGC_API_KEY

HERE="$(cd "$(dirname "$0")" && pwd)"
echo "=== RAG backend bootstrap $(date -u +%FT%TZ) ==="

bash "$HERE/deploy/01-cluster.sh"     # driver sanity + microk8s + cert-manager
bash "$HERE/deploy/02-engines.sh"     # TMO operator + CacheBlend + baseline (svc :8000 each)
bash "$HERE/deploy/03-nemo.sh"        # NeMo Retriever core (svc :7670)

cat <<EOF

=== BACKEND READY ===
  CacheBlend engine : svc/gptoss20b.cacheblend-workload:8000   -> CACHEBLEND_LLM_URL
  Baseline engine   : svc/gptoss20b-base.cacheblend-workload:8000 -> BASELINE_LLM_URL
  NeMo Retriever    : svc/retriever-nemo-retriever.retriever:7670 -> RETRIEVER_URL
The NVIDIA launchable's web UI (Try-It landing page + Secure Link) points at these.
EOF
