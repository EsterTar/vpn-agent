"""
VPN Server Agent — thin FastAPI agent for xray management.
Backend sends a server config (list of inbound profiles) and user UUIDs;
agent owns config generation.

Launch:
    uvicorn main:app --host 0.0.0.0 --port 8080
"""

import logging
import threading
import traceback

from fastapi import Depends, FastAPI, HTTPException, Request, Security
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app import xray
from app.config_builder import build_config, extract_users
from app.profile import ServerConfig, read_profile, write_profile
from app.settings import settings

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("agent")

app = FastAPI(title="VPN Server Agent")
security = HTTPBearer()
_lock = threading.Lock()  # serialises all config read→write→reload cycles


@app.middleware("http")
async def log_requests(request: Request, call_next):
    log.info("%s %s", request.method, request.url.path)
    response = await call_next(request)
    log.info("%s %s → %d", request.method, request.url.path, response.status_code)
    return response


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    log.error(
        "Unhandled error on %s %s:\n%s",
        request.method,
        request.url.path,
        traceback.format_exc(),
    )
    return JSONResponse(status_code=500, content={"detail": str(exc)})


def verify_token(creds: HTTPAuthorizationCredentials = Security(security)) -> None:
    if creds.credentials != settings.agent_token:
        raise HTTPException(401, "Invalid token")


# ── Server config ─────────────────────────────────────────────────────────────


@app.put("/server", dependencies=[Depends(verify_token)])
def set_server(server_config: ServerConfig) -> dict:
    """Set server config (all inbound profiles). Preserves existing users."""
    log.info("set_server: inbounds=%s", [ib.inbound_tag for ib in server_config.inbounds])
    with _lock:
        old_xray = xray.read_config()
        old_config = read_profile()

        old_tags = (
            [ib.inbound_tag for ib in old_config.inbounds]
            if old_config
            else [ib.inbound_tag for ib in server_config.inbounds]
        )
        users = extract_users(old_xray, old_tags)
        log.info("set_server: preserving %d users", len(users))

        write_profile(server_config)
        _apply(build_config(server_config, users), old_xray)

    public_keys = {
        ib.inbound_tag: ib.reality.public_key
        for ib in server_config.inbounds
        if ib.reality
    }
    return {"status": "applied", "public_keys": public_keys}


@app.get("/server", dependencies=[Depends(verify_token)])
def get_server() -> ServerConfig:
    config = read_profile()
    if config is None:
        raise HTTPException(404, "Server config not set")
    return config


# ── Users ─────────────────────────────────────────────────────────────────────


class UserIn(BaseModel):
    id: str


@app.post("/users", dependencies=[Depends(verify_token)])
def add_user(user: UserIn) -> dict:
    """Add a user by UUID to all inbounds. Rebuilds and reloads xray config."""
    log.info("add_user: id=%s", user.id)
    with _lock:
        server_config = _require_config()
        old_xray = xray.read_config()
        tags = [ib.inbound_tag for ib in server_config.inbounds]
        users = extract_users(old_xray, tags)

        if user.id in users:
            raise HTTPException(409, f"User '{user.id}' already exists")

        _apply(build_config(server_config, [*users, user.id]), old_xray)
    return {"status": "added", "id": user.id}


@app.delete("/users/{uuid}", dependencies=[Depends(verify_token)])
def remove_user(uuid: str) -> dict:
    """Remove a user by UUID from all inbounds. Rebuilds and reloads xray config."""
    log.info("remove_user: uuid=%s", uuid)
    with _lock:
        server_config = _require_config()
        old_xray = xray.read_config()
        tags = [ib.inbound_tag for ib in server_config.inbounds]
        users = extract_users(old_xray, tags)

        if uuid not in users:
            raise HTTPException(404, f"User '{uuid}' not found")

        _apply(build_config(server_config, [u for u in users if u != uuid]), old_xray)
    return {"status": "removed", "id": uuid}


@app.get("/users", dependencies=[Depends(verify_token)])
def list_users() -> dict:
    server_config = _require_config()
    tags = [ib.inbound_tag for ib in server_config.inbounds]
    users = extract_users(xray.read_config(), tags)
    return {"users": users}


# ── Stats ─────────────────────────────────────────────────────────────────────


@app.get("/stats", dependencies=[Depends(verify_token)])
def get_stats(pattern: str = "") -> dict:
    """Query xray traffic stats. pattern — UUID or empty for all."""
    return xray.query_stats(pattern)


# ── System ────────────────────────────────────────────────────────────────────


@app.get("/health")
def health() -> dict:
    status = xray.service_status()
    return {"xray": "ok" if status == "active" else "down", "status": status}


@app.post("/restart", dependencies=[Depends(verify_token)])
def restart() -> dict:
    xray.restart_service()
    return {"status": "restarted"}


# ── Helpers ───────────────────────────────────────────────────────────────────


def _require_config() -> ServerConfig:
    config = read_profile()
    if config is None:
        raise HTTPException(409, "Server config not set — call PUT /server first")
    return config


def _apply(new: dict, old: dict) -> None:
    """Write → validate → reload. Rolls back to old on any failure."""
    xray.write_config(new)
    log.info("_apply: config written, validating")

    ok, err = xray.validate_config()
    if not ok:
        log.error("_apply: validation failed: %s", err)
        if old:
            xray.write_config(old)
            log.warning("_apply: rolled back to previous config")
        raise HTTPException(400, f"Config validation failed: {err}")

    log.info("_apply: validation ok, reloading xray")
    try:
        xray.reload_service()
        log.info("_apply: reload successful")
    except Exception as exc:
        log.error("_apply: reload failed: %s\n%s", exc, traceback.format_exc())
        if old:
            xray.write_config(old)
            try:
                xray.reload_service()
                log.warning("_apply: rolled back and reloaded previous config")
            except Exception:
                xray.restart_service()
                log.warning("_apply: rollback reload failed, restarted service")
        raise HTTPException(500, f"Service reload failed: {exc}") from exc
