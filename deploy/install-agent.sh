#!/bin/bash
# Install the thin VPN server agent as a systemd service.
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

# --- Install dependencies ---
echo "=== Installing dependencies ==="
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-venv

# --- Setup directory ---
echo "=== Setting up agent ==="
mkdir -p "$INSTALL_DIR"

# Copy agent code
cp "$REPO_DIR/main.py" "$INSTALL_DIR/main.py"

# Create virtualenv and install deps
if [[ ! -d "$INSTALL_DIR/venv" ]]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q -r "$REPO_DIR/requirements.txt"

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
    AGENT_TOKEN=$(grep AGENT_TOKEN "$INSTALL_DIR/server-agent.env" | cut -d"'" -f2)
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
    ufw allow "${AGENT_PORT}/tcp"
    echo "Opened port ${AGENT_PORT}/tcp in firewall"
fi

echo ""
echo "=== Agent installed ==="
echo "Port:   ${AGENT_PORT}"
echo "Host:   ${AGENT_HOST}"
echo "Token:  ${AGENT_TOKEN}"
echo "Status: systemctl status vpn-agent"
echo "Logs:   journalctl -u vpn-agent -f"
echo ""
echo "Add this server to the backend:"
echo "  POST /api/servers"
echo "  {\"name\": \"$(hostname)\", \"ip\": \"$(curl -s ifconfig.me)\", \"agent_port\": ${AGENT_PORT}, \"agent_token\": \"${AGENT_TOKEN}\"}"
