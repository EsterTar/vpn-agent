#!/bin/bash
# Install sing-box on any server (protocol-agnostic).
# Idempotent — safe to run multiple times.
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

if [[ $# -eq 0 ]]; then
    echo "Usage: sudo bash $0 <port> [port...]"
    echo "Example: sudo bash $0 443 8443"
    exit 1
fi

# --- Check port conflicts ---
for port in "$@"; do
    pid=$(ss -tlnp "sport = :$port" 2>/dev/null | awk 'NR>1 {print $6}' | awk -F'pid=' '{print $2}' | awk -F',' '{print $1}' | head -1 || true)
    if [[ -n "$pid" ]]; then
        proc=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")
        if [[ "$proc" != "sing-box" ]]; then
            echo "ERROR: Port $port is already used by $proc (pid $pid)"
            echo "Free the port first or choose a different one"
            exit 1
        fi
    fi
done

# --- Install dependencies ---
apt-get update -qq
apt-get install -y -qq curl jq ufw

# --- Install sing-box ---
if command -v sing-box &>/dev/null; then
    echo "sing-box already installed: $(sing-box version | head -1)"
    echo "Skipping installation, updating config..."
else
    echo "=== Installing sing-box ==="
    bash <(curl -fsSL https://sing-box.app/deb-install.sh)

    if ! command -v sing-box &>/dev/null; then
        echo "ERROR: sing-box install failed"
        exit 1
    fi
    echo "sing-box installed: $(sing-box version | head -1)"
fi

# --- Create config (only if not exists) ---
mkdir -p /etc/sing-box

if [[ ! -f /etc/sing-box/config.json ]]; then
    cat > /etc/sing-box/config.json << 'EOF'
{
  "log": {"level": "warn"},
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ]
}
EOF
    echo "Created placeholder config"
else
    echo "Config already exists, skipping"
fi

# --- Firewall ---
echo "=== Configuring firewall ==="
ufw allow 22/tcp 2>/dev/null || true
for port in "$@"; do
    ufw allow "$port"/tcp 2>/dev/null || true
    ufw allow "$port"/udp 2>/dev/null || true
    echo "Opened port $port (tcp+udp)"
done
ufw --force enable

# --- Enable and start ---
systemctl enable sing-box
systemctl restart sing-box

sleep 1
if systemctl is-active --quiet sing-box; then
    echo ""
    echo "=== sing-box ready ==="
else
    echo ""
    echo "WARNING: sing-box is not running. Check: journalctl -u sing-box -n 20"
fi

echo "Config: /etc/sing-box/config.json"
echo "Next: run install-agent.sh"
