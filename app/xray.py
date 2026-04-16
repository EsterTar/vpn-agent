"""xray process control: validate, reload, restart, stats."""

import json
import subprocess
from pathlib import Path

from .settings import settings


def read_config() -> dict:
    path = Path(settings.xray_config_path)
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def write_config(config: dict) -> None:
    path = Path(settings.xray_config_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        Path(f"{path}.bak").write_text(path.read_text())
    path.write_text(json.dumps(config, indent=2, ensure_ascii=False))


def validate_config() -> tuple[bool, str]:
    """Run xray -test. Returns (ok, error_message)."""
    result = subprocess.run(
        ["xray", "run", "-test", "-c", settings.xray_config_path],
        capture_output=True,
        text=True,
    )
    output = (result.stderr or result.stdout).strip()
    return result.returncode == 0, output


def reload_service() -> None:
    """Send SIGHUP — xray reloads config without dropping connections."""
    subprocess.run(
        ["systemctl", "reload", settings.xray_service],
        check=True,
        capture_output=True,
    )


def restart_service() -> None:
    subprocess.run(
        ["systemctl", "restart", settings.xray_service],
        check=True,
        capture_output=True,
    )


def service_status() -> str:
    """Returns systemd active state: 'active', 'inactive', 'failed', etc."""
    result = subprocess.run(
        ["systemctl", "is-active", settings.xray_service],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def query_stats(pattern: str = "") -> dict:
    """Query xray traffic stats. Requires stats+api sections in xray config."""
    result = subprocess.run(
        [
            "xray", "api", "statsquery",
            f"-s={settings.xray_api_address}",
            f"-pattern={pattern}",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return {"error": result.stderr.strip() or "stats API unavailable"}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"raw": result.stdout.strip()}
