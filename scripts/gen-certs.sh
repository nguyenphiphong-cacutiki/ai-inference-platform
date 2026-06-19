#!/usr/bin/env bash
# Generate a self-signed TLS certificate for Nginx (local/dev use).
# For a real domain on a VPS, replace these with Let's Encrypt certs
# (see docs/02-nginx-gateway.md).
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/nginx/certs"
CN="${1:-localhost}"

mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$CERT_DIR/server.key" \
  -out    "$CERT_DIR/server.crt" \
  -days 365 \
  -subj "/C=US/ST=Dev/L=Dev/O=AIHub/CN=${CN}" \
  -addext "subjectAltName=DNS:${CN},DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/server.key"
echo "Self-signed cert written to $CERT_DIR (CN=${CN})."
