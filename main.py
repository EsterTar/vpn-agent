"""
Thin Server Agent — accepts a complete sing-box config, writes it, restarts.
Knows nothing about protocols. Launch:
    uvicorn server-agent.main:app --host 0.0.0.0 --port 8080
"""

import json
import subprocess
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    agent_token: str
    singbox_config_path: str = "/etc/sing-box/config.json"
    singbox_service: str = "sing-box"

    model_config = {"env_file": "server-agent.env"}


settings = Settings()
app = FastAPI(title="VPN Server Agent")
security = HTTPBearer()


def verify_token(creds: HTTPAuthorizationCredentials = Security(security)):
    if creds.credentials != settings.agent_token:
        raise HTTPException(401, "Invalid token")


def _read_config() -> dict:
    path = Path(settings.singbox_config_path)
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def _write_config(config: dict):
    path = Path(settings.singbox_config_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Backup before writing
    if path.exists():
        Path(f"{path}.bak").write_text(path.read_text())
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False))


def _check_config() -> tuple[bool, str]:
    """Validate config with sing-box check."""
    result = subprocess.run(
        [settings.singbox_service, "check", "-c", settings.singbox_config_path],
        capture_output=True, text=True,
    )
    return result.returncode == 0, result.stderr


def _restart_service():
    subprocess.run(
        ["systemctl", "restart", settings.singbox_service],
        check=True, capture_output=True,
    )


@app.put("/config", dependencies=[Depends(verify_token)])
def push_config(config: dict):
    backup_path = Path(f"{settings.singbox_config_path}.bak")
    old_config = _read_config()

    _write_config(config)

    ok, err = _check_config()
    if not ok:
        # Rollback to previous config
        if old_config:
            _write_config(old_config)
        raise HTTPException(400, f"Invalid config: {err}")

    _restart_service()
    return {"status": "applied"}


@app.get("/config", dependencies=[Depends(verify_token)])
def get_config():
    return _read_config()


@app.get("/health")
def health():
    result = subprocess.run(
        ["systemctl", "is-active", settings.singbox_service],
        capture_output=True, text=True,
    )
    active = result.stdout.strip() == "active"
    return {"singbox": "ok" if active else "down"}


@app.post("/restart", dependencies=[Depends(verify_token)])
def restart():
    _restart_service()
    return {"status": "restarted"}
