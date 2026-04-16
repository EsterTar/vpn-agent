"""Build a full xray config from a ServerProfile + list of user UUIDs."""

from .profile import RelayTarget, ServerProfile

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


def build_config(profile: ServerProfile, users: list[str]) -> dict:
    """Return a complete xray config dict ready to write to disk."""
    inbound: dict = {
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

    outbounds = _build_outbounds(profile)

    return {
        "log": {
            "access": "/var/log/xray/access.log",
            "error": "/var/log/xray/error.log",
            "loglevel": "warning",
        },
        **_STATS_SECTIONS,
        "inbounds": [_API_INBOUND, inbound],
        "outbounds": outbounds,
        "routing": {
            "rules": [
                {"inboundTag": ["api-in"], "outboundTag": "api"},
            ],
        },
    }


def extract_users(config: dict, inbound_tag: str) -> list[str]:
    """Extract user UUIDs from an existing xray config."""
    for inbound in config.get("inbounds", []):
        if inbound.get("tag") == inbound_tag:
            return [c["id"] for c in inbound.get("settings", {}).get("clients", [])]
    return []


# ── Outbounds ─────────────────────────────────────────────────────────────────


def _build_outbounds(profile: ServerProfile) -> list[dict]:
    if profile.relay is None:
        # Exit node: traffic goes directly to internet
        return [
            {"protocol": "freedom", "tag": "direct"},
            {"protocol": "blackhole", "tag": "block"},
        ]

    # Relay node: traffic forwarded to next hop
    return [
        _relay_outbound(profile.relay),
        {"protocol": "blackhole", "tag": "block"},
    ]


def _relay_outbound(relay: RelayTarget) -> dict:
    flow = "xtls-rprx-vision" if relay.protocol == "vless" and relay.security == "reality" else ""
    user: dict = {"id": relay.user_id, "encryption": "none"}
    if flow:
        user["flow"] = flow

    return {
        "tag": "direct",   # keep tag "direct" — routing rules stay unchanged
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


# ── Stream settings ───────────────────────────────────────────────────────────


def _inbound_stream_settings(profile: ServerProfile) -> dict:
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


# ── Clients ───────────────────────────────────────────────────────────────────


def _build_clients(profile: ServerProfile, users: list[str]) -> list[dict]:
    flow = "xtls-rprx-vision" if profile.protocol == "vless" and profile.security == "reality" else ""
    clients = []
    for uid in users:
        client: dict = {"id": uid, "email": uid}
        if flow:
            client["flow"] = flow
        clients.append(client)
    return clients
