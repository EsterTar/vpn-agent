#!/bin/bash
# Install the VPN server agent as a systemd service.
# Idempotent — safe to run multiple times. Preserves existing token.
# Run from the repo root: sudo bash deploy/install-agent.sh [port] [host]
# Default: port=8080, host=0.0.0.0
set -euo pipefail

AGENT_PORT="${1:-8080}"
AGENT_HOST="${2:-0.0.0.0}"
INSTALL_DIR="/data/docker/agent"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { echo "[INFO]  $*"; }
ok()  { echo "[OK]    $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ── Validate ──────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"

[[ -f "$REPO_DIR/main.py" ]] \
    || die "main.py not found in $REPO_DIR. Run from the repo root: sudo bash deploy/install-agent.sh"

# ── Port conflict check ───────────────────────────────────────────────────────

pid=$(ss -tlnp "sport = :$AGENT_PORT" 2>/dev/null \
    | awk 'NR>1 {print $6}' \
    | awk -F'pid=' '{print $2}' \
    | awk -F',' '{print $1}' \
    | head -1 || true)

if [[ -n "$pid" ]]; then
    unit=$(systemctl list-units --type=service --state=running --no-pager 2>/dev/null \
        | awk '/vpn-agent/ {print $1}' || true)
    if [[ -n "$unit" ]]; then
        log "vpn-agent already running on port $AGENT_PORT — will restart"
    else
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        die "Port $AGENT_PORT is used by $proc (pid $pid). Free it first."
    fi
fi

# ── xray check ────────────────────────────────────────────────────────────────

if command -v xray &>/dev/null; then
    ok "xray found: $(xray version 2>/dev/null | head -1)"
else
    log "WARNING: xray is not installed. Agent will start but /health will report 'down'"
    log "Run deploy/install-xray.sh first"
fi

# ── Python dependencies ───────────────────────────────────────────────────────

log "Installing Python runtime..."
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv
ok "Python ready: $(python3 --version)"

# ── Agent directory ───────────────────────────────────────────────────────────

log "Setting up agent directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [[ "$REPO_DIR" != "$INSTALL_DIR" ]]; then
    cp "$REPO_DIR/main.py"        "$INSTALL_DIR/main.py"
    cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
    cp -r "$REPO_DIR/app"         "$INSTALL_DIR/app"
    ok "Agent files copied to $INSTALL_DIR"
else
    log "Repo and install dir are the same — skipping copy"
fi

# ── Virtual environment ───────────────────────────────────────────────────────

if [[ ! -d "$INSTALL_DIR/venv" ]]; then
    log "Creating virtual environment..."
    python3 -m venv "$INSTALL_DIR/venv"
    ok "Virtual environment created"
fi

log "Installing Python dependencies..."
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade -r "$INSTALL_DIR/requirements.txt"
ok "Python dependencies installed"

# ── Token and env ─────────────────────────────────────────────────────────────

if [[ ! -f "$INSTALL_DIR/server-agent.env" ]]; then
    AGENT_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    cat > "$INSTALL_DIR/server-agent.env" << EOF
AGENT_TOKEN='${AGENT_TOKEN}'
XRAY_CONFIG_PATH='/usr/local/etc/xray/config.json'
XRAY_SERVICE='xray'
XRAY_API_ADDRESS='127.0.0.1:10085'
EOF
    ok "Generated new agent token"
else
    AGENT_TOKEN=$(awk -F"'" '/AGENT_TOKEN/ {print $2}' "$INSTALL_DIR/server-agent.env")
    ok "Using existing token from server-agent.env"
fi

# ── Systemd service ───────────────────────────────────────────────────────────

log "Writing systemd unit..."
cat > /etc/systemd/system/vpn-agent.service << EOF
[Unit]
Description=VPN Server Agent
After=network.target xray.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/uvicorn main:app --host ${AGENT_HOST} --port ${AGENT_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-agent
systemctl restart vpn-agent
ok "vpn-agent service started"

# ── Firewall ──────────────────────────────────────────────────────────────────

if [[ "$AGENT_HOST" != "127.0.0.1" ]] && command -v ufw &>/dev/null; then
    ufw allow "${AGENT_PORT}/tcp" 2>/dev/null || true
    ok "Opened port ${AGENT_PORT}/tcp in firewall"
fi

# ── Health check ──────────────────────────────────────────────────────────────

log "Waiting for agent to start..."
sleep 2

if ! systemctl is-active --quiet vpn-agent; then
    echo "[ERROR] vpn-agent failed to start. Last 20 lines from journal:" >&2
    journalctl -u vpn-agent -n 20 --no-pager >&2
    exit 1
fi

HEALTH=$(curl -sf --connect-timeout 5 "http://127.0.0.1:${AGENT_PORT}/health" 2>/dev/null || true)
if [[ -n "$HEALTH" ]]; then
    ok "Health check passed: $HEALTH"
else
    log "WARNING: Health endpoint did not respond — agent may still be starting"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "<unknown>")

echo ""
echo "=== Agent installed ==="
echo "Port:   ${AGENT_PORT}"
echo "Host:   ${AGENT_HOST}"
echo "Token:  ${AGENT_TOKEN}"
echo ""
echo "Register this server in the backend:"
echo "  POST /api/servers"
printf '  {"name": "%s", "ip": "%s", "agent_port": %s, "agent_token": "%s"}\n' \
    "$(hostname)" "$SERVER_IP" "$AGENT_PORT" "$AGENT_TOKEN"
