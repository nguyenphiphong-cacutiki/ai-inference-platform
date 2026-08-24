# Phase 1 - Core AI Services: LLM + OCR

**Goal:** get the two foundational AI services running under Compose with
healthchecks, resource limits, and restart policies.
**Outcome:** you can curl an LLM and an OCR endpoint directly (no gateway yet).

---

## 1.1 The LLM service (Ollama)

Ollama is a single container that downloads and serves models. Look at its block
in `docker-compose.yml`:

```yaml
ollama:
  image: ollama/ollama:${OLLAMA_VERSION:-latest}
  ports: ["127.0.0.1:11434:11434"]   # localhost only
  volumes: [ollama_data:/root/.ollama]
  healthcheck:
    test: ["CMD", "ollama", "list"]   # the image has no curl; use its own CLI
  deploy:
    resources:
      limits: { memory: ${OLLAMA_MEM_LIMIT:-5g} }
```

**Why these matter:**

- **Volume `ollama_data`** - models are multi-GB. Without a named volume you'd
  re-download them every time the container is recreated.
- **Healthcheck via `ollama list`** - the official image doesn't include `curl`,
  so the usual `curl -f localhost:11434` healthcheck would always fail. `ollama
list` exits 0 only when the server is up. (This is a real gotcha worth knowing.)
- **`memory: 5g`** - a 3B model in CPU mode uses ~3–4 GB. The limit stops Ollama
  from ballooning and OOM-killing the box. You'll _deliberately_ set it too low
  in Phase 5 to watch an OOM happen.

### Start just Ollama and pull a model

```bash
docker compose up -d ollama
docker compose ps                       # wait until STATUS shows (healthy)
make models                             # pulls llama3.2:3b + nomic-embed-text
```

`make models` runs `ollama pull` _inside_ the container. The models land in the
`ollama_data` volume, so they survive restarts.

### Test the LLM directly

```bash
curl http://localhost:11434/api/generate \
  -d '{"model":"llama3.2:3b","prompt":"Explain Docker in one sentence.","stream":false}'
```

You should get a JSON response with a `response` field. Also try the embeddings
endpoint that the search service will use later:

```bash
curl http://localhost:11434/api/embeddings \
  -d '{"model":"nomic-embed-text","prompt":"hello"}' | head -c 120
```

That returns a 768-number array - remember that 768, it's the Milvus vector dim.

---

## 1.2 The OCR service (FastAPI + PP-OCR models on ONNX)

This is the first service **we** build. Read `ocr-service/app/main.py` and
`ocr-service/Dockerfile` alongside this.

> **A real deployment decision (good interview story).** The plan called for
> "PaddleOCR". The obvious approach - `pip install paddlepaddle paddleocr` - built
> fine but the container **aborted at runtime with `free(): invalid size`**: the
> paddlepaddle native wheel is incompatible with the glibc in current slim Python
> images (it's not an AVX issue - the CPU has AVX2). Rather than fight native
> crashes, we serve the **exact same PP-OCR models through `rapidocr-onnxruntime`
> (ONNX Runtime)**. Same models, a pure-ONNX backend, ~700 MB instead of ~3 GB,
> and no native abort. This is _operations_: when a dependency is unstable in your
> target environment, swap the runtime, keep the capability.

Key design points (all visible in the code):

- **Model loaded once** in the FastAPI `lifespan` handler, not per request -
  loading the engine takes a moment and hundreds of MB.
- **Models baked into the image** - `rapidocr-onnxruntime` ships the ONNX models
  inside the wheel, and the Dockerfile warms the engine at build time, so the
  first request is fast and the container needs **no internet at runtime**.
- **Three endpoints:** `POST /ocr/run` (the work), `GET /ocr/health` (healthcheck),
  `GET /metrics` (Prometheus, used in Phase 4).
- **Paths namespaced under `/ocr`** so they're identical whether you call the
  container directly or via Nginx later.

### Build and start it

```bash
docker compose up -d --build ocr-service
```

> First build takes a few minutes: it installs onnxruntime + opencv and warms up
> the engine. Watch progress with `docker compose logs -f ocr-service`.
> The container becomes `healthy` only after the model finishes loading
> (hence `start_period: 40s` in the healthcheck).

### Test OCR directly

Grab any image with text (a screenshot works). Then:

```bash
curl -F file=@'/home/phong/Pictures/Screenshots/Screenshot from 2026-06-24 09-57-42.png' http://localhost:8001/ocr/run
```

You get back `{ text, num_regions, lines:[{text, confidence, box}], ... }`.
`:8001` is the localhost-only test port mapped to the container's `:8000`.

No image handy? Make one:

```bash
sudo apt-get install -y imagemagick    # if needed
convert -size 600x120 xc:white -gravity center \
  -pointsize 36 -annotate 0 "Hello OCR 12345" sample.png
curl -F file=@sample.png http://localhost:8001/ocr/run
```

---

## 1.3 Healthchecks, restart policy, limits - the operations core

These three appear on **every** service and are means
"verify it's running."

**See health status:**

```bash
docker compose ps
docker inspect --format '{{json .State.Health}}' ocr-service | python3 -m json.tool
```

**Prove the restart policy works:**

```bash
docker inspect --format '{{.State.Pid}}' ocr-service       # get PID
sudo kill -9 <PID> # simulate a crash
docker compose ps              # within seconds it restarts (restart: unless-stopped)
```

`unless-stopped` means: restart on crash/reboot, but if _you_ run
`docker compose stop ocr-service`, it stays down (won't fight you).

**Watch resource usage:**

```bash
docker stats                   # live CPU/MEM per container; Ctrl-C to exit
```

---

## ✅ Phase 1 done when

- `docker compose ps` shows `ollama` and `ocr-service` both `(healthy)`.
- `curl :11434/api/generate` returns text; `:8001/ocr/run` returns OCR results.
- You've killed `ocr-service` and watched it auto-restart.

**Interview stories:** the Ollama healthcheck gotcha (no curl in image →
use `ollama list`); baking OCR models into the image for fast, offline cold
starts; why the model is loaded once at startup, not per request.

➡️ Next: [Phase 2 - Nginx Gateway](02-nginx-gateway.md)
