"""Server profile: protocol/transport/security settings stored on disk."""

from pathlib import Path
from typing import Literal

from pydantic import BaseModel

from .settings import settings


# ── Inbound Reality (сервер принимает соединения) ─────────────────────────────

class RealitySettings(BaseModel):
    dest: str                  # "yahoo.com:443" — куда форвардить handshake
    server_names: list[str]    # допустимые SNI от клиента
    private_key: str
    public_key: str            # отдаётся бэкенду для клиентских конфигов
    short_ids: list[str]


# ── Outbound Reality (сервер подключается к следующему хопу) ──────────────────

class RealityClientSettings(BaseModel):
    server_name: str           # SNI — один, не список
    public_key: str            # public key следующего хопа
    short_id: str              # один short_id для соединения
    fingerprint: str = "chrome"


# ── Relay target (следующий хоп в цепочке) ───────────────────────────────────

class RelayTarget(BaseModel):
    address: str
    port: int
    user_id: str               # служебный UUID — не из списка /users
    protocol: Literal["vless"] = "vless"
    transport: Literal["tcp", "ws", "grpc"] = "tcp"
    security: Literal["reality", "tls", "none"] = "reality"
    reality: RealityClientSettings | None = None


# ── Профиль сервера ───────────────────────────────────────────────────────────

class ServerProfile(BaseModel):
    protocol: Literal["vless"] = "vless"
    port: int
    transport: Literal["tcp", "ws", "grpc"] = "tcp"
    security: Literal["reality", "tls", "none"] = "reality"
    inbound_tag: str = "vless-in"
    reality: RealitySettings | None = None
    relay: RelayTarget | None = None  # None = exit-нода (freedom)


def read_profile() -> ServerProfile | None:
    path = Path(settings.profile_path)
    if not path.exists():
        return None
    return ServerProfile.model_validate_json(path.read_text())


def write_profile(profile: ServerProfile) -> None:
    path = Path(settings.profile_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(profile.model_dump_json(indent=2))
