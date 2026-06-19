#!/usr/bin/env bash
# End-to-end smoke test through the Nginx gateway.
# Assumes the core stack is up, models are pulled, and basic-auth = admin/admin
# (override with AUTH env var, e.g. AUTH='-u myuser:mypass').
#
# -k accepts the self-signed certificate.
set -euo pipefail

BASE="${BASE:-https://localhost}"
AUTH="${AUTH:--u admin:admin}"
CURL=(curl -sk $AUTH)

echo "== Gateway health =="
"${CURL[@]}" "$BASE/healthz"; echo

echo "== OCR health =="
"${CURL[@]}" "$BASE/ocr/health"; echo

echo "== Search health =="
"${CURL[@]}" "$BASE/search/health"; echo

echo "== LLM generate (llama3.2:3b) =="
"${CURL[@]}" "$BASE/llm/api/generate" \
  -d '{"model":"llama3.2:3b","prompt":"Say hello in one short sentence.","stream":false}' \
  | head -c 400; echo

echo "== Index a document =="
"${CURL[@]}" -X POST "$BASE/search/index" \
  -H 'Content-Type: application/json' \
  -d '{"text":"The Eiffel Tower is located in Paris, France.","source":"smoke"}'; echo

echo "== Semantic query =="
"${CURL[@]}" -X POST "$BASE/search/query" \
  -H 'Content-Type: application/json' \
  -d '{"query":"Where is the Eiffel Tower?","top_k":3}'; echo

echo "All smoke checks issued."
