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
# Known-good answer for the default PDF/query — makes PASS mean "answered CORRECTLY"
# rather than merely "answered". Override together with SMOKE_QUERY/SMOKE_PDF.
EXPECT="${SMOKE_EXPECT:-cat}"
log() { echo -e "\n\033[1;32m==> $*\033[0m"; }

log "E2E smoke: ingest -> retrieve -> generate"
[ -f "$PDF" ] || { echo "  SKIP: no test PDF at $PDF"; exit 0; }
printf '  query      "%s"  (expect: %s)\n' "$Q" "$EXPECT"

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
Q="$Q" EXPECT="$EXPECT" python3 - <<'PY'
import json, os, time, urllib.request

def jpost(url, body, timeout=180):
    r = urllib.request.Request(url, data=json.dumps(body).encode(),
                               headers={'content-type': 'application/json'}, method='POST')
    with urllib.request.urlopen(r, timeout=timeout) as f:
        return json.load(f)

Q = os.environ['Q']
EXPECT = os.environ.get('EXPECT', '').strip().lower()
ok, wrong = [], []

try:
    hits = jpost("http://localhost:7670/v1/query", {"query": Q, "top_k": 3})["results"][0]["hits"]
except Exception as e:
    print(f"  FAIL  retrieve: {e}"); raise SystemExit(0)
if not hits:
    print("  FAIL  retrieve: 0 hits"); raise SystemExit(0)

snippet = " ".join(hits[0]["text"].split())[:64]
print(f'  retrieve   {len(hits)} hits, top d={hits[0].get("_distance", float("nan")):.3f} | "{snippet}..."')

ctx = "\n\n".join(h["text"] for h in hits)
# Ask for a terse answer: with --enforce-eager the engines decode at ~11 tok/s, so a
# chatty reply adds seconds and makes run-to-run timings look like cache differences.
msgs = [{"role": "system", "content": "Answer using only the provided context. Reply with as few words as possible."},
        {"role": "user",   "content": f"Context:\n{ctx}\n\nQuestion: {Q}"}]

# Availability check, not a perf or blend check — the UI needs BOTH urls to answer.
# Narrow it with e.g. SMOKE_ARMS="baseline" if you only want the simplest proof.
ARMS = {"baseline": 8011, "cacheblend": 8010}
want = os.environ.get("SMOKE_ARMS", "baseline cacheblend").split()
for name, port in [(a, ARMS[a]) for a in want if a in ARMS]:
    try:
        t0 = time.time()
        # temperature 0 + fixed seed: without these the same prompt returns prose one run
        # and JSON the next, and the timing difference is just answer length, not cache.
        # max_tokens MUST stay generous: gpt-oss is a REASONING model — it spends tokens in
        # `reasoning` first, and a tight budget leaves `content: null` (looks like a failure
        # on a perfectly healthy engine). 256 is the floor, not a tuning knob.
        a = jpost(f"http://localhost:{port}/v1/chat/completions",
                  {"model": "openai/gpt-oss-20b", "messages": msgs, "max_tokens": 256,
                   "temperature": 0, "seed": 42}, timeout=180)
        dt = time.time() - t0
        m = a["choices"][0]["message"]
        ans = " ".join((m.get("content") or "").split())
        if not ans and m.get("reasoning"):
            ans = "(empty content — answer stayed in `reasoning`; raise max_tokens)"
        # completion_tokens counts reasoning + content, which is why it varies more than
        # the visible answer length suggests.
        out = (a.get("usage") or {}).get("completion_tokens", "?")
        # Substring match, not equality: the model may answer as prose or as JSON,
        # so assert on content.
        hit = (not EXPECT) or (EXPECT in ans.lower())
        print(f'  generate   {name:<10} ({dt:.1f}s, {out} tok) {"OK   " if hit else "WRONG"} -> "{ans[:80]}"')
        (ok if hit else wrong).append(name)
    except Exception:
        print(f"  generate   {name:<10} SKIP (endpoint not serving)")

if ok:
    msg = f'PASS - correct answer ("{EXPECT}") from: ' + ", ".join(ok)
    if wrong:
        msg += f' | WRONG from: ' + ", ".join(wrong)
elif wrong:
    msg = 'FAIL - engines answered but none contained the expected answer: ' + ", ".join(wrong)
else:
    msg = 'FAIL - retrieval OK but no engine answered'
print(f'\n  RESULT     {msg}')
PY
