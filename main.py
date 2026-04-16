"""
VPN Server Agent — thin FastAPI agent for xray management.
Backend sends a server profile and user UUIDs; agent owns config generation.

Launch:
    uvicorn main:app --host 0.0.0.0 --port 8080
"""

import threading

from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

from app import xray
from app.config_builder import build_config, extract_users
from app.profile import ServerProfile, read_profile, write_profile
from app.settings import settings

app = FastAPI(title="VPN Server Agent")
security = HTTPBearer()
_lock = threading.Lock()  # serialises all config read→write→reload cycles


def verify_token(creds: HTTPAuthorizationCredentials = Security(security)) -> None:
    if creds.credentials != settings.agent_token:
        raise HTTPException(401, "Invalid token")


# ── Server profile ────────────────────────────────────────────────────────────


@app.put("/server", dependencies=[Depends(verify_token)])
def set_server(profile: ServerProfile) -> dict:
    """Set server profile (protocol, port, keys). Preserves existing users."""
    with _lock:
        old_config = xray.read_config()
        old_profile = read_profile()
        users = extract_users(old_config, old_profile.inbound_tag if old_profile else profile.inbound_tag)

        write_profile(profile)
        _apply(build_config(profile, users), old_config)
    return {"status": "applied", "public_key": profile.reality.public_key if profile.reality else None}


@app.get("/server", dependencies=[Depends(verify_token)])
def get_server() -> ServerProfile:
    profile = read_profile()
    if profile is None:
        raise HTTPException(404, "Server profile not set")
    return profile


# ── Users ─────────────────────────────────────────────────────────────────────


class UserIn(BaseModel):
    id: str


@app.post("/users", dependencies=[Depends(verify_token)])
def add_user(user: UserIn) -> dict:
    """Add a user by UUID. Rebuilds and reloads xray config."""
    with _lock:
        profile = _require_profile()
        old_config = xray.read_config()
        users = extract_users(old_config, profile.inbound_tag)

        if user.id in users:
            raise HTTPException(409, f"User '{user.id}' already exists")

        _apply(build_config(profile, [*users, user.id]), old_config)
    return {"status": "added", "id": user.id}


@app.delete("/users/{uuid}", dependencies=[Depends(verify_token)])
def remove_user(uuid: str) -> dict:
    """Remove a user by UUID. Rebuilds and reloads xray config."""
    with _lock:
        profile = _require_profile()
        old_config = xray.read_config()
        users = extract_users(old_config, profile.inbound_tag)

        if uuid not in users:
            raise HTTPException(404, f"User '{uuid}' not found")

        _apply(build_config(profile, [u for u in users if u != uuid]), old_config)
    return {"status": "removed", "id": uuid}


@app.get("/users", dependencies=[Depends(verify_token)])
def list_users() -> dict:
    profile = _require_profile()
    users = extract_users(xray.read_config(), profile.inbound_tag)
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


def _require_profile() -> ServerProfile:
    profile = read_profile()
    if profile is None:
        raise HTTPException(409, "Server profile not set — call PUT /server first")
    return profile


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
