# Validation

Cold-boot reference run, what it validates, and the failure modes the scripts handle.

---

## 📋 Reference run

Fresh 4× RTX PRO 6000 node, empty caches, `0.5.3` tuple. **~31 min end to end**, ~21 of it first-run NIM weight download.

| Phase | Duration | Ends with |
| :--- | :--- | :--- |
| `01-cluster` | ~2 min | cert-manager rolled out |
| `02-engines` | ~9 min | both engines serving, MP store fired |
| `03-nemo` | ~20 min | 4 NIMServices Ready, retriever healthy |
| `04-smoke` | ~1 min | correct answer from both arms |

---

## ✅ What a passing run proves

| Check | Evidence in the log |
| :--- | :--- |
| Blend server on CUDA | `blend server on the CUDA backend OK` |
| GPU Operator discovered | `ns=gpu-operator-resources clusterpolicy=cluster-policy` |
| Slicing applied | `allocatable nvidia.com/gpu: 16 (expected 16)` |
| Plugin injected | `webhook injection verified (hostIPC)` |
| Engine registered, cache used | `served a ~2800-tok completion` → `MP store fired` |
| NIMs ready | `all NIMServices Ready` |
| Retriever serving | `retriever healthy: {"status":"ok","mode":"standalone"}` |
| RAG loop correct | `PASS - correct answer ("cat") from: baseline, cacheblend` |

> ⚠️ **Don't read the generate times as a benchmark.** The smoke prompt is only ~363 tokens, so CacheBlend has almost nothing to reuse — the timings mostly reflect how long each answer happened to be. Which arm looks faster has flipped between runs. Real numbers need a large corpus and the LDP benchmark harness.

---

## 🪤 Failure modes handled

All hit on real deploys. The silent ones are the dangerous ones.

| Symptom | Cause | Handled by |
| :--- | :--- | :--- |
| Hangs after blend server Ready, no error | `0.5.3` dropped the `Using backend: lmcache.c_ops` line | `02` matches several banner variants, bounded wait |
| `namespaces "gpu-operator" not found` | Brev k8s uses `gpu-operator-resources` | `03` discovers ns + ClusterPolicy at runtime |
| `ngcImagePullSecret.password required` | `NGC_API_KEY` set but **empty** (`set -u` misses that) | `03` guards non-empty + `nvapi-` prefix |
| NIM weights `402 Payment Required` | Account not in the free NVIDIA Developer Program | Enrol, then **regenerate** the key |
| Plugin `failed to resolve image ... not found` | Tag doesn't exist | Pin a published tag |
| Plugin `httpReadSeeker: failed open: content ... not found` | **Dangling tag** — digest resolves, manifest content missing | Registry-side; report it, pin another tag |
| Slicing step idles ~5 min per re-run | Waited for "more than before", unsatisfiable once applied | `03` compares to `GPUs × replicas` |
| NIM pods `Pending` | 4 NIMs each want a whole GPU; engines hold theirs | GPU time-slicing |
| Engine healthy, cache never used | Prompt shorter than `chunkSize` (256) stores nothing | `02` warm-up is ~2800 tok, asserts new `Stored` |
| Registration lost after idle | `lmcache-mp-worker-reaper` reaps idle workers | Warm-up right after rollout; any request re-registers |
| Empty answer / false WRONG | `gpt-oss` reasons first — tight `max_tokens` leaves `content: null` | `04` keeps 256, reports if answer stayed in `reasoning` |
| Same prompt → prose, then JSON | Sampling unpinned | `04` pins `temperature 0` + `seed 42`, echoes both |
| Port-forward returns a stranger's web UI | `8001` is Headlamp on Brev | Use 8010 / 8011 |
| `external_prefix_cache_hits_total` = 0 | APC sits in front and serves repeats first | Expected — disable APC on **both** arms to verify |

---

## 🗂️ One corpus, four representations

What actually moves and lands where when the Quick Demo (299 FinQA PDFs) is ingested:

| Stage | What happens | Form | Where it lives | Rough size |
| :--- | :--- | :--- | :--- | :--- |
| 1 · Download | HF → box disk | raw PDFs | `~/t2-ragbench` (host) | ~72 MB |
| 2 · Upload | box → retriever ingest job | same PDF bytes | retriever storage (PVC) | ~72 MB |
| 3 · Ingest | layout → tables → OCR → embed | regions / text / vectors **in flight** | transient in the NIM pods — **not stored** | — |
| 4 · Index | vectordb writes final rows | `{chunk text, vector, metadata}` (619 chunks) | **LanceDB** PVC | a few MB |
| 5 · Precompute | chunks prefilled through the engine | **KV tensors** per token | LMCache **L1 (host RAM)** | **~8–9 GB** |

📌 The sizes invert at the end: 72 MB of PDFs → a few MB of index → ~8–9 GB of KV (≈ 619 chunks × ~400 tok × ~34 KB/tok). The KV form is the heaviest by far — which is why **L1 sizing decides what the demo can cache** (Quick Demo fits; the 7,353-PDF Full Benchmark cannot).

📌 Re-ingesting the same corpus duplicates stages 2–4 only (counters inflate; retrieval dedupes identical text at query time). The KV cache does not duplicate — identical chunk text hashes to the same key.

---

## 📖 Reading the Try-It UI log

What each line in the `05-tryit-ui` uvicorn log means:

| Log line | What it is |
| :--- | :--- |
| `Started server process` → `Uvicorn running on :8000` | UI process booting — no endpoints involved |
| `127.0.0.1 - "GET /"` (repeating) | `index.html` fetched from **localhost** — Brev's secure-link prober confirming the port answers, not a person |
| `<external-ip> - "GET /"` | a real visitor loading the Try-It page through the secure link (`:0` port = proxied) |
| `GET /api/health` | proxies the **retriever** (`:7670/v1/health`) — drives the `● Retriever` dot |
| `GET /api/inference/health/baseline` | pings `BASELINE_LLM_URL` (`:8011`) — the `● Baseline (APC)` dot |
| `GET /api/inference/health/cacheblend` | pings `CACHEBLEND_LLM_URL` (`:8010`) — the `● CacheBlend` dot |
| `POST /api/ingest` | the **1 PDF / sample** button (ends with the injected 1-request CacheBlend warm) |
| `POST /api/dataset` + `GET /api/dataset/status` | **Quick Demo / Full Benchmark** download+ingest and its progress polling (quick mode ends with the injected precompute) |
| `GET /api/dataset/questions` | Benchmark tab loading FinQA questions (also used by `06-precompute`) |
| `POST /api/rag/stream` | a compare-page **Ask** — one per panel unless context is shared |

> Ingestion only happens via `04-smoke` and the UI ingest buttons — restarting `05` never adds documents. Re-ingesting the same file stores it again (new `document_id`; counters inflate), but retrieval dedupes identical chunk text at query time, so prompts are unaffected.

---

## 🎯 CacheBlend metrics live on the blend server (`:8080`), not vLLM

The compare UI derives Blend% from vLLM's `external_prefix_cache_hits_total` — which **never increments** under `CBKVConnector` (blended KV is injected mid-sequence, not claimed as prefix). The real counters are on the lmcache server's HTTP port:

```
lmcache_mp_l1_write_chunks_total   2118    ← stores
lmcache_mp_l1_read_chunks_total     198    ← actual blend reuse
lmcache_mp_l1_evicted_chunks_total  411    ← evictions (TTL, see below)
```

📌 Blend% is rescuable with current images: per-request **delta** of `l1_read_chunks_total` (after − before) × 256 (chunk size) ÷ prompt tokens = true reuse fraction.

📌 **Stored KV has a TTL.** `GET :8080/status` → `write_ttl_seconds: 600`, `read_ttl_seconds: 300` — L1 entries expire ~10 min after write (observed: 7/7 keys retained at +5 min → 1/6 with 5 "stale" at +10 min; evictions fire at 67% usage, well under the 0.8 watermark, so it's TTL, not pressure). **Any precompute must land within ~10 min of the queries it serves**, until the TTL is configurable/pinnable.

📌 Useful `:8080` endpoints: `GET /status` (L1 occupancy, TTLs), `GET /cache/objects` (what's stored), `POST /cache/clear` (clean cold/warm resets without redeploying), `POST /metrics/reset`.

Other UI metric caveats: **APC hit%** is a lifetime cumulative ratio (precompute traffic dilutes one arm — compare per-request deltas instead); **TTFT** counts to the first *content* token, so for reasoning models it includes the whole reasoning phase.

---

## 🔍 Verification commands

```bash
# blend server on the CUDA backend, not the CPU stub
kubectl -n cacheblend-workload logs $(kubectl -n cacheblend-workload get pod -o name | grep cacheblend | head -1) \
  | grep -E 'torch_device_type|CudaPinMemoryBackend|accelerator available'

# plugin injected — vanilla vLLM shows none of these
kubectl -n cacheblend-workload logs deploy/gptoss20b \
  | grep -E 'CBKVConnector|Registering kv caches|Wrapping .* KV cache tensors for IPC'

# blend engaging: matches > 0 means non-prefix reuse was found
kubectl -n cacheblend-workload logs deploy/gptoss20b \
  | grep -E 'match_probe|Registered CB rope|Prefetch request completed'

# cache counters: APC vs external tier
curl -s localhost:8010/metrics | grep -E '^vllm:(external_)?prefix_cache_(queries|hits)_total'
```
