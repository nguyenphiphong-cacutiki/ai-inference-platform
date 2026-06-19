# Phase 3 - Search / RAG with Milvus

**Goal:** add a vector database and a service that turns text into embeddings,
stores them, and answers semantic queries.
**Outcome:** the full RAG pipeline - image → OCR → text → embedding → Milvus → search.

Read `search-service/app/main.py`, `search-service/app/config.py`, and the
`etcd`/`minio`/`milvus`/`search-service` blocks in `docker-compose.yml`.

---

## 3.1 "Milvus" is actually three containers

Milvus *standalone* still needs:
- **etcd** - stores metadata (collections, schemas, indexes).
- **minio** - S3-compatible object storage for the vector data files.
- **milvus** - the engine that talks to both.

```
search-service ──gRPC :19530──> milvus ──> etcd  (metadata)
                                      └──> minio (vector segments)
```

This is a great lesson: a "single" dependency is often a small system. Each has
its own healthcheck, and `milvus` waits for `etcd` + `minio` to be healthy:

```yaml
milvus:
  depends_on:
    etcd:  { condition: service_healthy }
    minio: { condition: service_healthy }
```

## 3.2 How the search service works

`search-service` is deliberately light - **no ML libraries**. It delegates
embeddings to Ollama over HTTP and talks to Milvus with `pymilvus`.

Flow in `main.py`:
1. **Startup (`lifespan`)** - `connect_with_retry()` (Milvus can take ~a minute
   to be ready) then `ensure_collection()` creates the `documents` collection
   and an **HNSW / COSINE** index if it doesn't exist, and `load()`s it.
2. **`POST /search/index`** - embed text via Ollama → insert `{text, source,
   vector}` → `flush()` so it's instantly searchable.
3. **`POST /search/query`** - embed query → ANN search top-k → return rows + scores.

Why the schema dim is **768**: that's what `nomic-embed-text` outputs. If model
and schema disagree, inserts fail - a classic, instructive error.

```python
FieldSchema(name="vector", dtype=DataType.FLOAT_VECTOR, dim=settings.embed_dim)  # 768
```

## 3.3 Bring it up

Milvus depends on Ollama (for embeddings) being up with the embedding model
pulled - you did that in Phase 1. Now start the vector stack + service:

```bash
docker compose up -d --build etcd minio milvus search-service
docker compose ps           # wait for milvus (healthy), then search-service (healthy)
```

> `milvus` has `start_period: 60s` - it's normal for it to sit `(health: starting)`
> for a bit. `search-service` won't report healthy until it has connected and
> loaded the collection. Watch: `docker compose logs -f search-service`.

## 3.4 Test the pipeline

**Directly** (localhost test port `:8002`):

```bash
# Index a few documents
curl -s localhost:8002/search/index -H 'Content-Type: application/json' \
  -d '{"text":"Milvus is an open-source vector database.","source":"docs"}'
curl -s localhost:8002/search/index -H 'Content-Type: application/json' \
  -d '{"text":"The Eiffel Tower is in Paris, France.","source":"docs"}'
curl -s localhost:8002/search/index -H 'Content-Type: application/json' \
  -d '{"text":"Prometheus scrapes metrics from targets.","source":"docs"}'

# Semantic query - note it matches MEANING, not keywords
curl -s localhost:8002/search/query -H 'Content-Type: application/json' \
  -d '{"query":"where can I store embeddings?","top_k":2}' | python3 -m json.tool
```

The top hit should be the Milvus sentence even though your query shares no words
with it - that's the embedding doing its job.

**Through the gateway** (Phase 2 routing + auth):
```bash
curl -sk -u admin:admin https://localhost/search/query \
  -H 'Content-Type: application/json' \
  -d '{"query":"capital of France landmark","top_k":2}' | python3 -m json.tool
```

## 3.5 The end-to-end RAG flow (OCR → Search)

This is the money demo - chaining two AI services:

```bash
# 1. OCR an image to text
TEXT=$(curl -s -F file=@sample.png localhost:8001/ocr/run | python3 -c "import sys,json;print(json.load(sys.stdin)['text'])")
echo "OCR extracted: $TEXT"

# 2. Index that extracted text
curl -s localhost:8002/search/index -H 'Content-Type: application/json' \
  -d "$(python3 -c "import json,os;print(json.dumps({'text':os.environ['TEXT'],'source':'ocr'}))" TEXT="$TEXT")"

# 3. Search for it
curl -s localhost:8002/search/query -H 'Content-Type: application/json' \
  -d '{"query":"hello number","top_k":3}' | python3 -m json.tool
```

`scripts/smoke-test.sh` automates a version of this through the gateway.

## 3.6 Inspecting Milvus

```bash
# Milvus health + its own metrics (used by Prometheus in Phase 4)
curl -s localhost:9091/healthz; echo
curl -s localhost:9091/metrics | head

# See the MinIO console (object storage behind Milvus) - internal only, so port-forward:
#   it's not published; check it via: docker compose logs minio
```

---

## ✅ Phase 3 done when

- `etcd`, `minio`, `milvus`, `search-service` are all `(healthy)`.
- Indexing returns an `id`; querying returns semantically-ranked `hits`.
- The OCR→index→query chain works end-to-end.

**Interview stories:** Milvus standalone is really milvus+etcd+minio (orchestrating
a multi-container dependency with health-gated `depends_on`); embeddings delegated
to Ollama to keep the service light; why vector dim must match the embedding model;
HNSW + cosine for semantic search.

➡️ Next: [Phase 4 - Observability](04-observability.md)
