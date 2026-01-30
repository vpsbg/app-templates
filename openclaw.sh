export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y

curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

npm install -g openclaw@latest

cat >/root/openclaw-install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   /root/openclaw-install.sh
#   /root/openclaw-install.sh "API_KEY"

API_KEY="${1:-}"

if [[ -n "$API_KEY" ]]; then
  echo "[openclaw] Non-interactive onboarding (API key provided)"
  env ANTHROPIC_API_KEY="$API_KEY" \
    openclaw onboard --non-interactive \
      --mode local \
      --auth-choice apiKey \
      --anthropic-api-key "$API_KEY" \
      --gateway-port 18789 \
      --gateway-bind loopback \
      --skip-skills \
      --install-daemon \
      --accept-risk
else
  echo "[openclaw] Interactive onboarding"
  openclaw onboard --install-daemon
fi
EOF

chmod +x /root/openclaw-install.sh

echo 'OpenClaw installation prepared.'
echo 'Run: /root/openclaw-install.sh'
echo 'Or non-interactive: /root/openclaw-install.sh "API_KEY"'