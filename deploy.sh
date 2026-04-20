#!/usr/bin/env bash
# Deploy test agent instance. Run as root from repo root.
# Usage: bash deploy.sh <AGENT_TOKEN>
set -euo pipefail

AGENT_TOKEN="${1:-}"
if [[ -z "$AGENT_TOKEN" ]]; then
  echo "Usage: bash deploy.sh <AGENT_TOKEN>" >&2
  exit 1
fi

DIR=/data/docker/agent-test

# --- env ---
cp .env.example server-agent.env
sed -i 's/^PORT=.*/PORT=8081/' server-agent.env
sed -i "s|^XRAY_CONFIG_PATH=.*|XRAY_CONFIG_PATH=$DIR/xray.json|" server-agent.env
sed -i 's/^XRAY_SERVICE=.*/XRAY_SERVICE=xray-test/' server-agent.env
sed -i "s|^PROFILE_PATH=.*|PROFILE_PATH=$DIR/server-profile.json|" server-agent.env
sed -i "s/^AGENT_TOKEN=.*/AGENT_TOKEN='$AGENT_TOKEN'/" server-agent.env

# --- xray + firewall ---
bash deploy/install-xray.sh 443

# --- python venv ---
apt-get install -y python3.12-venv
python3 -m venv venv
venv/bin/pip install -r requirements.txt

# --- systemd: xray-test ---
cat > /etc/systemd/system/xray-test.service << 'EOF'
[Unit]
Description=Xray Test Instance
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray -config /data/docker/agent-test/xray.json
Restart=on-failure
ExecReload=/bin/systemctl restart xray-test.service
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- systemd: vpn-agent-test ---
cat > /etc/systemd/system/vpn-agent-test.service << 'EOF'
[Unit]
Description=VPN Server Agent Test
After=network.target xray-test.service

[Service]
Type=simple
WorkingDirectory=/data/docker/agent-test
ExecStart=/data/docker/agent-test/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8081
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# --- firewall ---
ufw allow 8081/tcp
ufw allow 443/tcp

# --- start ---
systemctl daemon-reload
systemctl enable --now vpn-agent-test
systemctl status vpn-agent-test --no-pager

# --- check ---
curl -s http://localhost:8081/health