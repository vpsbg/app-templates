#!/bin/sh

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

npm install -g openclaw@latest
useradd -m openclaw

cat >/root/openclaw-install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   /root/openclaw-install.sh
#   /root/openclaw-install.sh "API_KEY"

API_KEY="${1:-}"

if [[ -n "$API_KEY" ]]; then
  echo "[openclaw] Non-interactive onboarding (API key provided)"
  sudo -iu openclaw env ANTHROPIC_API_KEY="$API_KEY" \
    openclaw onboard --non-interactive \
      --mode local \
      --auth-choice apiKey \
      --anthropic-api-key "$API_KEY" \
      --gateway-port 18789 \
      --gateway-bind loopback \
      --skip-skills \
      --accept-risk
else
  echo "[openclaw] Interactive onboarding"
  sudo -iu openclaw openclaw onboard
fi

# systemd service
cat >/etc/systemd/system/openclaw-gateway.service <<'UNIT'
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/home/openclaw
Environment=HOME=/home/openclaw
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now openclaw-gateway.service

echo "[openclaw] System service enabled: openclaw-gateway.service"
echo "[openclaw] UI (loopback): http://127.0.0.1:18789/"
echo "[openclaw] SSH tunnel: ssh -L 18789:127.0.0.1:18789 root@SERVER"
EOF

chmod +x /root/openclaw-install.sh

echo 'OpenClaw installation prepared.'
echo 'Run: /root/openclaw-install.sh'
echo 'Or non-interactive: /root/openclaw-install.sh "API_KEY"'