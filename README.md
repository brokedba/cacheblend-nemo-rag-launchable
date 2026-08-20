# 🚀 cacheblend-nemo-rag-launchable — backend deploy

> ✍🏼 Backend deploy for the RAG demo: the **TMO CacheBlend engines** (baseline + optimized) **+ NeMo Retriever**, brought up on one single-node **microk8s** cluster.  
**Status:** `WIP / staging`

---

## 📂 Project Structure

```bash
./
├── bootstrap.sh                          # orchestrator — guards env, runs the 3 deploy steps
├── deploy/
│   ├── 01-cluster.sh                     # driver sanity + microk8s ready + cert-manager
│   ├── 02-engines.sh                     # TMO operator + CacheBlend arm + baseline arm
│   └── 03-nemo.sh                        # GPU time-slicing + NIM Operator + NeMo chart
├── config/
│   ├── manifests/
│   │   ├── engine-cacheblend.yaml        # optimized: vLLM + APC + CacheBlend (webhook-injected)
│   │   ├── engine-baseline.yaml          # baseline: vanilla vLLM + APC
│   │   ├── tmo-cacheblend-values.yaml    # TMO Helm values (operator + CacheBlendEngine)
│   │   └── gpu-timeslicing.yaml          # time-slice config for the NeMo GPU
│   └── nemo/
│       └── values-brev-core.yaml         # NeMo Retriever "core RAG" chart values
└── README.md                             # ← you are here
```

---

## 🏗️ What it deploys

| Component | Service | Role |
| :--- | :--- | :--- |
| **CacheBlend engine** *(optimized)* | `svc/gptoss20b:8000` | vLLM + APC + CacheBlend — TMO operator + webhook-injected plugin, gpt-oss-20b |
| **Baseline engine** | `svc/gptoss20b-base:8000` | vanilla vLLM + APC, gpt-oss-20b |
| **NeMo Retriever** | `svc/retriever-nemo-retriever:7670` | 4 core NIMs + LanceDB (NeMo Retriever chart) |

UI wiring: `CACHEBLEND_LLM_URL` · `BASELINE_LLM_URL` · retriever `:7670`.

---

## 🔑 Required env

> Injected by the launchable's env-var field at deploy time — **never committed to the repo.**

| Var | For |
| :--- | :--- |
| `TENSORMESH_API_KEY` | `tm_...` key for **`artifacts.tensormesh.ai`** → private Helm chart + `cacheblend-plugin` image |
| `NGC_API_KEY` | NVIDIA **NGC Catalog** key (`nvapi-...`) → the NeMo Retriever NIMs |

> The artifact proxy takes the key as the password with the literal username **`x-access-token`** — one revocable key covers both the chart and the private image. Public OSS images (`lmcache/vllm-openai`, `lmcache/lmcache-operator`) come from `docker.io` unauthenticated.

---

## 📦 Version tuple

> Keep these in lockstep — mixing versions across chart / operator / engine is unsupported.

| Component | Version |
| :--- | :--- |
| Helm chart | `0.5.2` |
| Operator | `v0.5.2` |
| Cache engine | `v0.5.2` |
| CacheBlend plugin | `v0.5.2` *(private, via the proxy)* |
| vLLM serving image | `lmcache/vllm-openai:v0.5.2` |

---

## 🎛️ GPU layout — 4× RTX PRO 6000

📌 `CacheBlend → 1 GPU`  ·  `baseline → 1 GPU`  ·  `NeMo NIMs → 1 GPU (time-sliced)`  ·  `1 spare`
