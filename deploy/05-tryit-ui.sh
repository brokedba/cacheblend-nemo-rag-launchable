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
git -C "$NEMO_DIR" checkout -- deploy/brev/webui/index.html deploy/brev/webui/app.py deploy/brev/webui/inference.py 2>/dev/null || true

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

# Patch the SERVED COPY of inference.py — fixes the metric columns in BOTH the compare
# tab and the inference benchmark (the benchmark consumes rag_stream()'s metrics event):
#   * Blend %   : real counters live on the lmcache server (:8080 lmcache_mp_l1_*);
#                 vLLM's external_prefix_cache_hits_total NEVER increments under
#                 CBKVConnector. New value = per-request read/(read+write) chunk delta.
#   * APC hit % : per-request delta instead of lifetime cumulative ratio (precompute
#                 traffic dilutes one arm's lifetime number).
#   * TTFT      : first delta of ANY kind — gpt-oss streams `reasoning` deltas before
#                 `content`, so first-content TTFT measured verbosity, not prefill.
# Payload keys are unchanged, so compare.html and the benchmark need no edits.
python3 - "$WEBUI/inference.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "_kv_counters" in s:
    print("  (inference.py metric patch already applied)")
    raise SystemExit(0)
ok = True

# A) raw-counter helper (vLLM APC counters + lmcache L1 chunk counters)
a = "def get_vllm_metrics(base_url: str) -> dict:"
helper = '''LMCACHE_METRICS_URL = os.environ.get("LMCACHE_METRICS_URL", "http://localhost:8080/metrics")


def _kv_counters(base_url: str) -> dict:
    """(injected) Raw cumulative counters, scraped before/after a request for deltas."""
    out = {"apc_q": 0.0, "apc_h": 0.0, "l1_r": 0.0, "l1_w": 0.0}
    try:
        for line in requests.get(f"{base_url}/metrics", timeout=5).text.splitlines():
            if line.startswith("vllm:prefix_cache_queries_total"):
                out["apc_q"] = float(line.split()[-1])
            elif line.startswith("vllm:prefix_cache_hits_total"):
                out["apc_h"] = float(line.split()[-1])
    except Exception:  # noqa: BLE001
        pass
    if base_url == CACHEBLEND_LLM_URL:
        try:
            for line in requests.get(LMCACHE_METRICS_URL, timeout=5).text.splitlines():
                if line.startswith("lmcache_mp_l1_read_chunks_total"):
                    out["l1_r"] = float(line.split()[-1])
                elif line.startswith("lmcache_mp_l1_write_chunks_total"):
                    out["l1_w"] = float(line.split()[-1])
        except Exception:  # noqa: BLE001
            pass
    return out


'''
if a in s:
    s = s.replace(a, helper + a, 1)
else:
    ok = False; print("  WARN: helper anchor missing")

# B) capture counters just before generation starts
b = "    # 2. Streaming generation"
if b in s:
    s = s.replace(b, "    _kv0 = _kv_counters(llm_url)\n\n" + b, 1)
else:
    ok = False; print("  WARN: pre-capture anchor missing")

# C) TTFT on the first delta of any kind (reasoning included)
c = '''                    try:
                        delta = json.loads(data)["choices"][0]["delta"].get("content", "")
                    except Exception:  # noqa: BLE001
                        continue
                    if delta:
                        if ttft_ms is None:
                            ttft_ms = (time.time() - t_llm_start) * 1000
                        token_count += 1'''
c_new = '''                    try:
                        _d = json.loads(data)["choices"][0]["delta"]
                        delta = _d.get("content") or ""
                    except Exception:  # noqa: BLE001
                        continue
                    if ttft_ms is None and (delta or _d.get("reasoning") or _d.get("reasoning_content")):
                        ttft_ms = (time.time() - t_llm_start) * 1000
                    if delta:
                        token_count += 1'''
if c in s:
    s = s.replace(c, c_new, 1)
else:
    ok = False; print("  WARN: TTFT anchor missing")

# D) overwrite the cumulative ratios with per-request deltas (same payload keys)
d = "    vllm_metrics = get_vllm_metrics(llm_url)"
d_new = '''    vllm_metrics = get_vllm_metrics(llm_url)
    # (injected) per-request deltas — lifetime ratios mislead across arms
    try:
        _kv1 = _kv_counters(llm_url)
        _dq = _kv1["apc_q"] - _kv0["apc_q"]
        _dh = max(_kv1["apc_h"] - _kv0["apc_h"], 0.0)
        if _dq > 0:
            vllm_metrics["vllm:prefix_cache_hit_rate"] = round(_dh / _dq, 4)
        _dr = max(_kv1["l1_r"] - _kv0["l1_r"], 0.0)
        _dw = max(_kv1["l1_w"] - _kv0["l1_w"], 0.0)
        if (_dr + _dw) > 0:
            vllm_metrics["lmcache:blend_ratio"] = round(_dr / (_dr + _dw), 4)
            vllm_metrics["lmcache:hit_ratio"] = vllm_metrics["lmcache:blend_ratio"]
    except Exception:  # noqa: BLE001
        pass'''
if d in s:
    s = s.replace(d, d_new, 1)
else:
    ok = False; print("  WARN: delta anchor missing")

open(p, "w", encoding="utf-8").write(s)
print("  patched inference.py: Blend% from lmcache :8080 deltas, APC% per-request, reasoning-aware TTFT"
      + ("" if ok else " (PARTIAL — see warnings)"))
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
# blend server HTTP (:8080) — source of the real lmcache_mp_* counters for Blend%
pgrep -f "port-forward svc/tensormesh-cacheblend" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/tensormesh-cacheblend 8080:8080 >/dev/null 2>&1 &
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
