#!/bin/bash
# Install the thin VPN server agent as a systemd service.
# Idempotent — safe to run multiple times. Preserves existing token.
# Run from the repo root: sudo bash deploy/install-agent.sh [port] [host]
# Default: port=8080, host=0.0.0.0
set -euo pipefail

AGENT_PORT="${1:-8080}"
AGENT_HOST="${2:-0.0.0.0}"
INSTALL_DIR="/opt/vpn-agent"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Validate ---
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
fi

if [[ ! -f "$REPO_DIR/main.py" ]]; then
    echo "ERROR: main.py not found in $REPO_DIR"
    echo "Run this script from the agent repo root: sudo bash deploy/install-agent.sh"
    exit 1
fi

# --- Check port conflict ---
pid=$(ss -tlnp "sport = :$AGENT_PORT" 2>/dev/null | awk 'NR>1 {print $6}' | awk -F'pid=' '{print $2}' | awk -F',' '{print $1}' | head -1 || true)
if [[ -n "$pid" ]]; then
    proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
    unit=$(systemctl list-units --type=service --state=running --no-pager 2>/dev/null | grep "vpn-agent" | awk '{print $1}' || true)
    if [[ -n "$unit" ]]; then
        echo "vpn-agent already running on port $AGENT_PORT, will restart"
    else
        echo "ERROR: Port $AGENT_PORT is already used by $proc (pid $pid)"
        echo "Free the port first or choose a different one"
        exit 1
    fi
fi

# --- Check sing-box ---
if ! command -v sing-box &>/dev/null; then
    echo "WARNING: sing-box is not installed. Agent will start but health check will report 'down'"
    echo "Run install-singbox.sh first"
fi

# --- Install dependencies ---
echo "=== Installing dependencies ==="
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv

# --- Setup directory ---
echo "=== Setting up agent ==="
mkdir -p "$INSTALL_DIR"

# Copy agent code and requirements
cp "$REPO_DIR/main.py" "$INSTALL_DIR/main.py"
cp "$REPO_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

# Create virtualenv and install deps
if [[ ! -d "$INSTALL_DIR/venv" ]]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade -r "$INSTALL_DIR/requirements.txt"

# --- Generate config (only if not exists) ---
if [[ ! -f "$INSTALL_DIR/server-agent.env" ]]; then
    AGENT_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

    cat > "$INSTALL_DIR/server-agent.env" << EOF
AGENT_TOKEN='${AGENT_TOKEN}'
SINGBOX_CONFIG_PATH='/etc/sing-box/config.json'
SINGBOX_SERVICE='sing-box'
EOF
    echo "Generated new token: ${AGENT_TOKEN}"
else
    AGENT_TOKEN=$(awk -F"'" '/AGENT_TOKEN/ {print $2}' "$INSTALL_DIR/server-agent.env")
    echo "Using existing token from server-agent.env"
fi

# --- Systemd service ---
cat > /etc/systemd/system/vpn-agent.service << EOF
[Unit]
Description=VPN Server Agent
After=network.target sing-box.service

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

# --- Firewall ---
if [[ "$AGENT_HOST" != "127.0.0.1" ]]; then
    ufw allow "${AGENT_PORT}/tcp" 2>/dev/null || true
    echo "Opened port ${AGENT_PORT}/tcp in firewall"
fi

# --- Verify ---
sleep 1
if systemctl is-active --quiet vpn-agent; then
    SERVER_IP=$(curl -s --connect-timeout 5 ifconfig.me || echo "<unknown>")
    echo ""
    echo "=== Agent installed ==="
    echo "Port:   ${AGENT_PORT}"
    echo "Host:   ${AGENT_HOST}"
    echo "Token:  ${AGENT_TOKEN}"
    echo ""
    echo "Add this server to the backend:"
    echo "  POST /api/servers"
    echo "  {\"name\": \"$(hostname)\", \"ip\": \"${SERVER_IP}\", \"agent_port\": ${AGENT_PORT}, \"agent_token\": \"${AGENT_TOKEN}\"}"
else
    echo ""
    echo "ERROR: Agent failed to start. Check: journalctl -u vpn-agent -n 20"
    exit 1
fi
