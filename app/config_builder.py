"""Build a full xray config from a ServerConfig + list of user UUIDs."""

from .profile import InboundProfile, RelayTarget, ServerConfig

_API_INBOUND = {
    "tag": "api-in",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"},
}

_STATS_SECTIONS = {
    "stats": {},
    "api": {
        "tag": "api",
        "services": ["StatsService"],
    },
    "policy": {
        "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
        "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
    },
}


def build_config(server_config: ServerConfig, users: list[str]) -> dict:
    """Return a complete xray config dict ready to write to disk."""
    inbounds = [_API_INBOUND]
    outbounds = [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "block"},
    ]
    routing_rules: list[dict] = [
        {"inboundTag": ["api-in"], "outboundTag": "api"},
    ]

    for profile in server_config.inbounds:
        inbounds.append(_build_inbound(profile, users))

        if profile.relay is not None:
            relay_tag = f"relay-{profile.inbound_tag}"
            outbounds.append(_relay_outbound(profile.relay, relay_tag))
            routing_rules.append({
                "inboundTag": [profile.inbound_tag],
                "outboundTag": relay_tag,
            })

    return {
        "log": {
            "access": "/var/log/xray/access.log",
            "error": "/var/log/xray/error.log",
            "loglevel": "warning",
        },
        **_STATS_SECTIONS,
        "inbounds": inbounds,
        "outbounds": outbounds,
        "routing": {"rules": routing_rules},
    }


def extract_users(config: dict, inbound_tags: list[str]) -> list[str]:
    """Extract unique user UUIDs from the given inbounds in an existing xray config."""
    tags = set(inbound_tags)
    seen: set[str] = set()
    users: list[str] = []
    for inbound in config.get("inbounds", []):
        if inbound.get("tag") in tags:
            for client in inbound.get("settings", {}).get("clients", []):
                uid = client["id"]
                if uid not in seen:
                    seen.add(uid)
                    users.append(uid)
    return users


# ── Inbound ───────────────────────────────────────────────────────────────────


def _build_inbound(profile: InboundProfile, users: list[str]) -> dict:
    return {
        "tag": profile.inbound_tag,
        "listen": "0.0.0.0",
        "port": profile.port,
        "protocol": profile.protocol,
        "settings": {
            "clients": _build_clients(profile, users),
            "decryption": "none",
        },
        "streamSettings": _inbound_stream_settings(profile),
    }


def _build_clients(profile: InboundProfile, users: list[str]) -> list[dict]:
    flow = "xtls-rprx-vision" if profile.protocol == "vless" and profile.security == "reality" else ""
    clients = []
    for uid in users:
        client: dict = {"id": uid, "email": uid}
        if flow:
            client["flow"] = flow
        clients.append(client)
    return clients


def _inbound_stream_settings(profile: InboundProfile) -> dict:
    """realitySettings for inbound (server side): plural forms, privateKey, dest."""
    ss: dict = {"network": profile.transport}

    if profile.security == "reality":
        assert profile.reality is not None, "reality settings required for security=reality"
        r = profile.reality
        ss["security"] = "reality"
        ss["realitySettings"] = {
            "show": False,
            "dest": r.dest,
            "serverNames": r.server_names,
            "privateKey": r.private_key,
            "shortIds": r.short_ids,
        }
    elif profile.security == "tls":
        ss["security"] = "tls"

    return ss


# ── Outbounds ─────────────────────────────────────────────────────────────────


def _relay_outbound(relay: RelayTarget, tag: str) -> dict:
    flow = "xtls-rprx-vision" if relay.protocol == "vless" and relay.security == "reality" else ""
    user: dict = {"id": relay.user_id, "encryption": "none"}
    if flow:
        user["flow"] = flow

    return {
        "tag": tag,
        "protocol": relay.protocol,
        "settings": {
            "vnext": [{
                "address": relay.address,
                "port": relay.port,
                "users": [user],
            }]
        },
        "streamSettings": _outbound_stream_settings(relay),
    }


def _outbound_stream_settings(relay: RelayTarget) -> dict:
    """realitySettings for outbound (client side): singular forms, publicKey, fingerprint."""
    ss: dict = {"network": relay.transport}

    if relay.security == "reality":
        assert relay.reality is not None, "reality settings required for security=reality"
        r = relay.reality
        ss["security"] = "reality"
        ss["realitySettings"] = {
            "serverName": r.server_name,
            "fingerprint": r.fingerprint,
            "publicKey": r.public_key,
            "shortId": r.short_id,
        }
    elif relay.security == "tls":
        ss["security"] = "tls"

    return ss
