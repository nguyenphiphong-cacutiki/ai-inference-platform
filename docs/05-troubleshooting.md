# Phase 5 - Troubleshooting Drills + RCA

**Goal:** deliberately break things and fix them, building the muscle memory and
the *stories* an interviewer wants to hear.
**Outcome:** 7 documented incidents in RCA format.

For each drill, write up: **Symptom → How detected → Root cause → Fix → Prevention.**
Templates are filled in below - reproduce them on your machine and confirm each
observation yourself. Keep your own notes; the act of writing the RCA is the point.

> Tip: keep Grafana + `docker compose logs -f` open in split panes while you do
> these - half the skill is knowing *where to look*.

---

## Drill 1 - Container OOM (out of memory)

**Trigger:**
```bash
# Set Ollama's limit absurdly low, then force a generate that needs more.
# Edit .env:  OLLAMA_MEM_LIMIT=512m
docker compose up -d ollama
curl localhost:11434/api/generate -d '{"model":"llama3.2:3b","prompt":"hi","stream":false}'
```
**Symptom:** request hangs/fails; container restarts; `docker compose ps` shows
recent restart.
**How detected:**
```bash
docker stats                              # MEM% pinned at 100%
docker inspect ollama --format '{{.State.OOMKilled}}'   # true
dmesg | grep -i oom                       # kernel "Out of memory: Killed process"
docker logs ollama
```
**Root cause:** memory limit below the model's working set → kernel OOM-killer
terminates the process.
**Fix:** raise `OLLAMA_MEM_LIMIT` back to `5g` (or use a smaller model);
`docker compose up -d ollama`.
**Prevention:** size limits from observed `docker stats`; alert on container
memory near its limit; pick models that fit the host.

---

## Drill 2 - Port conflict

**Trigger:** start something else on a port Compose wants (e.g. 11434):
```bash
python3 -m http.server 11434 &            # squat on the port
docker compose up -d ollama               # fails to bind
```
**Symptom:** `Error ... bind: address already in use`.
**How detected:**
```bash
ss -tulpn | grep 11434                    # shows the process holding it
# (older tool: netstat -tulpn | grep 11434)
```
**Root cause:** two processes want the same host port.
**Fix:** stop the squatter (`kill %1`) or change the host-side port mapping in
`docker-compose.yml`. Re-run.
**Prevention:** keep a port map in the README; bind admin ports to `127.0.0.1`;
avoid ad-hoc processes on service ports.

---

## Drill 3 - Wrong DNS name in Nginx

**Trigger:** in `nginx/conf.d/default.conf`, misspell an upstream, e.g.
`set $upstream_ocr http://ocr-servic:8000;` then `docker compose restart nginx`.
**Symptom:** `https://localhost/ocr/health` returns **502 Bad Gateway**; other
routes still work.
**How detected:**
```bash
docker compose logs nginx | tail          # "no resolver / name ... could not be resolved" or upstream errors
docker exec nginx nslookup ocr-service    # resolves; ocr-servic does NOT
```
> Note: thanks to the runtime `resolver`, Nginx *still starts* - only the bad
> route 502s. Without that pattern, Nginx would refuse to start at all (a
> different, more confusing symptom). That contrast is a great talking point.

**Root cause:** typo'd service name → Docker DNS can't resolve it.
**Fix:** correct the name; `docker compose restart nginx`.
**Prevention:** config review/validation (`nginx -t`); keep service names in one
place; treat config as code.

---

## Drill 4 - Service down, healthcheck failing

**Trigger:**
```bash
docker stop search-service                # silently kill it
```
**Symptom:** `/search/*` returns 502; dashboards show it gone.
**How detected:**
```bash
docker compose ps                                       # search-service: Exited
docker inspect --format '{{json .State.Health}}' milvus | python3 -m json.tool
# and in monitoring: Prometheus /targets shows it DOWN; ServiceDown alert fires
```
**Root cause:** the container/process is not running.
**Fix:** `docker compose start search-service` (or `up -d`).
**Prevention:** `restart: unless-stopped` (so crashes self-heal); the
`ServiceDown` alert; healthchecks so orchestration knows the true state.

---

## Drill 5 - Firewall blocking a port _(VPS)_

**Trigger:**
```bash
sudo ufw deny 443/tcp
```
**Symptom:** clients can't reach the API; `curl https://SERVER/...` times out,
but `curl -k https://localhost/...` *on the box* still works.
**How detected:**
```bash
curl -v https://SERVER_IP/healthz         # connection timeout (not a TLS/HTTP error)
sudo ufw status                           # 443 DENY
sudo ss -tulpn | grep :443                # nginx IS listening locally
# optionally: sudo tcpdump -ni any port 443   # SYNs arrive, no completion
```
**Root cause:** host firewall drops inbound 443; the service itself is fine.
**Fix:** `sudo ufw allow 443/tcp`.
**Prevention:** document required ports; test external reachability after
firewall changes; the "works locally, not remotely" pattern → suspect network/firewall.

---

## Drill 6 - Disk full from logs/volumes

**Trigger:**
```bash
docker exec -it milvus bash -c "fallocate -l 5G /var/lib/milvus/junk.bin"   # eat space
df -h /
```
**Symptom:** services error on writes; new data won't persist; possible crashes.
**How detected:**
```bash
df -h                                     # filesystem near 100%
du -sh /var/lib/docker/volumes/* | sort -h | tail   # biggest volumes
docker system df                          # space used by images/containers/volumes
```
**Root cause:** unbounded growth (junk file here; in real life: unrotated logs).
**Fix:** remove the junk (`docker exec milvus rm /var/lib/milvus/junk.bin`);
`docker system prune` for dangling images.
**Prevention:** we already cap container logs (`max-size`/`max-file` in the
`x-logging` anchor) - that's the real-world fix for runaway logs; alert on disk
(`HostDiskAlmostFull`); retention limits on Prometheus/Loki.

---

## Drill 7 - API returns 502 (backend dead, Nginx still routing)

**Trigger:**
```bash
docker stop ocr-service
curl -sk -u admin:admin https://localhost/ocr/run -F file=@sample.png   # 502
```
**Symptom:** gateway returns **502 Bad Gateway** for that route only.
**How detected:**
```bash
docker compose logs nginx | tail          # upstream connect failed / refused
# In Grafana → Explore (Loki):  {compose_service="nginx"} |= "502"
docker compose ps                         # ocr-service is down
curl localhost:8001/ocr/health            # connection refused (proves it's the backend)
```
**Root cause:** Nginx forwards to a backend that isn't accepting connections.
**Fix:** bring the backend back: `docker compose start ocr-service`.
**Prevention:** healthchecks + `restart: unless-stopped`; `ServiceDown` alert;
the `upstream=` field in the Nginx access log makes 502 root-causing fast.

---

## ✅ Phase 5 done when

You've reproduced all 7, confirmed each detection command yourself, and written
your own RCA notes. These are your interview stories - each one is a
"tell me about a time you debugged X" answer ready to go.

➡️ Next: [Phase 6 - CI/CD (optional)](06-cicd.md)
