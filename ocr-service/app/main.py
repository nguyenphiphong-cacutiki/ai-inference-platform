"""
OCR microservice
================
A thin FastAPI wrapper around RapidOCR (PP-OCR / PaddleOCR models on ONNX Runtime).

Design notes (why it looks like this):
- The OCR engine loads model weights into memory. We load it ONCE at startup
  (in the lifespan handler) and reuse the instance for every request. Loading
  per-request would be catastrophically slow.
- Endpoints are namespaced under /ocr so the path is identical whether you call
  the service directly (ocr-service:8000/ocr/health) or through the Nginx
  gateway (https://host/ocr/health). No surprising path rewriting.
- /metrics is exposed at the root because Prometheus scrapes the container
  directly on the internal network, not through the gateway.

Why RapidOCR instead of the `paddleocr` package: it serves the exact same PP-OCR
models, but through ONNX Runtime instead of the paddlepaddle native library,
which crashes ("free(): invalid size") on recent glibc inside slim images.
"""

import io
import time
import logging
from contextlib import asynccontextmanager

import numpy as np
from PIL import Image
from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ocr-service")

# --- Prometheus metrics --------------------------------------------------------
# Counter: monotonically increasing total. Histogram: distribution of durations.
REQUESTS = Counter(
    "ocr_requests_total", "Total OCR requests", ["endpoint", "status"]
)
LATENCY = Histogram(
    "ocr_request_duration_seconds", "OCR request latency in seconds", ["endpoint"]
)
DETECTIONS = Histogram(
    "ocr_text_regions_detected",
    "Number of text regions detected per image",
    buckets=(0, 1, 2, 5, 10, 20, 50, 100),
)

# The OCR engine is created at startup and stored here.
_state = {"ocr": None}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Runs once on startup / shutdown. Load the heavy model here."""
    from rapidocr_onnxruntime import RapidOCR

    log.info("Loading RapidOCR (PP-OCR / ONNX) models...")
    # RapidOCR bundles detection + angle-classification + recognition models and
    # loads them from inside the installed package (no network needed).
    _state["ocr"] = RapidOCR()
    log.info("OCR engine loaded and ready.")
    yield
    _state["ocr"] = None


app = FastAPI(title="OCR Service", version="1.0.0", lifespan=lifespan)


@app.get("/ocr/health")
def health():
    """Liveness/readiness probe. 'ok' only once the model is loaded."""
    ready = _state["ocr"] is not None
    return JSONResponse(
        status_code=200 if ready else 503,
        content={"status": "ok" if ready else "loading", "model_loaded": ready},
    )


@app.get("/metrics")
def metrics():
    """Prometheus scrape endpoint."""
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/ocr/run")
async def run_ocr(file: UploadFile = File(...)):
    """
    Accept an image file (multipart/form-data, field name 'file') and return the
    recognized text plus per-line bounding boxes and confidence scores.
    """
    endpoint = "/ocr/run"
    start = time.perf_counter()

    if _state["ocr"] is None:
        REQUESTS.labels(endpoint, "503").inc()
        raise HTTPException(status_code=503, detail="OCR model not loaded yet")

    # Read the uploaded bytes and decode to an RGB image.
    raw = await file.read()
    try:
        image = Image.open(io.BytesIO(raw)).convert("RGB")
    except Exception:
        REQUESTS.labels(endpoint, "400").inc()
        raise HTTPException(status_code=400, detail="Invalid or unsupported image file")

    img_array = np.array(image)

    # RapidOCR returns (result, elapse). `result` is None when nothing is found,
    # otherwise a list of [box, text, confidence] where box is 4 [x, y] points.
    result, _elapse = _state["ocr"](img_array)

    lines = []
    full_text_parts = []
    for item in result or []:
        box, text, confidence = item
        lines.append(
            {
                "text": text,
                "confidence": round(float(confidence), 4),
                "box": [[float(x), float(y)] for x, y in box],
            }
        )
        full_text_parts.append(text)

    duration = time.perf_counter() - start
    LATENCY.labels(endpoint).observe(duration)
    DETECTIONS.observe(len(lines))
    REQUESTS.labels(endpoint, "200").inc()
    log.info("OCR ok: %d regions in %.3fs (%s)", len(lines), duration, file.filename)

    return {
        "filename": file.filename,
        "num_regions": len(lines),
        "text": "\n".join(full_text_parts),
        "lines": lines,
        "duration_seconds": round(duration, 3),
    }
