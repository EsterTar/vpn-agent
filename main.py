"""
VPN Server Agent — thin FastAPI agent for xray management.
Backend sends a server config (list of inbound profiles) and user UUIDs;
agent owns config generation.

Launch:
    uvicorn main:app --host 0.0.0.0 --port 8080
"""

import threading

from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app import xray
from app.config_builder import build_config, extract_users
from app.profile import ServerConfig, read_profile, write_profile
from app.settings import settings

app = FastAPI(title="VPN Server Agent")
security = HTTPBearer()
_lock = threading.Lock()  # serialises all config read→write→reload cycles


def verify_token(creds: HTTPAuthorizationCredentials = Security(security)) -> None:
    if creds.credentials != settings.agent_token:
        raise HTTPException(401, "Invalid token")


# ── Server config ─────────────────────────────────────────────────────────────


@app.put("/server", dependencies=[Depends(verify_token)])
def set_server(server_config: ServerConfig) -> dict:
    """Set server config (all inbound profiles). Preserves existing users."""
    with _lock:
        old_xray = xray.read_config()
        old_config = read_profile()

        old_tags = (
            [ib.inbound_tag for ib in old_config.inbounds]
            if old_config
            else [ib.inbound_tag for ib in server_config.inbounds]
        )
        users = extract_users(old_xray, old_tags)

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

    ok, err = xray.validate_config()
    if not ok:
        if old:
            xray.write_config(old)
        raise HTTPException(400, f"Config validation failed: {err}")

    try:
        xray.reload_service()
    except Exception as exc:
        if old:
            xray.write_config(old)
            try:
                xray.reload_service()
            except Exception:
                xray.restart_service()
        raise HTTPException(500, f"Service reload failed: {exc}") from exc
