#!/bin/bash
# Install xray-core on Ubuntu/Debian.
# Idempotent — safe to run multiple times.
# Usage: sudo bash install-xray.sh <port> [port...]
# Example: sudo bash install-xray.sh 443 8443
set -euo pipefail

log() { echo "[INFO]  $*"; }
ok()  { echo "[OK]    $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null || die "Only Ubuntu/Debian supported"
[[ $# -ge 1 ]] || die "Usage: sudo bash $0 <port> [port...]"

# ── Port conflict check ───────────────────────────────────────────────────────

for port in "$@"; do
    pid=$(ss -tlnp "sport = :$port" 2>/dev/null \
        | awk 'NR>1 {print $6}' \
        | awk -F'pid=' '{print $2}' \
        | awk -F',' '{print $1}' \
        | head -1 || true)
    if [[ -n "$pid" ]]; then
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        [[ "$proc" == "xray" ]] \
            || die "Port $port is already used by $proc (pid $pid). Free it first."
        log "Port $port is used by xray — will reuse"
    fi
done

# ── Dependencies ──────────────────────────────────────────────────────────────

log "Installing system dependencies..."
apt-get update -qq
apt-get install -y -qq curl unzip
ok "System dependencies ready"

# ── Install xray ─────────────────────────────────────────────────────────────

if command -v xray &>/dev/null; then
    ok "xray already installed: $(xray version 2>/dev/null | head -1)"
else
    log "Downloading xray via official install script..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    command -v xray &>/dev/null || die "xray install failed — binary not found after install"
    ok "xray installed: $(xray version 2>/dev/null | head -1)"
fi

# ── Patch systemd service: add ExecReload for SIGHUP config reload ────────────

SERVICE_FILE="/etc/systemd/system/xray.service"
if [[ -f "$SERVICE_FILE" ]] && ! grep -q "ExecReload" "$SERVICE_FILE"; then
    log "Patching xray.service to support config reload (SIGHUP)..."
    sed -i '/^\[Service\]/a ExecReload=/bin/kill -HUP $MAINPID' "$SERVICE_FILE"
    systemctl daemon-reload
    ok "ExecReload added to xray.service"
else
    log "xray.service already has ExecReload or service file not found"
fi

# ── Directories ───────────────────────────────────────────────────────────────

CONF_DIR="/usr/local/etc/xray"
LOG_DIR="/var/log/xray"

mkdir -p "$CONF_DIR" "$LOG_DIR"
chmod 750 "$LOG_DIR"
ok "Directories ready: $CONF_DIR, $LOG_DIR"

# ── Placeholder config (only if not exists) ───────────────────────────────────

CONF="$CONF_DIR/config.json"
if [[ ! -f "$CONF" ]]; then
    log "Creating placeholder xray config..."
    cat > "$CONF" << 'EOF'
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": { "0": { "statsUserUplink": true, "statsUserDownlink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true }
  },
  "inbounds": [
    {
      "tag": "api-in",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" }
  ],
  "routing": {
    "rules": [
      { "inboundTag": ["api-in"], "outboundTag": "api" }
    ]
  }
}
EOF
    ok "Placeholder config created at $CONF"
else
    log "Config already exists at $CONF — skipping"
fi

# ── Validate config ───────────────────────────────────────────────────────────

log "Validating xray config..."
xray run -test -c "$CONF" >/dev/null 2>&1 \
    || die "Config validation failed. Fix manually: xray run -test -c $CONF"
ok "Config is valid"

# ── Firewall ──────────────────────────────────────────────────────────────────

if command -v ufw &>/dev/null; then
    log "Configuring firewall..."
    ufw allow 22/tcp 2>/dev/null || true
    for port in "$@"; do
        ufw allow "$port"/tcp 2>/dev/null || true
        ufw allow "$port"/udp 2>/dev/null || true
        ok "Opened port $port (tcp+udp)"
    done
    ufw --force enable
    ok "Firewall configured"
else
    log "ufw not found — skipping firewall setup"
fi

# ── Enable and start ──────────────────────────────────────────────────────────

log "Enabling and starting xray service..."
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2
if systemctl is-active --quiet xray; then
    ok "xray is running"
else
    echo "[ERROR] xray failed to start. Last 20 lines from journal:" >&2
    journalctl -u xray -n 20 --no-pager >&2
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== xray ready ==="
echo "Config:  $CONF"
echo "Logs:    $LOG_DIR/"
echo "Stats:   127.0.0.1:10085"
echo "Next:    sudo bash deploy/install-agent.sh"
