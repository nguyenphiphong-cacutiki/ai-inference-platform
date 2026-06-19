# Phase 2 - Nginx Gateway + Security

**Goal:** put a single, secured front door in front of all services.
**Outcome:** TLS, routing, rate limiting, and basic auth - and you understand the
reverse-proxy + DNS mechanics that make troubleshooting possible later.

Read `nginx/nginx.conf` and `nginx/conf.d/default.conf` alongside this guide.

---

## 2.1 What the gateway does

```
client ──HTTPS──> :443 nginx ──http──> ollama / ocr-service / search-service
            :80 ──301──> :443
```

One server block on 443 handles three route groups:
- `/llm/*`    → `ollama:11434` (prefix stripped → Ollama's native `/api/...`)
- `/ocr/*`    → `ocr-service:8000` (pass-through, already namespaced)
- `/search/*` → `search-service:8000` (pass-through)

Plus `/healthz` (no auth, used by the container healthcheck) and an internal
`stub_status` page on `:8080` for the metrics exporter in Phase 4.

## 2.2 The runtime-resolver trick (important)

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;     # Docker's embedded DNS
location /ocr/ {
    set $upstream_ocr http://ocr-service:8000;
    proxy_pass $upstream_ocr$request_uri;     # variable → resolved per-request
}
```

If you write `proxy_pass http://ocr-service:8000;` directly, Nginx resolves the
name **at startup** and **refuses to start** if `ocr-service` isn't running yet.
By putting the upstream in a **variable** and adding a **resolver**, resolution
happens **per request**. Result:

- Nginx always boots, even if a backend is down.
- A missing/dead backend yields a **502 at request time**, not a crash loop.

This is the foundation for troubleshooting cases #3 (wrong DNS name) and #7
(backend dead → 502) in Phase 5. Good to understand *now*.

## 2.3 TLS

`scripts/gen-certs.sh` (already run by `make init`) created a self-signed cert.
Nginx loads it:

```nginx
ssl_certificate     /etc/nginx/certs/server.crt;
ssl_certificate_key /etc/nginx/certs/server.key;
ssl_protocols       TLSv1.2 TLSv1.3;
```

Self-signed means browsers/curl warn about trust - use `curl -k` to bypass. For
a **real domain on a VPS**, use Let's Encrypt instead (section 2.7).

## 2.4 Rate limiting

In `nginx.conf`:
```nginx
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;
```
and per route: `limit_req zone=api_limit burst=20 nodelay;`

Meaning: each client IP gets ~10 requests/second steady-state, with a burst of 20
absorbed instantly; excess gets **HTTP 429**. This protects the (slow, expensive)
AI backends from a hot loop or abuse.

## 2.5 Basic auth

Every `/llm`, `/ocr`, `/search` location requires:
```nginx
auth_basic           "AI Hub";
auth_basic_user_file /etc/nginx/.htpasswd;
```
`make init` created `.htpasswd` with `admin:admin` (apr1-hashed). Change it:
```bash
make htpasswd USER=phong PASS='a-strong-password'
docker compose restart nginx       # reload the mounted file
```

> Basic auth is the *minimum*. It's fine behind TLS for an internal tool. For a
> public API you'd graduate to API keys or OAuth - noted as a future step.

## 2.6 Start Nginx and test

```bash
docker compose up -d nginx
docker compose ps                  # nginx (healthy)
```

**Inspect the handshake and headers** (the `-v` is the learning part):

```bash
# TLS handshake + redirect from 80 → 443
curl -v http://localhost/healthz                 # see 301 Location: https://...
curl -vk https://localhost/healthz               # see TLS cert + "ok"

# Auth: 401 without creds, 200 with
curl -k https://localhost/ocr/health             # 401 Unauthorized
curl -k -u admin:admin https://localhost/ocr/health   # 200 {"status":"ok"}

# Route to the LLM through the gateway (prefix stripped)
curl -k -u admin:admin https://localhost/llm/api/generate \
  -d '{"model":"llama3.2:3b","prompt":"hi","stream":false}'
```

**Trigger the rate limiter** to see 429s:
```bash
for i in $(seq 1 40); do
  curl -sk -o /dev/null -w "%{http_code} " -u admin:admin https://localhost/ocr/health
done; echo
# you'll see 200s turn into 429s once the burst is exhausted
```

## 2.7 _(VPS)_ Real TLS with Let's Encrypt

On a server with a real domain pointed at it (DNS A record → server IP):

```bash
sudo apt-get install -y certbot
sudo certbot certonly --standalone -d api.yourdomain.com   # needs :80 free briefly
```

Then point Nginx at the issued files (mount them, or copy into `nginx/certs/`):
```
ssl_certificate     /etc/letsencrypt/live/api.yourdomain.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/api.yourdomain.com/privkey.pem;
```
Certbot auto-renews via a systemd timer; reload Nginx after renewal.

---

## ✅ Phase 2 done when

- `http://localhost/...` 301-redirects to HTTPS.
- Protected routes return **401** without creds, **200** with `admin:admin`.
- You've seen **429** responses from the rate limiter.
- `curl -k -u … https://localhost/llm/api/generate` reaches Ollama.

**Interview stories:** why upstreams use a variable + `resolver` (so Nginx starts
without all backends and returns clean 502s); TLS termination at the edge;
layered protection with rate limiting + auth in front of expensive AI services.

➡️ Next: [Phase 3 - Search/RAG with Milvus](03-search-rag-milvus.md)
