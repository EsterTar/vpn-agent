#!/bin/bash
# Migration: sing-box → xray
# Reads existing sing-box config, converts clients, installs xray,
# updates agent in-place (token preserved), then does atomic cutover.
#
# Downtime: only the sing-box stop → xray start window (~2-3 sec).
#
# Usage: sudo bash deploy/migrate-singbox-to-xray.sh
# Run from repo root.
set -euo pipefail

SINGBOX_CONF="/etc/sing-box/config.json"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
XRAY_LOG_DIR="/var/log/xray"
INSTALL_DIR="/data/docker/agent"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONVERTED_CONF="/tmp/xray-converted.json"

log() { echo "[INFO]  $*"; }
ok()  { echo "[OK]    $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }
sep() { echo ""; echo "────────────────────────────────────────"; echo "  $*"; echo "────────────────────────────────────────"; }

# ── Validate ──────────────────────────────────────────────────────────────────

sep "Pre-flight checks"

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null || die "Only Ubuntu/Debian supported"
[[ -f "$SINGBOX_CONF" ]] || die "sing-box config not found at $SINGBOX_CONF"
[[ -f "$REPO_DIR/main.py" ]] || die "main.py not found in $REPO_DIR. Run from repo root."
[[ -f "$INSTALL_DIR/server-agent.env" ]] || die "Agent env not found at $INSTALL_DIR/server-agent.env"

command -v python3 &>/dev/null || die "python3 not found"

ok "Pre-flight passed"
log "sing-box config: $SINGBOX_CONF"
log "Agent dir:       $INSTALL_DIR"

# ── Read existing token ───────────────────────────────────────────────────────

sep "Reading existing agent token"

AGENT_TOKEN=$(awk -F"'" '/AGENT_TOKEN/ {print $2}' "$INSTALL_DIR/server-agent.env")
[[ -n "$AGENT_TOKEN" ]] || die "Could not read AGENT_TOKEN from $INSTALL_DIR/server-agent.env"
ok "Token preserved: ${AGENT_TOKEN:0:8}..."

# ── Install xray (sing-box stays running) ─────────────────────────────────────

sep "Installing xray"

apt-get update -qq
apt-get install -y -qq curl unzip
ok "System dependencies ready"

if command -v xray &>/dev/null; then
    ok "xray already installed: $(xray version 2>/dev/null | head -1)"
else
    log "Downloading xray via official install script..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    command -v xray &>/dev/null || die "xray install failed — binary not found"
    ok "xray installed: $(xray version 2>/dev/null | head -1)"
fi

# Patch xray.service to support config reload via SIGHUP
SERVICE_FILE="/etc/systemd/system/xray.service"
if [[ -f "$SERVICE_FILE" ]] && ! grep -q "ExecReload" "$SERVICE_FILE"; then
    sed -i '/^\[Service\]/a ExecReload=/bin/kill -HUP $MAINPID' "$SERVICE_FILE"
    systemctl daemon-reload
    ok "ExecReload patched into xray.service"
fi

mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"
chmod 750 "$XRAY_LOG_DIR"

# ── Convert sing-box config → xray config ─────────────────────────────────────

sep "Converting sing-box config to xray format"

python3 - "$SINGBOX_CONF" "$CONVERTED_CONF" << 'PYEOF'
import json
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]

with open(src_path) as f:
    sb = json.load(f)

xray_inbounds = []

# Stats API listener (localhost only)
xray_inbounds.append({
    "tag": "api-in",
    "listen": "127.0.0.1",
    "port": 10085,
    "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"},
})

converted = 0
skipped = []

for ib in sb.get("inbounds", []):
    ib_type = ib.get("type", "")

    if ib_type != "vless":
        skipped.append(f"{ib.get('tag','?')} (type={ib_type})")
        continue

    tag      = ib.get("tag", "vless-in")
    port     = ib.get("listen_port", 443)
    users    = ib.get("users", [])
    tls      = ib.get("tls", {})
    reality  = tls.get("reality", {})
    hs       = reality.get("handshake", {})

    clients = [
        {
            "id":    u["uuid"],
            "email": u.get("name") or u["uuid"][:8],
            "flow":  "xtls-rprx-vision",
        }
        for u in users
    ]

    dest_host  = hs.get("server", "")
    dest_port  = hs.get("server_port", 443)
    sni        = tls.get("server_name") or dest_host
    private_key = reality.get("private_key", "")
    short_ids  = reality.get("short_id", [])

    if not dest_host:
        print(f"[WARN] inbound '{tag}': no Reality handshake host, skipping", file=sys.stderr)
        skipped.append(f"{tag} (no handshake host)")
        continue

    xray_inbounds.append({
        "tag":      tag,
        "listen":   "0.0.0.0",
        "port":     port,
        "protocol": "vless",
        "settings": {
            "clients":    clients,
            "decryption": "none",
        },
        "streamSettings": {
            "network":  "tcp",
            "security": "reality",
            "realitySettings": {
                "show":        False,
                "dest":        f"{dest_host}:{dest_port}",
                "serverNames": [sni],
                "privateKey":  private_key,
                "shortIds":    short_ids,
            },
        },
    })
    converted += 1
    print(f"[OK]    Converted inbound '{tag}': {len(clients)} client(s) on port {port}", file=sys.stderr)

if skipped:
    print(f"[WARN]  Skipped inbounds: {', '.join(skipped)}", file=sys.stderr)

xray_config = {
    "log": {
        "access":   "/var/log/xray/access.log",
        "error":    "/var/log/xray/error.log",
        "loglevel": "warning",
    },
    "stats": {},
    "api": {
        "tag":      "api",
        "services": ["StatsService"],
    },
    "policy": {
        "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
        "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
    },
    "inbounds": xray_inbounds,
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
    ],
    "routing": {
        "rules": [
            {"inboundTag": ["api-in"], "outboundTag": "api"},
        ],
    },
}

with open(dst_path, "w") as f:
    json.dump(xray_config, f, indent=2, ensure_ascii=False)

if converted == 0:
    print("[ERROR] No VLESS inbounds were converted — aborting", file=sys.stderr)
    sys.exit(1)

print(f"[OK]    Conversion done: {converted} inbound(s) written to {dst_path}", file=sys.stderr)
PYEOF

ok "Config converted to $CONVERTED_CONF"

# ── Validate converted config ─────────────────────────────────────────────────

sep "Validating converted xray config"

# Write to final location for validation (xray validates from that path)
cp "$CONVERTED_CONF" "$XRAY_CONF"
xray run -test -c "$XRAY_CONF" >/dev/null 2>&1 \
    || { echo "[ERROR] xray config validation failed:"; xray run -test -c "$XRAY_CONF"; exit 1; }
ok "Config is valid"

# ── Update agent files ────────────────────────────────────────────────────────

sep "Updating agent code"

if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    cp "$REPO_DIR/main.py"          "$INSTALL_DIR/main.py"
    cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
    cp -r "$REPO_DIR/app"           "$INSTALL_DIR/app"
    ok "Agent files copied from $REPO_DIR"
else
    ok "Repo and install dir are the same — skipping file copy"
fi

log "Updating Python dependencies..."
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade -r "$INSTALL_DIR/requirements.txt"
ok "Python dependencies updated"

# Update env: replace SINGBOX_* keys, preserve token, add XRAY_API_ADDRESS
cat > "$INSTALL_DIR/server-agent.env" << EOF
AGENT_TOKEN='${AGENT_TOKEN}'
XRAY_CONFIG_PATH='${XRAY_CONF}'
XRAY_SERVICE='xray'
XRAY_API_ADDRESS='127.0.0.1:10085'
EOF
ok "server-agent.env updated (token preserved)"

# ── Cutover: stop sing-box, start xray ───────────────────────────────────────

sep "Cutover (brief downtime starts here)"

log "Stopping sing-box..."
systemctl stop sing-box || true
systemctl disable sing-box || true
ok "sing-box stopped"

log "Starting xray..."
systemctl enable xray
systemctl start xray

sleep 2
if systemctl is-active --quiet xray; then
    ok "xray is running"
else
    echo "[ERROR] xray failed to start. Attempting to restore sing-box..." >&2
    systemctl start sing-box || true
    journalctl -u xray -n 30 --no-pager >&2
    die "Cutover failed — sing-box restored. Fix xray config and retry."
fi

# ── Restart agent ─────────────────────────────────────────────────────────────

sep "Restarting agent"

systemctl restart vpn-agent

sleep 2
if ! systemctl is-active --quiet vpn-agent; then
    journalctl -u vpn-agent -n 20 --no-pager >&2
    die "Agent failed to restart. Check logs above."
fi

HEALTH=$(curl -sf --connect-timeout 5 "http://127.0.0.1:8080/health" 2>/dev/null || true)
if [[ -n "$HEALTH" ]]; then
    ok "Health check: $HEALTH"
else
    log "WARNING: health endpoint did not respond — agent may still be starting"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

sep "Migration complete"

echo "xray config:  $XRAY_CONF"
echo "xray logs:    $XRAY_LOG_DIR/"
echo "Agent:        $INSTALL_DIR"
echo "Token:        ${AGENT_TOKEN}"
echo ""
echo "Verify:"
echo "  systemctl status xray"
echo "  systemctl status vpn-agent"
echo "  journalctl -u xray -f"
