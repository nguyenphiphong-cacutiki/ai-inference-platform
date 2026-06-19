# ---- OCR service image ----
# Base on a slim Python image. RapidOCR (ONNX Runtime + opencv) keeps this far
# smaller than a paddlepaddle-based image (~700MB vs ~3GB).
FROM python:3.10-slim

# PYTHONUNBUFFERED=1 -> logs appear immediately (no stdout buffering), important
# so `docker logs` shows output in real time.
ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# System libraries the OpenCV / ONNX Runtime stack needs at runtime:
#   libgl1, libglib2.0-0 -> OpenCV image ops
#   libgomp1             -> OpenMP runtime used by ONNX Runtime
#   curl                 -> used by the container HEALTHCHECK
WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Python deps first (separate layer = better build caching: deps only
# re-install when requirements.txt changes, not on every code edit).
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy application code.
COPY app ./app

# Warm up the engine at BUILD time so the models are extracted/initialised and
# the first request is fast. RapidOCR ships its models inside the wheel, so this
# needs no network access.
RUN python -c "from rapidocr_onnxruntime import RapidOCR; RapidOCR()"

EXPOSE 8000

# uvicorn is the ASGI server that actually runs FastAPI.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
