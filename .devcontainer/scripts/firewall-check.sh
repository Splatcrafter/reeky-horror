#!/usr/bin/env bash
# Manueller Firewall-Check als normaler User: `firewall-check`
# Optional mit Domain: `firewall-check docs.roblox.com` prüft eine einzelne URL.
set -uo pipefail

ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; fail=1; }
fail=0

probe() { curl -sS -o /dev/null --max-time 6 "$@" >/dev/null 2>&1; }

if [[ $# -gt 0 ]]; then
  url="$1"; [[ "$url" == http* ]] || url="https://$url"
  if probe "$url"; then echo "🟢 erreichbar: $url"; else echo "🔴 blockiert: $url"; fi
  exit 0
fi

echo "🛡️  Firewall-Status"
if [[ -f /run/firewall/ready ]]; then ok "aktiv seit $(cat /run/firewall/ready)"; else bad "nicht bereit (siehe /run/firewall/init.log)"; fi

echo "🟢 Muss erreichbar sein:"
for u in https://api.anthropic.com https://claude.ai https://github.com https://api.github.com; do
  if probe "$u"; then ok "$u"; else bad "$u"; fi
done

echo "🔴 Muss blockiert sein:"
for u in https://example.com https://www.google.com http://host.docker.internal http://192.168.65.254 http://172.17.0.1; do
  if probe "$u"; then bad "$u ist erreichbar!"; else ok "$u"; fi
done
if dig +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1; then bad "Direkter DNS (1.1.1.1) möglich!"; else ok "Direkter DNS an fremde Resolver"; fi

echo "📜 Letzte DNS-Anfragen (zum Finden fehlender Allowlist-Einträge):"
grep -F 'query[' /run/firewall/dnsmasq.log 2>/dev/null | tail -n 15 | sed 's/^/  /' || true

exit "${fail}"
