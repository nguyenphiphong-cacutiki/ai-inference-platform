#!/usr/bin/env bash
# Create/overwrite the Nginx basic-auth file (nginx/.htpasswd).
# Usage: ./scripts/gen-htpasswd.sh <user> <password>
# Uses openssl (apr1) so you don't need apache2-utils installed.
set -euo pipefail

USER="${1:-admin}"
PASS="${2:-admin}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/nginx/.htpasswd"

HASH="$(openssl passwd -apr1 "$PASS")"
echo "${USER}:${HASH}" > "$OUT"
chmod 644 "$OUT"
echo "Wrote $OUT for user '${USER}'."
echo "Use it like:  curl -k -u ${USER}:${PASS} https://localhost/ocr/health"
