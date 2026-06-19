#!/usr/bin/env bash
# Pull the LLM + embedding models into the running Ollama container.
# Run this once after `docker compose up -d ollama` (models persist in the
# ollama_data volume, so you only do it again if you delete that volume).
set -euo pipefail

cd "$(dirname "$0")/.."

# Defaults match .env; override via environment if you like.
LLM_MODEL="${LLM_MODEL:-llama3.2:3b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"

echo "Pulling LLM model: ${LLM_MODEL}"
docker compose exec -T ollama ollama pull "${LLM_MODEL}"

echo "Pulling embedding model: ${EMBED_MODEL}"
docker compose exec -T ollama ollama pull "${EMBED_MODEL}"

echo "Done. Installed models:"
docker compose exec -T ollama ollama list
