# 🚀 cacheblend-nemo-rag-launchable — backend deploy

> ✍🏼 Backend deploy for the RAG demo: the **TMO CacheBlend engines** (baseline + optimized) **+ NeMo Retriever**, brought up on one single-node **microk8s** cluster. The **launchable itself is NVIDIA-owned** — it clones this repo and runs `bootstrap.sh`; this repo is the dependency it consumes. The front-end (Try-It landing page + Secure Link) is NVIDIA's.

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
| `CB_PLUGIN_TOKEN` | Docker Hub read token → private `tensormesh/cacheblend-plugin` |
| `TMO_GHCR_TOKEN` | GHCR `read:packages` token → the TMO Helm chart |
| `TMO_GHCR_USER` | GHCR username |
| `NGC_API_KEY` | NVIDIA NGC key → the NeMo Retriever NIMs |

---

## 🎛️ GPU layout — 4× RTX PRO 6000

📌 `CacheBlend → 1 GPU`  ·  `baseline → 1 GPU`  ·  `NeMo NIMs → 1 GPU (time-sliced)`  ·  `1 spare`
