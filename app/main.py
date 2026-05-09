from fastapi import FastAPI, HTTPException
from fastapi.responses import RedirectResponse
from pydantic import BaseModel
import redis
import os
import hashlib
import time
import logging
import json

class JSONFormatter(logging.Formatter):
    def format(self, record):
        return json.dumps({
            "time": self.formatTime(record),
            "level": record.levelname,
            "message": record.getMessage(),
            "service": "url-shortener"
        })

handler = logging.StreamHandler()
handler.setFormatter(JSONFormatter())
logger = logging.getLogger("app")
logger.addHandler(handler)
logger.setLevel(logging.INFO)


app = FastAPI(title="URL Shortener")

# -------------------------
# Secret Reader
# -------------------------
def read_secret(name: str, fallback_env: str = None) -> str:
    """Read secret from file first, fall back to env var."""
    secret_path = f"/app/secrets/{name}"
    if os.path.exists(secret_path):
        with open(secret_path) as f:
            return f.read().strip()
    if fallback_env:
        return os.getenv(fallback_env, "")
    return ""

# -------------------------
# Redis Client (with timeouts)
# -------------------------
password = read_secret("redis_password")

if password:
    password = password.strip()   # 🔥 CRITICAL FIX

r = redis.Redis(
    host=os.getenv("REDIS_HOST", "localhost"),
    port=int(os.getenv("REDIS_PORT", 6379)),
    password=password if password else None,
    decode_responses=True,
    socket_connect_timeout=2,
    socket_timeout=2
)
# -------------------------
# Models
# -------------------------
class URLRequest(BaseModel):
    url: str

# -------------------------
# Utility
# -------------------------
def make_short_code(url: str) -> str:
    unique = f"{url}{time.time()}"
    return hashlib.md5(unique.encode()).hexdigest()[:6]

# -------------------------
# Health Endpoints
# -------------------------

# Liveness: MUST always succeed
@app.get("/health")
def health():
    return {"status": "ok"}

# Readiness: check dependencies (Redis)
@app.get("/ready")
def ready():
    try:
        r.ping()
        return {"status": "ready"}
    except Exception:
        raise HTTPException(status_code=503, detail="Redis not ready")

# -------------------------
# Core APIs
# -------------------------
@app.post("/shorten")
def shorten(req: URLRequest):
    code = make_short_code(req.url)
    r.hset(f"url:{code}", mapping={"url": req.url, "clicks": 0})

    logger.info(json.dumps({
        "event": "url_shortened",
        "code": code,
        "url": req.url
    }))

    return {"short_code": code, "short_url": f"/r/{code}"}

@app.get("/r/{code}")
def redirect(code: str):
    data = r.hgetall(f"url:{code}")
    if not data:
        raise HTTPException(status_code=404, detail="Short URL not found")

    r.hincrby(f"url:{code}", "clicks", 1)
    return RedirectResponse(url=data["url"])

@app.get("/stats/{code}")
def stats(code: str):
    data = r.hgetall(f"url:{code}")
    if not data:
        raise HTTPException(status_code=404, detail="Short URL not found")

    return {
        "short_code": code,
        "url": data["url"],
        "clicks": data["clicks"]
    }

@app.get("/")
def root():
    return {"message": "URL Shortener running", "docs": "/docs"}