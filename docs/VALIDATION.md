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

> ⚠️ **Generate times are not a benchmark.** At ~363 prompt tokens CacheBlend has nothing to reuse, and both engines run `--enforce-eager` (~11 tok/s decode), so timings track answer length and cold-request effects. They have landed on either side across runs. Measure with a real corpus and the LDP harness.

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
