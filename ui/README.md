# Try-It web UI

Adapted from the [NeMo-Retriever](https://github.com/yiwzhao/NeMo-Retriever) deploy webui
(`brev-launchable` branch, commit `9e2b172`), Apache-2.0 — see [LICENSE](./LICENSE).

Local modifications vs upstream:

- `inference.py` — Blend% from lmcache server counters (`:8080` `lmcache_mp_l1_*` per-request
  deltas; vLLM's `external_prefix_cache_hits_total` never increments under `CBKVConnector`);
  APC hit% as a per-request delta instead of a lifetime ratio; TTFT on the first stream
  delta of any kind (gpt-oss emits `reasoning` before `content`).
- `app.py` — CacheBlend precompute after dataset ingest (quick mode) and after the 1-PDF
  sample ingest, so first asks have KV to blend; `REPO_ROOT` adjusted to this repo's layout.
- `index.html` — hardcoded JupyterLab section removed; Full Benchmark confirm explains the
  corpus exceeds the CacheBlend L1.

Served by `deploy/05-tryit-ui.sh`. Sample PDFs for the ingest buttons live in `../data/`.
`THIRD_PARTY_DATA.md` covers the benchmark dataset the UI can download at runtime.
