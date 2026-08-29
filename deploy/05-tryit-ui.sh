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
# Reset the served copies to pristine so the patches below re-apply cleanly on every
# run (otherwise an older patch version blocks the newer one via the idempotency guard).
git -C "$NEMO_DIR" checkout -- deploy/brev/webui/index.html deploy/brev/webui/app.py 2>/dev/null || true

# Strip the "Run your own experiments" JupyterLab section from the SERVED COPY only
# (upstream untouched): its button is HARDCODED to the reference instance's dead
# Jupyter tunnel, not driven by NOTEBOOK_URL. Keeps the nbHint div (her JS uses it).
python3 - "$WEBUI/index.html" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2 = re.sub(r'<label[^>]*>4 · Run your own experiments</label>.*?</a>\s*</div>', '', s, flags=re.S)
if s2 != s:
    open(p, "w", encoding="utf-8").write(s2)
    print("  stripped hardcoded JupyterLab section from index.html")
else:
    print("  (JupyterLab section not found — already stripped or upstream changed)")

# Extend the Full Benchmark confirm: the full corpus far exceeds the CacheBlend L1,
# so it cannot showcase the cache — steer people to Quick Demo for that.
old = "this takes a long time. Continue?"
new = ("this takes a long time, and the corpus far exceeds the CacheBlend L1 cache, "
       "so it will NOT showcase CacheBlend (no precompute is run). "
       "Use Quick Demo for the cache comparison. Continue?")
if old in s2:
    open(p, "w", encoding="utf-8").write(s2.replace(old, new, 1))
    print("  extended the Full Benchmark confirm message")
PY

# Patch the SERVED COPY of app.py: after a dataset ingest completes (Quick Demo /
# Full Benchmark click), warm the CacheBlend cache with every dataset question
# (max_tokens=1, prefill-only) BEFORE reporting phase=done. Without this, every
# first-touch question is a cold store and CacheBlend benchmarks pure overhead.
# Progress streams into the UI's live ingest log. Idempotent; upstream untouched.
python3 - "$WEBUI/app.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "Precomputing CacheBlend KV cache" in s:
    print("  (precompute patch already applied)")
    raise SystemExit(0)

anchor = '''        with _ds_lock:
            _ds.update(phase="done", elapsed=int(time.monotonic() - t0))'''
warm = '''        # --- CacheBlend precompute (injected): warm the cache for every dataset question.
        # QUICK mode only: the full corpus far exceeds the CacheBlend L1, so a full-corpus
        # warm would evict itself while running (and take hours) — skip it there.
        if mode == "quick":
            _dlog("Precomputing CacheBlend KV cache (max_tokens=1, prefill-only)\\u2026")
            _qs = [q for _p, q, _a in records if q]
            _w_ok = _w_fail = 0
            for _q in _qs:
                try:
                    _hits, _ = inf.retrieve_context(_q, top_k=5)
                    _ctx = "\\n\\n---\\n\\n".join(h["text"] for h in _hits if h.get("text"))[:8192]
                    requests.post(
                        inf.PATHS["cacheblend"] + "/v1/chat/completions",
                        json={"model": "cacheblend",
                              "messages": [
                                  {"role": "system", "content": inf._RAG_SYSTEM},
                                  {"role": "user", "content": f"Context:\\n{_ctx}\\n\\nQuestion: {_q}"}],
                              "max_tokens": 1, "temperature": 0},
                        timeout=300)
                    _w_ok += 1
                except Exception as _exc:  # noqa: BLE001
                    _w_fail += 1
                if (_w_ok + _w_fail) % 25 == 0:
                    _dlog(f"  precomputed {_w_ok + _w_fail}/{len(_qs)} ({_w_fail} failed)")
                    with _ds_lock:
                        _ds.update(elapsed=int(time.monotonic() - t0))
            _dlog(f"Precompute done \\u2014 {_w_ok} warmed, {_w_fail} failed of {len(_qs)}")
        else:
            _dlog("Skipping CacheBlend precompute: full corpus exceeds the L1 cache \\u2014 use Quick Demo for cache comparisons.")
'''
if anchor not in s:
    print("  WARN: precompute anchor not found in app.py — upstream changed; patch NOT applied")
    raise SystemExit(0)
s = s.replace(anchor, warm + anchor, 1)

# Also warm after the 1-PDF / sample ingest (_ingest_files): one prefill-only request
# with the canonical demo question, so the first compare ask on the sample is warm too.
anchor2 = '''    total = sum((d["rows"] or 0) for d in docs_out)
    return {"job_id": jid, "documents": docs_out, "total_rows": total}'''
warm2 = '''    total = sum((d["rows"] or 0) for d in docs_out)
    # --- CacheBlend precompute (injected): warm the just-ingested sample (1 request)
    try:
        _q = "Which animal is jumping onto a laptop?"
        _hits, _ = inf.retrieve_context(_q, top_k=5)
        _ctx = "\\n\\n---\\n\\n".join(h["text"] for h in _hits if h.get("text"))[:8192]
        requests.post(
            inf.PATHS["cacheblend"] + "/v1/chat/completions",
            json={"model": "cacheblend",
                  "messages": [{"role": "system", "content": inf._RAG_SYSTEM},
                               {"role": "user", "content": f"Context:\\n{_ctx}\\n\\nQuestion: {_q}"}],
                  "max_tokens": 1, "temperature": 0},
            timeout=300)
    except Exception:  # noqa: BLE001
        pass
    return {"job_id": jid, "documents": docs_out, "total_rows": total}'''
if anchor2 in s:
    s = s.replace(anchor2, warm2, 1)
    print("  patched app.py: sample/1-PDF ingest also precomputes (1 request)")
else:
    print("  WARN: 1-PDF anchor not found — sample warm NOT applied")

open(p, "w", encoding="utf-8").write(s)
print("  patched app.py: dataset ingest now precomputes the CacheBlend cache before 'done'")
PY

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
