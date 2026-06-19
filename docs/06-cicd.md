# Phase 6 - Lightweight CI/CD (optional)

**Goal:** push to `main` → images build in GitHub Actions → deploy to the VPS over
SSH → health-verified, with rollback on failure.
**Outcome:** a near-zero-downtime deploy you triggered with `git push`.

The workflow is in `.github/workflows/deploy.yml`. Read it alongside this.

---

## 6.1 The pipeline

```
git push main
   │
   ├─ job: build-and-push   (matrix: ocr-service, search-service)
   │     buildx → push ghcr.io/<you>/<repo>/<service>:latest + :<sha>
   │
   └─ job: deploy  (needs build-and-push)
         ssh VPS → git pull → docker compose pull → up -d → healthcheck (or fail)
```

Why build in CI instead of on the VPS? The VPS stays small and never needs build
toolchains or burns CPU compiling; it just **pulls** finished images. That's the
"build once, deploy anywhere" idea.

## 6.2 One-time setup

1. **Push this repo to GitHub.** GHCR (GitHub Container Registry) is enabled by
   default; the workflow pushes with the auto-provided `GITHUB_TOKEN`.

2. **Add repository secrets** (*Settings → Secrets and variables → Actions*):
   - `SSH_HOST` - your VPS IP/hostname
   - `SSH_USER` - the deploy user (e.g. `deploy`)
   - `SSH_KEY`  - a **private** key whose public half is in the VPS's
     `~/.ssh/authorized_keys`

3. **On the VPS, make Compose pull GHCR images** instead of building locally.
   The committed `docker-compose.yml` uses `build:` (great for local dev). For
   the server, add a `docker-compose.override.yml` next to it:

   ```yaml
   services:
     ocr-service:
       image: ghcr.io/<you>/<repo>/ocr-service:latest
       build: !reset null          # ignore the build context, just pull
     search-service:
       image: ghcr.io/<you>/<repo>/search-service:latest
       build: !reset null
   ```

   Compose automatically merges `docker-compose.override.yml`, so
   `docker compose pull ocr-service search-service` now pulls from GHCR.

   Also `docker login ghcr.io` once on the VPS (a PAT with `read:packages`) if the
   packages are private.

## 6.3 What a deploy does

The `deploy` job SSHes in and runs:
```bash
cd ~/ai-deployment-hub
git pull --ff-only
docker compose pull ocr-service search-service   # get the new images
docker compose up -d ocr-service search-service  # recreate only those two
```
Then it **polls health** for up to ~100s and **fails the job** (printing logs) if
either service doesn't reach `healthy`. A failed job is your signal to roll back.

## 6.4 Rollback

Because every build is also tagged with the commit SHA, rolling back is just
re-deploying a known-good tag:
```bash
# on the VPS
docker compose pull   # or pin the override image to a previous :<sha>
docker tag ghcr.io/<you>/<repo>/ocr-service:<good-sha> ...   # or edit override
docker compose up -d ocr-service search-service
```
A more advanced version captures the current SHA before deploy and auto-redeploys
it if the healthcheck fails - a good enhancement to add yourself.

## 6.5 Notes / hardening

- **Secrets:** `.env` is gitignored and never built into images. On the VPS it
  lives only on disk. For more safety, use Docker secrets or SOPS.
- **Only app images are CI-built** - infra images (Ollama, Milvus, Nginx, the
  monitoring stack) are pulled from their upstreams by tag, pinned in `.env`.
- **Zero-downtime caveat:** `up -d` recreates the container (brief blip). For true
  zero-downtime you'd run two replicas behind Nginx and drain one at a time -
  beyond this project's scope but worth mentioning in an interview.

---

## ✅ Phase 6 done when

- A push to `main` builds both images and pushes them to GHCR.
- The deploy job updates the VPS and the post-deploy healthcheck passes.
- You can articulate build-in-CI / pull-on-host, SHA tags for rollback, and the
  zero-downtime caveat.

**Interview story:** "I set up GitHub Actions to build service images, push to
GHCR, and deploy over SSH with a post-deploy health gate that fails the pipeline
(and surfaces logs) if a service doesn't come up healthy."

⬅️ Back to the [README](../README.md)
