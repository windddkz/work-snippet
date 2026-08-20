#!/usr/bin/env bash
set -euo pipefail

if [ -z "${TS_AUTHKEY:-}" ]; then
    echo "TS_AUTHKEY is required"
    exit 1
fi

mkdir -p /etc/apt/sources.list.d

echo "[+] Installing Tailscale"

curl -fsSL https://tailscale.com/install.sh | sh


echo "[+] Starting tailscaled"

sudo systemctl enable --now tailscaled


echo "[+] Joining tailnet"

sudo tailscale up \
    --auth-key="${TS_AUTHKEY}" \
    --hostname="github-runner-$(hostname)" \
    --advertise-tags=tag:gat \
    --advertise-exit-node \
    --ssh=false


echo "[+] Current status"

tailscale status
tailscale ip
