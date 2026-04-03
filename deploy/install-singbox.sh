#!/bin/bash
# Install sing-box on any server (protocol-agnostic).
# Usage: sudo bash install-singbox.sh [ports...]
# Example: sudo bash install-singbox.sh 443 8443
set -euo pipefail

# --- Validate ---
if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash $0"
    exit 1
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    echo "Only Ubuntu/Debian supported"
    exit 1
fi

# --- Install sing-box ---
echo "=== Installing sing-box ==="
apt-get update -qq
apt-get install -y -qq curl jq ufw

# Official install script
bash <(curl -fsSL https://sing-box.app/deb-install.sh)

# Verify
if ! command -v sing-box &>/dev/null; then
    echo "sing-box install failed"
    exit 1
fi
echo "sing-box version: $(sing-box version)"

# --- Create config directory ---
mkdir -p /etc/sing-box

# Placeholder config (will be replaced by agent)
cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {"level": "warn"},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ]
}
EOF

# --- Firewall ---
echo "=== Configuring firewall ==="
ufw allow 22/tcp
for port in "$@"; do
    ufw allow "$port"/tcp
    ufw allow "$port"/udp
    echo "Opened port $port (tcp+udp)"
done
ufw --force enable

# --- Enable and start ---
systemctl enable sing-box
systemctl start sing-box

echo ""
echo "=== sing-box installed ==="
echo "Config: /etc/sing-box/config.json"
echo "Status: systemctl status sing-box"
echo "Logs:   journalctl -u sing-box -f"
echo ""
echo "Next: run install-agent.sh to install the management agent"
