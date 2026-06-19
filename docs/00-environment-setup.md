# Phase 0 - Environment Setup

**Goal:** a hardened Linux host with Docker, ready to run the stack.
**Outcome:** you understand basic server hardening (users, SSH, firewall) and
have the project on disk.

You can do this on your **local Ubuntu machine** (what this repo was built on) or
on a **VPS/EC2 instance**. The commands are the same; the VPS-only bits are
marked _(VPS)_.

---

## 0.1 Provision the host

- Ubuntu 22.04 or 24.04, **≥ 8 GB RAM** (LLM + OCR + Milvus need headroom),
  ≥ 20 GB disk, 2–4 vCPU.
- Options: a cheap VPS, AWS EC2 (`t3.large`+), or just your local machine.

> This project targets **x86_64**. ARM (e.g. Oracle/Graviton) works for most
> services but PaddleOCR and Milvus images are fiddlier there - stay on x86 while
> learning.

## 0.2 Create a non-root user _(VPS)_

Running as root is a bad habit and a real risk. Create a sudo user:

```bash
adduser deploy
usermod -aG sudo deploy        # allow sudo
usermod -aG docker deploy      # run docker without sudo (after Docker is installed)
```

## 0.3 SSH key auth, disable passwords _(VPS)_

From **your laptop**, copy your public key up, then log in as `deploy`:

```bash
ssh-copy-id deploy@YOUR_SERVER_IP
```

Then on the server, in `/etc/ssh/sshd_config` set:

```
PasswordAuthentication no
PermitRootLogin no
```

```bash
sudo systemctl restart ssh
```

**Why:** password logins get brute-forced constantly. Keys are effectively
unbruteforceable. Keep a second SSH session open while you test, so you don't
lock yourself out.

## 0.4 Firewall: only 22, 80, 443

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp     # SSH
sudo ufw allow 80/tcp     # HTTP (redirects to HTTPS)
sudo ufw allow 443/tcp    # HTTPS
sudo ufw enable
sudo ufw status verbose
```

**Why these three only:** the whole stack is reachable through Nginx on 80/443.
Everything else (Grafana, Prometheus, Milvus, …) is bound to `127.0.0.1` or kept
inside Docker, so it must *not* be open to the internet.

> ⚠️ Docker + ufw caveat: Docker writes its own iptables rules and can bypass ufw
> for **published** ports. We deliberately publish only `nginx` on 0.0.0.0; every
> other `ports:` entry is bound to `127.0.0.1`, so this isn't a problem here.
> Just don't change a port binding to `0.0.0.0` and assume ufw will block it.

## 0.5 Install Docker + Compose plugin

Official convenience script (fine for a personal box):

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER       # then log out/in so the group applies
docker --version
docker compose version              # the v2 plugin, note: "compose" not "compose-"
```

Verify your user can run Docker without sudo:

```bash
docker run --rm hello-world
```

> On the machine this repo was authored on, Docker 29 + Compose v2 were already
> present - `docker compose version` confirms the plugin is installed.

## 0.6 Get the project on the host

```bash
# if using git:
git clone <your-repo-url> ai-deployment-hub
cd ai-deployment-hub
# or scp the folder up from your laptop:
#   scp -r ai-deployment-hub deploy@SERVER:~/
```

Look around - understand the layout before running anything:

```bash
ls -R | head -50
```

## 0.7 One-time init

```bash
make init
```

This does three things (read `scripts/` to see exactly how):
1. `cp .env.example .env` - your config (versions, limits, passwords).
2. `gen-certs.sh` - a self-signed TLS cert in `nginx/certs/`.
3. `gen-htpasswd.sh admin admin` - basic-auth file for the gateway.

> **Change the defaults** for anything internet-facing: edit `.env`
> (`GRAFANA_ADMIN_PASSWORD`) and re-run `make htpasswd USER=you PASS=strongpass`.

---

## ✅ Phase 0 done when

- `docker run --rm hello-world` works without sudo.
- `ufw status` shows only 22/80/443 _(VPS)_.
- `make init` created `.env`, `nginx/certs/server.crt`, `nginx/.htpasswd`.

**Interview story to bank:** "I hardened the host (non-root user, key-only SSH,
ufw allowing only 22/80/443), then kept every service except the gateway off the
public interface by binding admin ports to localhost."

➡️ Next: [Phase 1 - LLM + OCR](01-llm-ocr.md)
