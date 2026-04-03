#!/bin/bash
# Install the thin VPN server agent as a systemd service.
# Usage: sudo bash install-agent.sh [agent_port]
# Default port: 8080
set -euo pipefail

AGENT_PORT="${1:-8080}"
INSTALL_DIR="/opt/vpn-agent"

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
cp server-agent/main.py "$INSTALL_DIR/main.py"

# Create virtualenv and install deps
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q fastapi uvicorn pydantic-settings httpx

# --- Generate config ---
AGENT_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")

cat > "$INSTALL_DIR/server-agent.env" << EOF
AGENT_TOKEN='${AGENT_TOKEN}'
SINGBOX_CONFIG_PATH='/etc/sing-box/config.json'
SINGBOX_SERVICE='sing-box'
EOF

# --- Systemd service ---
cat > /etc/systemd/system/vpn-agent.service << EOF
[Unit]
Description=VPN Server Agent
After=network.target sing-box.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/uvicorn main:app --host 127.0.0.1 --port ${AGENT_PORT}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vpn-agent
systemctl start vpn-agent

# --- Firewall (agent port only for internal access) ---
# Agent listens on 127.0.0.1 by default — no firewall rule needed
# If you need remote access, change --host to 0.0.0.0 and open the port

echo ""
echo "=== Agent installed ==="
echo "Port:   ${AGENT_PORT}"
echo "Token:  ${AGENT_TOKEN}"
echo "Status: systemctl status vpn-agent"
echo "Logs:   journalctl -u vpn-agent -f"
echo ""
echo "Add this server to the backend:"
echo "  POST /api/servers"
echo "  {\"name\": \"$(hostname)\", \"ip\": \"$(curl -s ifconfig.me)\", \"agent_port\": ${AGENT_PORT}, \"agent_token\": \"${AGENT_TOKEN}\"}"
