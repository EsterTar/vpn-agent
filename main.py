"""
VPN Server Agent — thin FastAPI agent for xray management.
Accepts xray config via API, validates, applies via SIGHUP reload.
No protocol knowledge — all logic lives in the calling backend.

Launch:
    uvicorn main:app --host 0.0.0.0 --port 8080
"""

import copy
import threading

from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app import xray
from app.settings import settings

app = FastAPI(title="VPN Server Agent")
security = HTTPBearer()
_lock = threading.Lock()  # serialises all config read→write→reload cycles


def verify_token(creds: HTTPAuthorizationCredentials = Security(security)) -> None:
    if creds.credentials != settings.agent_token:
        raise HTTPException(401, "Invalid token")


# ── Config ────────────────────────────────────────────────────────────────────


@app.put("/config", dependencies=[Depends(verify_token)])
def push_config(config: dict) -> dict:
    """Replace full xray config. Validates before applying; rolls back on failure."""
    with _lock:
        old = xray.read_config()
        _apply_config_change(config, old)
    return {"status": "applied"}


@app.get("/config", dependencies=[Depends(verify_token)])
def get_config() -> dict:
    return xray.read_config()


# ── Clients ───────────────────────────────────────────────────────────────────


@app.post("/clients/{inbound_tag}", dependencies=[Depends(verify_token)])
def add_client(inbound_tag: str, client: dict) -> dict:
    """Add a client to an inbound. Reloads config without dropping connections."""
    with _lock:
        old = xray.read_config()
        new = copy.deepcopy(old)

        inbound = _find_inbound(new, inbound_tag)
        clients: list = inbound.setdefault("settings", {}).setdefault("clients", [])

        if any(c.get("email") == client.get("email") for c in clients):
            raise HTTPException(409, f"Client '{client.get('email')}' already exists in '{inbound_tag}'")

        clients.append(client)
        _apply_config_change(new, old)
    return {"status": "added", "inbound": inbound_tag}


@app.delete("/clients/{inbound_tag}/{email}", dependencies=[Depends(verify_token)])
def remove_client(inbound_tag: str, email: str) -> dict:
    """Remove a client from an inbound. Reloads config without dropping connections."""
    with _lock:
        old = xray.read_config()
        new = copy.deepcopy(old)

        inbound = _find_inbound(new, inbound_tag)
        clients: list = inbound.get("settings", {}).get("clients", [])
        filtered = [c for c in clients if c.get("email") != email]

        if len(filtered) == len(clients):
            raise HTTPException(404, f"Client '{email}' not found in '{inbound_tag}'")

        inbound["settings"]["clients"] = filtered
        _apply_config_change(new, old)
    return {"status": "removed", "inbound": inbound_tag, "email": email}


# ── Stats ─────────────────────────────────────────────────────────────────────


@app.get("/stats", dependencies=[Depends(verify_token)])
def get_stats(pattern: str = "") -> dict:
    """Query xray traffic stats. Requires stats+api sections in the xray config."""
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


def _find_inbound(config: dict, tag: str) -> dict:
    for inbound in config.get("inbounds", []):
        if inbound.get("tag") == tag:
            return inbound
    raise HTTPException(404, f"Inbound '{tag}' not found")


def _apply_config_change(new: dict, old: dict) -> None:
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
