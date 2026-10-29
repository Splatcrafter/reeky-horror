#!/usr/bin/env bash
# Container-Entrypoint (läuft als root, PID 1 ist tini via "init": true).
# Setzt die Firewall auf und übergibt dann an CMD (sleep infinity).
# Schlägt die Firewall fehl, bleibt der Container im Lockdown (kein Netz),
# damit man das Log lesen kann – er wird NICHT ungeschützt gestartet.
set -uo pipefail

mkdir -p /run/firewall
chmod 0755 /run/firewall

/usr/local/sbin/init-firewall.sh 2>&1 | tee /run/firewall/init.log
status=${PIPESTATUS[0]}
chmod 0644 /run/firewall/init.log

if [[ ${status} -ne 0 ]]; then
  echo "[entrypoint] ❌ Firewall-Setup fehlgeschlagen (Exit ${status}). Container läuft im Lockdown." >&2
fi

exec "$@"
