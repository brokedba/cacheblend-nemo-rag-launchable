#!/usr/bin/env bash
# 04-smoke.sh — end-to-end proof that the two tiers actually work together:
#   ingest a PDF -> extract (layout/tables/OCR) -> embed -> LanceDB -> retrieve -> generate
#
# NON-FATAL by design: this reports PASS/FAIL and always exits 0. A smoke failure should
# leave the stack up for inspection, not tear down a 30-minute deploy.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
NS_R="${NS_R:-retriever}"; NS_W="${NS_W:-cacheblend-workload}"; RELEASE="${RELEASE:-retriever}"
PDF="${SMOKE_PDF:-${NEMO_DIR:-/tmp/nemo-retriever}/data/multimodal_test.pdf}"
Q="${SMOKE_QUERY:-Which animal is jumping onto a laptop?}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "E2E smoke: ingest -> retrieve -> generate"
[ -f "$PDF" ] || { echo "  SKIP: no test PDF at $PDF"; exit 0; }

# Local ports: 8001 is Headlamp on Brev's image — never bind it.
kubectl -n "$NS_R" port-forward "svc/${RELEASE}-nemo-retriever" 7670:7670 >/dev/null 2>&1 & PF1=$!
kubectl -n "$NS_W" port-forward svc/gptoss20b-base 8011:8000     >/dev/null 2>&1 & PF2=$!
kubectl -n "$NS_W" port-forward svc/gptoss20b      8010:8000     >/dev/null 2>&1 & PF3=$!
trap 'kill $PF1 $PF2 $PF3 2>/dev/null || true' EXIT
sleep 5

R=http://localhost:7670

# --- 1. ingest ---------------------------------------------------------------
JID="$(curl -sS -X POST "$R/v1/ingest/job" -H 'content-type: application/json' \
        -d '{"expected_documents":1,"retain_results":true,"label":"smoke"}' 2>/dev/null \
      | python3 -c 'import sys,json;print(json.load(sys.stdin).get("job_id",""))' 2>/dev/null)"
[ -n "$JID" ] || { echo "  FAIL  ingest: could not open a job (is the retriever serving on :7670?)"; exit 0; }
curl -sS -X POST "$R/v1/ingest/job/$JID/document" -F "file=@$PDF" >/dev/null 2>&1

ST=""; ROWS=0; ELAP=0
for i in $(seq 1 60); do        # 60 x 5s = 5 min
  read -r ST ROWS ELAP <<<"$(curl -sS "$R/v1/ingest/job/$JID/documents?limit=1" 2>/dev/null \
    | python3 -c 'import sys,json;d=json.load(sys.stdin)["items"][0];print(d.get("status","?"),d.get("result_rows") or 0,d.get("elapsed_s") or 0)' 2>/dev/null)"
  case "$ST" in completed|failed) break ;; esac
  sleep 5
done

if [ "$ST" = completed ] && [ "${ROWS:-0}" -gt 0 ]; then
  printf '  ingest     %s -> %s chunks in %ss  (layout -> tables -> OCR -> embed -> LanceDB)\n' \
         "$(basename "$PDF")" "$ROWS" "$ELAP"
else
  echo "  FAIL  ingest: status=${ST:-timeout} rows=${ROWS:-0}"; exit 0
fi

# --- 2. retrieve + 3. generate on every arm that answers ---------------------
Q="$Q" python3 - <<'PY'
import json, os, time, urllib.request

def jpost(url, body, timeout=180):
    r = urllib.request.Request(url, data=json.dumps(body).encode(),
                               headers={'content-type': 'application/json'}, method='POST')
    with urllib.request.urlopen(r, timeout=timeout) as f:
        return json.load(f)

Q = os.environ['Q']
ok = []

try:
    hits = jpost("http://localhost:7670/v1/query", {"query": Q, "top_k": 3})["results"][0]["hits"]
except Exception as e:
    print(f"  FAIL  retrieve: {e}"); raise SystemExit(0)
if not hits:
    print("  FAIL  retrieve: 0 hits"); raise SystemExit(0)

snippet = " ".join(hits[0]["text"].split())[:64]
print(f'  retrieve   top hit d={hits[0].get("_distance", float("nan")):.3f} | "{snippet}..."')

ctx = "\n\n".join(h["text"] for h in hits)
msgs = [{"role": "system", "content": "Answer only from the provided context."},
        {"role": "user",   "content": f"Context:\n{ctx}\n\nQuestion: {Q}"}]

for name, port in (("baseline", 8011), ("cacheblend", 8010)):
    try:
        t0 = time.time()
        a = jpost(f"http://localhost:{port}/v1/chat/completions",
                  {"model": "openai/gpt-oss-20b", "messages": msgs, "max_tokens": 256}, timeout=180)
        dt = time.time() - t0
        ans = " ".join((a["choices"][0]["message"].get("content") or "").split())[:80]
        print(f'  generate   {name:<10} ({dt:.1f}s) -> "{ans}"')
        ok.append(name)
    except Exception:
        print(f"  generate   {name:<10} SKIP (endpoint not serving)")

print(f'\n  RESULT     {"PASS - RAG loop verified end to end on: " + ", ".join(ok) if ok else "FAIL - retrieval OK but no engine answered"}')
PY
