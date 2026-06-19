# Phase 4 - Observability: Prometheus + Grafana + Loki

**Goal:** see everything - host metrics, container metrics, app metrics, and logs
- in one place, with alerts.
**Outcome:** Grafana dashboards over Prometheus + Loki, and firing alert rules.

Read `monitoring/prometheus/prometheus.yml`, `monitoring/prometheus/alerts.yml`,
the `monitoring/grafana/provisioning/` files, and `logging/*.yml`.

---

## 4.1 The mental model

```
                 pull /metrics every 15s
Prometheus ◄──── node-exporter (host CPU/RAM/disk)
   │       ◄──── cAdvisor     (per-container CPU/RAM/net)
   │       ◄──── nginx-exporter (request/connection stats)
   │       ◄──── ocr-service /metrics, search-service /metrics, milvus /metrics
   │
   ├── evaluates alerts.yml  (ServiceDown, HostHighMemory, HostDiskAlmostFull)
   │
Grafana ◄── Prometheus (metrics datasource)
   │    ◄── Loki        (logs datasource)
   │
Loki ◄── Promtail ◄── Docker socket (tails every container's logs)
```

**Two different models worth internalizing:**
- **Prometheus *pulls*** metrics by scraping HTTP `/metrics` endpoints.
- **Loki is *pushed*** to by Promtail, which discovers containers via the Docker
  socket and ships their stdout/stderr.

## 4.2 Start the monitoring stack

```bash
docker compose --profile monitoring up -d
docker compose ps        # node-exporter, cadvisor, prometheus, grafana, loki, promtail, nginx-exporter
```

The `monitoring` **profile** is why these didn't start in earlier phases - they
only come up when you ask for them. Core services keep running untouched.

## 4.3 Prometheus - verify scraping

Open **http://localhost:9090** → *Status → Targets*. Every job should be **UP**:
`prometheus, node-exporter, cadvisor, nginx, ocr-service, search-service, milvus`.

Try queries in the *Graph* tab (this is PromQL):
```promql
up                                              # 1 = target healthy
rate(ocr_requests_total[5m])                    # OCR request rate by endpoint/status
sum by (container_label_com_docker_compose_service)(container_memory_usage_bytes)
100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100   # host CPU %
```

If a target is **DOWN**, that's a real finding - see Phase 5.

### Where the app metrics come from

Our FastAPI services expose `prometheus_client` counters/histograms at `/metrics`:
- `ocr_requests_total`, `ocr_request_duration_seconds`, `ocr_text_regions_detected`
- `search_requests_total`, `search_request_duration_seconds`, `search_embed_duration_seconds`

Generate some traffic, then watch the numbers move:
```bash
make smoke
```

## 4.4 Grafana - dashboards

Open **http://localhost:3000** (admin / admin → change the password).

Datasources (Prometheus + Loki) and the **"AI Hub Overview"** dashboard are
**auto-provisioned** (see `monitoring/grafana/provisioning/`), so they're already
there. The dashboard shows: targets up, host CPU/RAM, per-service container
CPU/RAM, app request rates, Nginx requests, and a live Loki log panel.

**Import community dashboards** for richer host/container views:
- *Dashboards → Import →* ID **1860** ("Node Exporter Full"), datasource Prometheus.
- ID **14282** ("cAdvisor") for container detail.

## 4.5 Loki - centralized logs in Grafana

*Explore* (compass icon) → datasource **Loki**. Query with LogQL:
```logql
{job="docker"}                                  # all container logs
{compose_service="ocr-service"}                 # just the OCR service
{compose_service="nginx"} |= "GET"              # nginx lines containing GET
{job="docker"} |= "error"                       # anything mentioning error
```
`compose_service` and `container` labels come from the relabeling in
`logging/promtail-config.yml`.

**Why this matters:** instead of `docker logs` on seven containers across a box,
you query all logs in one place, filtered and time-correlated with your metrics.

## 4.6 Alerts

`monitoring/prometheus/alerts.yml` defines three rules:
- **ServiceDown** - any scrape target `up == 0` for 1 minute.
- **HostHighMemory** - < 10% memory available for 2 minutes.
- **HostDiskAlmostFull** - root filesystem > 85% full for 5 minutes.

See them at **http://localhost:9090/alerts**. Force one to fire:
```bash
docker compose stop ocr-service     # wait ~1 min
# /alerts shows ServiceDown → PENDING → FIRING for job="ocr-service"
docker compose start ocr-service    # it resolves
```

### (Optional) route alerts to Telegram/Slack

Prometheus sends firing alerts to **Alertmanager**, which delivers them. To add
it: run an `alertmanager` container, point Prometheus at it
(`alerting: alertmanagers:`), and configure a `telegram_configs` or
`slack_configs` receiver with your bot token / webhook URL. Left as an exercise
so you wire a real notification channel yourself.

---

## ✅ Phase 4 done when

- All Prometheus targets are **UP**.
- The Grafana "AI Hub Overview" dashboard shows live data.
- You can query container logs in Grafana → Explore (Loki).
- Stopping a service makes **ServiceDown** fire, and starting it resolves it.

**Interview stories:** pull (Prometheus) vs push (Loki/Promtail) models;
instrumenting your own services with `/metrics`; provisioning Grafana as code so
dashboards/datasources aren't click-ops; alerting on `up == 0`.

➡️ Next: [Phase 5 - Troubleshooting drills](05-troubleshooting.md)
