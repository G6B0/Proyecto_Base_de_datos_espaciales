"""Sismos Chile · Observatorio — API y servidor de la interfaz.

    app\\.venv\\Scripts\\python -m uvicorn app.api.main:app --host 127.0.0.1 --port 8000

Sirve la API (/api/..., /tiles/...) y los archivos de app/web/ en la raíz.
Requiere la base local encendida (scripts/start_local_postgis.ps1).
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from .db import fetch_one, pool
from .routes import areas, events

WEB = Path(__file__).resolve().parents[1] / "web"


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True, timeout=15)
    yield
    pool.close()


app = FastAPI(title="Sismos Chile · Observatorio", lifespan=lifespan)
app.include_router(events.router)
app.include_router(areas.router)


@app.get("/api/health")
def health():
    row = fetch_one("SELECT postgis_lib_version() AS postgis, current_setting('server_version') AS postgres")
    return {"status": "ok", **row}


# Al final: todo lo que no es API se busca en app/web/ (index.html en "/").
app.mount("/", StaticFiles(directory=WEB, html=True), name="web")
