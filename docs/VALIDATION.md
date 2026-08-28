# Validation

Reference cold-boot run and the failure modes the deploy scripts handle.

---

## 📋 Reference run

Fresh 4× RTX PRO 6000 node, empty caches, `0.5.3` tuple. **~31 minutes end to end**, of which ~21 is first-run NIM weight download.

| Phase | Duration | Ends with |
| :--- | :--- | :--- |
| `01-cluster` | ~2 min | cert-manager rolled out |
| `02-engines` | ~9 min | both engines serving, MP store fired |
| `03-nemo` | ~20 min | all 4 NIMServices Ready, retriever health ok |
| `04-smoke` | ~1 min | correct answer from both arms |

Tail of a passing run:

```
==> engines up — CacheBlend=svc/gptoss20b:8000  baseline=svc/gptoss20b-base:8000
==> warm-up: registering the engine with lmcache (the MP store must fire)
  served a ~2800-tok completion in 14.4s
  MP store fired — 1 new "Stored" events on the blend server
==> GPU Operator ns=gpu-operator-resources clusterpolicy=cluster-policy
==> applying GPU time-slicing config (allocatable now: 4)
  allocatable nvidia.com/gpu: 16 (expected 16)
==> all NIMServices Ready
==> retriever healthy: {"status":"ok","mode":"standalone"}

==> E2E smoke: ingest -> retrieve -> generate
  query      "Which animal is jumping onto a laptop?"  (expect: cat)
  ingest     multimodal_test.pdf -> 8 chunks in 5.06s  (layout -> tables -> OCR -> embed -> LanceDB)
  retrieve   3 hits, top d=1.159
  sampling   max_tokens=256 temperature=0 seed=42  (identical on both arms)
  generate   baseline   (4.0s, 45 tok) OK -> "Cat"
  generate   cacheblend (1.7s, 45 tok) OK -> "Cat"

  RESULT     PASS - correct answer ("cat") from: baseline, cacheblend
```

> ⚠️ **The per-arm generate times are not a benchmark.** At ~363 prompt tokens there is nothing for CacheBlend to reuse, and both engines run `--enforce-eager` (~11 tok/s decode), so the numbers are dominated by answer length and cold-request effects. They have landed on either side across runs. Use a real corpus and the LDP harness for measurement.

---

## 🪤 Failure modes handled

Each of these was hit on a real deploy; the scripts now detect or prevent them.

| Symptom | Cause | Handled by |
| :--- | :--- | :--- |
| Deploy hangs silently after the blend server is Ready, no error | `0.5.3` dropped the `Using backend: lmcache.c_ops` log line; the backend probe moved to `lmcache.v1.platform._device_detect` | `02-engines.sh` matches several banner variants (`torch_device_type=cuda`, `CudaPinMemoryBackend`, `accelerator available: True`) and bounds the wait so a future rename times out instead of hanging |
| `namespaces "gpu-operator" not found` | Brev's single-node k8s ships the GPU Operator in **`gpu-operator-resources`**, not `gpu-operator` | `03-nemo.sh` discovers the namespace from the `nvidia-device-plugin` pod and the ClusterPolicy by name |
| Chart fails: `ngcImagePullSecret.password required when create=true` | `NGC_API_KEY` was set but **empty** — `set -u` does not catch set-but-empty | `03-nemo.sh` guards non-empty **and** checks the `nvapi-` prefix |
| NIM pods `ImagePullBackOff`, weights fail with `402 Payment Required` on `api.ngc.nvidia.com/.../models/...` | NGC account not enrolled in the **free NVIDIA Developer Program**. Note `docker login nvcr.io` and image pulls can succeed while weight manifests 402 — container access ≠ weight access | Prerequisite: enrol at developer.nvidia.com on the same account, then **regenerate** the API key (a key minted before enrolment does not inherit it) |
| Plugin init container `ImagePullBackOff` with `failed to resolve image ... not found` | Tag does not exist for that image | Pin a published tag; verify with `docker manifest inspect <ref>` before deploying |
| Same, but `httpReadSeeker: failed open: content at .../manifests/sha256:... not found` | **Dangling tag** — the tag resolves to a digest whose manifest content is missing (incomplete or garbage-collected push). Registry-side, not fixable client-side | Report to the registry owner; pin a different tag meanwhile |
| GPU slicing step idles ~5 min on every re-run | Waiting for "more units than before" can never be satisfied once slicing is already applied | `03-nemo.sh` compares against expected `physical GPUs × replicas` instead |
| NIM pods stay `Pending` | Each of the 4 core NIMs requests a whole `nvidia.com/gpu`, but the engines already hold dedicated cards | GPU time-slicing so one physical GPU advertises several schedulable units |
| Engine looks healthy but its cache path was never used | A prompt shorter than `server.chunkSize` (256) stores nothing | `02-engines.sh` sends a ~2800-token (~11 chunk) warm-up and asserts new `Stored` events appear |
| Engine loses its lmcache registration after idling | lmcache reaps idle workers (`lmcache-mp-worker-reaper`, 30 s interval) | Same warm-up runs right after the engines come up; any request re-registers |
| Answer comes back empty / assertion reports a wrong answer | `gpt-oss` is a **reasoning** model — it spends tokens in `reasoning` before `content`, so a tight `max_tokens` leaves `content: null` | `04-smoke.sh` keeps `max_tokens: 256` and reports explicitly when the answer stayed in `reasoning` |
| Identical prompt returns prose one run and JSON the next; timings swing | Sampling was unpinned | `04-smoke.sh` pins `temperature: 0` + `seed: 42` and echoes them, from the same dict it sends |
| Local port-forward returns someone else's web page | Port **8001** is Headlamp on Brev's image | Forward engines to 8010 / 8011 |
| `vllm:external_prefix_cache_hits_total` reads 0 on a working stack | vLLM's APC sits in front of the external tier and serves repeats first | Expected. Verify with APC disabled on **both** arms, or restart the producer (clears GPU prefix cache, lmcache keeps its store) and replay |

---

## 🔍 Useful checks

```bash
# blend server on the CUDA backend (not the CPU stub)
kubectl -n cacheblend-workload logs $(kubectl -n cacheblend-workload get pod -o name | grep cacheblend | head -1) \
  | grep -E 'torch_device_type|CudaPinMemoryBackend|accelerator available'

# plugin injected (vanilla vLLM would show neither)
kubectl -n cacheblend-workload logs deploy/gptoss20b | grep -E 'CBKVConnector|Registering kv caches|Wrapping .* KV cache tensors for IPC'

# blend actually engaging: matches > 0 means non-prefix reuse was found
kubectl -n cacheblend-workload logs deploy/gptoss20b | grep -E 'match_probe|Registered CB rope|Prefetch request completed'

# cache counters (APC vs external tier)
curl -s localhost:8010/metrics | grep -E '^vllm:(external_)?prefix_cache_(queries|hits)_total'
```
