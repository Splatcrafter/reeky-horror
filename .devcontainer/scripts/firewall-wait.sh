#!/usr/bin/env bash
# Waits (as user dev) for the entrypoint to finish setting up the firewall.
# Called from postCreateCommand and postStartCommand.
set -euo pipefail

timeout="${1:-90}"

for ((i = 0; i < timeout; i++)); do
  if [[ -f /run/firewall/ready ]]; then
    echo "🛡️  Firewall active since $(cat /run/firewall/ready)"
    exit 0
  fi
  if [[ -f /run/firewall/failed ]]; then
    echo "❌ Firewall setup failed – container is in lockdown (no network)." >&2
    cat /run/firewall/init.log >&2 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

echo "❌ Firewall not ready after ${timeout}s. Log: /run/firewall/init.log" >&2
exit 1
