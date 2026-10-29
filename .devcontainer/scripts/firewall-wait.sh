#!/usr/bin/env bash
# Wartet (als User dev) darauf, dass der Entrypoint die Firewall fertig hat.
# Wird von postCreateCommand und postStartCommand aufgerufen.
set -euo pipefail

timeout="${1:-90}"

for ((i = 0; i < timeout; i++)); do
  if [[ -f /run/firewall/ready ]]; then
    echo "🛡️  Firewall aktiv seit $(cat /run/firewall/ready)"
    exit 0
  fi
  if [[ -f /run/firewall/failed ]]; then
    echo "❌ Firewall-Setup fehlgeschlagen – Container ist im Lockdown (kein Netzwerk)." >&2
    cat /run/firewall/init.log >&2 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

echo "❌ Firewall nach ${timeout}s nicht bereit. Log: /run/firewall/init.log" >&2
exit 1
