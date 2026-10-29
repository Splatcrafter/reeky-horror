#!/usr/bin/env bash
# Container entrypoint (runs as root; PID 1 is tini via "init": true).
# Sets up the firewall, then hands over to CMD (sleep infinity).
# If the firewall fails, the container stays in lockdown (no network) so the
# log can be inspected – it is NEVER started unprotected.
set -uo pipefail

mkdir -p /run/firewall
chmod 0755 /run/firewall

/usr/local/sbin/init-firewall.sh 2>&1 | tee /run/firewall/init.log
status=${PIPESTATUS[0]}
chmod 0644 /run/firewall/init.log

if [[ ${status} -ne 0 ]]; then
  echo "[entrypoint] ❌ Firewall setup failed (exit ${status}). Container is in lockdown." >&2
fi

exec "$@"
