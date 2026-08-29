#!/usr/bin/env bash
# 06-precompute.sh — warm the CacheBlend cache for the ingested corpus.
#
# WHY: every FIRST-touch question is a cold store (blend match_probe hits=0), so an
# un-warmed benchmark measures pure store overhead and CacheBlend loses. This replays
# the dataset questions through the SAME retrieval + prompt assembly the compare UI
# uses (byte-aligned windows), against the CacheBlend arm only, with max_tokens=1 —
# prefill-only, so the blend server stores every context chunk's KV once.
#
# RUN AFTER: Quick Demo ingest has completed AND the Try-It UI (05) is running
# (questions are served by the UI at /api/dataset/questions). Idempotent — re-runs
# turn into cache hits. Non-fatal.
set -u

NS_R="${NS_R:-retriever}"; NS_W="${NS_W:-cacheblend-workload}"; RELEASE="${RELEASE:-retriever}"
UI="${UI:-http://localhost:8000}"
N="${N:-1000}"                       # max questions to warm (dataset has 299 in dev)
CONC="${CONC:-3}"                    # in-flight requests (engine max_num_seqs=4)
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

# port-forwards (reuse if already up from 05)
pgrep -f "port-forward.*${RELEASE}-nemo-retriever" >/dev/null || \
  nohup kubectl -n "$NS_R" port-forward "svc/${RELEASE}-nemo-retriever" 7670:7670 >/dev/null 2>&1 &
pgrep -f "port-forward svc/gptoss20b 8010" >/dev/null || \
  nohup kubectl -n "$NS_W" port-forward svc/gptoss20b 8010:8000 >/dev/null 2>&1 &
sleep 3

BLEND="$(kubectl -n "$NS_W" get pod -o name 2>/dev/null | grep cacheblend | head -1 | cut -d/ -f2)"
S0="$(kubectl -n "$NS_W" logs "$BLEND" 2>/dev/null | grep -c 'Stored .* tokens' || echo 0)"
T0=$(date +%s)

log "precompute: warming CacheBlend with dataset questions (max_tokens=1, prefill-only)"
UI="$UI" N="$N" CONC="$CONC" python3 - <<'PY'
import json, os, sys, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

UI   = os.environ["UI"]
N    = int(os.environ["N"])
CONC = int(os.environ["CONC"])

def get(url, timeout=60):
    with urllib.request.urlopen(url, timeout=timeout) as f:
        return json.load(f)

def post(url, body, timeout=300):
    r = urllib.request.Request(url, data=json.dumps(body).encode(),
                               headers={"content-type": "application/json"}, method="POST")
    with urllib.request.urlopen(r, timeout=timeout) as f:
        return json.load(f)

# 1. questions from the UI (same source the Benchmark tab uses)
try:
    qs = get(f"{UI}/api/dataset/questions?n={N}&mode=quick").get("questions", [])
except Exception as e:
    print(f"  FAIL: cannot fetch questions from the UI ({e}) — is 05-tryit-ui running?")
    sys.exit(0)
if not qs:
    print("  FAIL: 0 questions — has the Quick Demo dataset been ingested/downloaded?")
    sys.exit(0)
print(f"  {len(qs)} questions loaded")

# 2. EXACT replicas of inference.py's retrieve_context + prompt assembly
RAG_SYSTEM = ("You are a helpful assistant. Answer the user's question using only the provided context. "
              "Be concise and factual. If the context does not contain the answer, say so.")
TOP_K = 5

def retrieve(q):
    hits_raw = post("http://localhost:7670/v1/query",
                    {"query": q, "top_k": TOP_K * 4, "format": "hits"}, timeout=120)
    hits_raw = (hits_raw.get("results") or [{}])[0].get("hits", [])
    out, seen = [], set()
    for h in hits_raw:
        text = h.get("text") or (h.get("metadata", {}) or {}).get("content", "")
        key = " ".join(str(text).split())[:200]
        if not key or key in seen:
            continue
        seen.add(key)
        out.append(text)
        if len(out) >= TOP_K:
            break
    return out

done = fail = 0
def warm(q):
    global done, fail
    try:
        texts = retrieve(q)
        context = "\n\n---\n\n".join(t for t in texts if t)[:8192]
        post("http://localhost:8010/v1/chat/completions",
             {"model": "cacheblend",
              "messages": [{"role": "system", "content": RAG_SYSTEM},
                           {"role": "user", "content": f"Context:\n{context}\n\nQuestion: {q}"}],
              "max_tokens": 1, "temperature": 0})
        done += 1
    except Exception:
        fail += 1
    if (done + fail) % 25 == 0:
        print(f"  {done + fail}/{len(qs)} warmed ({fail} failed)")

with ThreadPoolExecutor(max_workers=CONC) as ex:
    list(ex.map(warm, qs))
print(f"  warm complete: {done} ok, {fail} failed of {len(qs)}")
PY

T1=$(date +%s)
S1="$(kubectl -n "$NS_W" logs "$BLEND" 2>/dev/null | grep -c 'Stored .* tokens' || echo 0)"
log "done in $((T1 - T0))s — $((S1 - S0)) new 'Stored' events on the blend server"
echo "  compare-page questions on this corpus should now blend on FIRST ask (watch match_probe hits > 0)"
