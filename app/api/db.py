"""Conexión a la base del proyecto (la misma de los scripts: .env en la raíz)."""

from __future__ import annotations

from pathlib import Path

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

ROOT = Path(__file__).resolve().parents[2]


def _env() -> dict[str, str]:
    values: dict[str, str] = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


def _conninfo() -> str:
    env = _env()
    # La contraseña va en kwargs del pool, nunca en un string que se pueda imprimir.
    return (f"host=127.0.0.1 port={env['POSTGRES_PORT']} dbname={env['POSTGRES_DB']} "
            f"user={env['POSTGRES_USER']} application_name=sismos_app_web")


pool = ConnectionPool(
    _conninfo(),
    kwargs={"password": _env()["POSTGRES_PASSWORD"], "row_factory": dict_row,
            "options": "-c statement_timeout=30000 -c TimeZone=UTC"},
    min_size=1,
    max_size=8,
    open=False,
)


def fetch_one(sql: str, params: dict | None = None) -> dict | None:
    with pool.connection() as connection:
        return connection.execute(sql, params or {}).fetchone()


def fetch_all(sql: str, params: dict | None = None) -> list[dict]:
    with pool.connection() as connection:
        return connection.execute(sql, params or {}).fetchall()
