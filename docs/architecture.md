# Architecture & Design Decisions

This document explains **what** the system is and **why** each choice was made.
Read it once before Phase 1, and again after Phase 4 - it'll make a lot more
sense the second time.

## 1. Goals that shaped the design

1. **Operations-first.** The point is deploying/running/monitoring AI services,
   not training models. So we use *small, off-the-shelf* models and spend our
   effort on healthchecks, limits, gateways, metrics, logs, and failure drills.
2. **Single host, Docker Compose.** No Kubernetes. One VPS, one `docker compose`
   command. This matches the target job description and is the right scope for
   a personal project.
3. **One public entrypoint.** Only Nginx (80/443) is exposed. Every other port
   is bound to `127.0.0.1` or kept inside the Docker network. This is both more
   secure and more realistic.
4. **Everything observable.** If you can't see it, you can't operate it. Metrics
   (Prometheus), dashboards (Grafana), and logs (Loki) cover all services.

## 2. Component responsibilities

| Component | Responsibility | Why this tech |
|---|---|---|
| **Ollama** | Serve the LLM and produce text embeddings | Dead-simple to run in Docker, CPU-friendly, one binary serves both chat + embeddings |
| **ocr-service** | HTTP wrapper around RapidOCR (PP-OCR/PaddleOCR models on ONNX Runtime) | FastAPI is fast to write, async, and gives us `/metrics` + `/health` easily; ONNX backend avoids the paddlepaddle native-crash problem |
| **search-service** | Embed text via Ollama, store/search vectors in Milvus | Keeps the RAG logic in one place; stays light by delegating embeddings |
| **Milvus** | Vector database (ANN search) | The JD's "nice-to-have"; industry-standard vector DB |
| **etcd / minio** | Milvus's metadata store / object store | Required by Milvus standalone; you learn that "one service" is often several |
| **Nginx** | TLS termination, routing, rate limit, auth | The classic API gateway; teaches reverse-proxy + networking |
| **Prometheus** | Pull metrics, evaluate alert rules | The de-facto metrics system; pull model is easy to reason about |
| **node-exporter / cAdvisor** | Host metrics / per-container metrics | Standard exporters; cover "is the box healthy" + "is each container healthy" |
| **Grafana** | Dashboards + log exploration | Single pane of glass over Prometheus *and* Loki |
| **Loki / Promtail** | Centralized logs | Lightweight ELK alternative; Promtail ships every container's logs to Loki |

## 3. Networking model

- All containers share one user-defined bridge network, `aihub`. On it, Docker
  runs an **embedded DNS server at `127.0.0.11`**, so containers reach each other
  by **service name** (`ollama`, `milvus`, `ocr-service`, …). No IPs hardcoded.
- **Port exposure policy:**
  - `nginx`: `80` + `443` on all interfaces → the only public surface.
  - `grafana`, `prometheus`, `ollama`, `ocr`, `search`, `milvus`: bound to
    `127.0.0.1` for local testing/debugging only.
  - `etcd`, `minio`, `loki`, `promtail`, exporters: **no host port** at all -
    internal to the network.
- **Nginx uses a runtime `resolver 127.0.0.11`** plus variables in `proxy_pass`.
  This defers DNS resolution of upstreams to *request* time. Effect: Nginx boots
  even if a backend container is down, and returns a 502 only when that specific
  route is hit. (If you instead hardcode `proxy_pass http://ocr-service:8000;`,
  Nginx refuses to even start when `ocr-service` is missing.) This single choice
  makes troubleshooting cases #3 and #7 observable.

## 4. The RAG data flow, precisely

**Indexing** (`POST /search/index`):
1. `search-service` receives `{text, source}`.
2. It calls Ollama `POST /api/embeddings` with `nomic-embed-text` → a 768-float vector.
3. It inserts `{text, source, vector}` into the Milvus `documents` collection
   (primary key auto-assigned) and `flush()`es so it's immediately searchable.

**Querying** (`POST /search/query`):
1. `search-service` embeds the query text the same way (same model → comparable space).
2. It runs an **HNSW + COSINE** approximate-nearest-neighbour search in Milvus.
3. Returns the top-k rows with their cosine similarity score.

Why COSINE + HNSW? Text embeddings encode meaning as *direction*, so cosine
similarity (angle) is the natural metric. HNSW is a graph index that gives
near-exact results with sub-millisecond latency at this scale.

Why 768 dimensions? That's the native output size of `nomic-embed-text`. The
Milvus schema (`embed_dim=768`) and the model must agree exactly, or inserts fail.

## 5. Reliability primitives (used on every service)

- **Healthchecks** - Compose marks a container `healthy`/`unhealthy`; downstream
  services use `depends_on: condition: service_healthy` to wait for readiness
  (e.g. `search-service` waits for `milvus` + `ollama`).
- **`restart: unless-stopped`** - containers come back after a crash or reboot,
  but stay down if *you* deliberately stopped them.
- **Resource limits** (`deploy.resources.limits.memory`) - prevent one service
  (especially the LLM) from OOM-killing the whole box. Tunable in `.env`.
- **Log rotation** (`max-size` + `max-file`) - a chatty container can't fill the
  disk.

## 6. What is intentionally *not* here

- **No Kubernetes / autoscaling** - out of scope; Compose on one host is the goal.
- **No GPU** - CPU inference with a 3B model is plenty for learning ops.
- **No managed secrets** - credentials live in `.env` (gitignored). On a real
  deployment you'd use Docker secrets or a vault; noted in Phase 6.
- **Self-signed TLS by default** - swap for Let's Encrypt on a real domain
  (Phase 2 covers both).
