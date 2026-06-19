# AI Service Deployment Hub

A multi-service AI stack - **LLM + OCR + Vector Search/RAG** - deployed with
**Docker Compose**, fronted by an **Nginx** API gateway, and fully observable
with **Prometheus + Grafana + Loki**.

This repo is built for *learning operations*: every service has healthchecks,
resource limits, restart policies, metrics, and centralized logs - the exact
things an "AI DevOps / Deployment Engineer" does day to day. Work through it
**phase by phase**; each phase has its own deep-dive guide in [`docs/`](docs/).

---

## What's inside

| Layer | Tech | Where |
|---|---|---|
| LLM | Ollama (`llama3.2:3b`) | `docker-compose.yml` → `ollama` |
| OCR | FastAPI + RapidOCR (PP-OCR/PaddleOCR models on ONNX) | `ocr-service/` |
| Search / RAG | FastAPI + Milvus + Ollama embeddings | `search-service/` |
| Vector DB | Milvus standalone (+ etcd + minio) | `docker-compose.yml` |
| Gateway | Nginx (TLS, rate limit, basic auth) | `nginx/` |
| Metrics | Prometheus, node-exporter, cAdvisor, nginx-exporter | `monitoring/` |
| Dashboards | Grafana (auto-provisioned) | `monitoring/grafana/` |
| Logs | Loki + Promtail | `logging/` |

---

## Architecture (request + data flow)

```
                         Client / curl / browser
                                  │  HTTPS (TLS, basic auth, rate limit)
                          ┌───────▼────────┐
                          │     Nginx       │   :80 → 301 → :443
                          │  (API gateway)  │
                          └──┬─────┬─────┬──┘
            /llm/*           │     │     │          /search/*
        ┌────────────────────┘     │     └───────────────────────┐
        │                /ocr/*    │                              │
 ┌──────▼──────┐         ┌─────────▼────────┐            ┌────────▼────────┐
 │   Ollama     │        │   ocr-service     │            │  search-service  │
 │  (LLM +      │◄───────┤  FastAPI +        │            │  FastAPI         │
 │  embeddings) │ embed  │  RapidOCR (PP-OCR)│            │                  │
 └──────────────┘        └──────────────────┘            └───────┬─────────┘
        ▲  embeddings (nomic-embed-text)                          │ store / search
        └─────────────────────────────────────────────┐         ▼
                                              ┌─────────┴───────────────┐
                                              │        Milvus            │
                                              │ standalone (vector DB)   │
                                              │  ├─ etcd  (metadata)     │
                                              │  └─ minio (object store) │
                                              └──────────────────────────┘

── Observability (profile: monitoring) ────────────────────────────────────────
  Prometheus ◄── node-exporter, cAdvisor, nginx-exporter, ocr/search /metrics
      │
   Grafana ◄── Prometheus (metrics) + Loki (logs)
      ▲
    Loki ◄── Promtail ◄── Docker socket (logs of every container)
```

The **RAG pipeline** ties three services together:

```
[image] → ocr-service → [text] → search-service → embed(Ollama) → [vector] → Milvus
                                        │
                          [query] → search-service → embed → Milvus → [ranked results]
```

Full design rationale: [`docs/architecture.md`](docs/architecture.md).

---

## Quickstart (TL;DR)

> Prereqs: Docker + Docker Compose plugin, ~6 GB free RAM, ~15 GB disk.
> First build downloads base images + builds the OCR/Search images, so allow 10–20 min.

```bash
cd ai-deployment-hub

# 1. One-time setup: creates .env, self-signed TLS cert, basic-auth (admin/admin)
make init

# 2. Start the core stack (Ollama, OCR, Search, Milvus, Nginx)
make up

# 3. Pull the LLM + embedding models into Ollama (persists in a volume)
make models

# 4. Verify everything end-to-end through the gateway
make smoke

# 5. (optional) Add the monitoring stack, then open Grafana
make up-mon
#   Grafana:    http://localhost:3000     (admin / admin)
#   Prometheus: http://localhost:9090
```

Direct (no gateway) test ports, bound to localhost only:
`OCR :8001 · Search :8002 · Ollama :11434 · Milvus :19530`.

To tear down (keep data): `make down`.  To wipe data too: `make clean`.

---

## Learn it phase by phase

Don't run `make up` and walk away - that defeats the purpose. Each guide builds
one layer, explains **why** it's configured that way, and ends with what to test.

| Phase | Guide | You build |
|---|---|---|
| 0 | [docs/00-environment-setup.md](docs/00-environment-setup.md) | Linux/Docker prep, hardening, project layout |
| 1 | [docs/01-llm-ocr.md](docs/01-llm-ocr.md) | Ollama LLM + OCR service (PP-OCR/ONNX), healthchecks, limits |
| 2 | [docs/02-nginx-gateway.md](docs/02-nginx-gateway.md) | Nginx reverse proxy, TLS, rate limit, basic auth |
| 3 | [docs/03-search-rag-milvus.md](docs/03-search-rag-milvus.md) | Milvus + embeddings + semantic search (RAG) |
| 4 | [docs/04-observability.md](docs/04-observability.md) | Prometheus, Grafana, Loki, alerts |
| 5 | [docs/05-troubleshooting.md](docs/05-troubleshooting.md) | 7 break/fix drills with RCA write-ups |
| 6 | [docs/06-cicd.md](docs/06-cicd.md) | GitHub Actions build + SSH deploy (optional) |

---

## Repository layout

```
ai-deployment-hub/
├── docker-compose.yml        # all services; monitoring behind a profile
├── .env.example / .env       # versions, limits, credentials
├── Makefile                  # convenience shortcuts (make help)
├── nginx/                    # gateway: nginx.conf, conf.d/, certs/, .htpasswd
├── ocr-service/              # FastAPI + RapidOCR/PP-OCR on ONNX (Dockerfile, app/)
├── search-service/           # FastAPI + Milvus + Ollama embeddings
├── monitoring/               # prometheus/, grafana/ (provisioned)
├── logging/                  # loki-config.yml, promtail-config.yml
├── scripts/                  # gen-certs, gen-htpasswd, pull-models, smoke-test
└── docs/                     # the phase-by-phase guide
```

---

## API cheat-sheet (through the gateway)

All calls go through Nginx on HTTPS with basic auth. `-k` trusts the self-signed cert.

```bash
# LLM (Ollama native API, prefixed with /llm)
curl -sk -u admin:admin https://localhost/llm/api/generate \
  -d '{"model":"llama3.2:3b","prompt":"Hello","stream":false}'

# OCR - upload an image, get text back
curl -sk -u admin:admin -F file=@sample.png https://localhost/ocr/run

# Search - index a document, then query semantically
curl -sk -u admin:admin https://localhost/search/index \
  -H 'Content-Type: application/json' \
  -d '{"text":"Milvus is a vector database","source":"notes"}'

curl -sk -u admin:admin https://localhost/search/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"what stores embeddings?","top_k":3}'
```

See [docs/05-troubleshooting.md](docs/05-troubleshooting.md) if anything misbehaves.
