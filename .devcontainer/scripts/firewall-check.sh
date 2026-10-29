#!/usr/bin/env bash
# Manual firewall check as a regular user: `firewall-check`
# Optionally with a domain: `firewall-check docs.roblox.com` checks a single URL.
set -uo pipefail

ok()   { printf '  ✅ %s\n' "$*"; }
bad()  { printf '  ❌ %s\n' "$*"; fail=1; }
fail=0

probe() { curl -sS -o /dev/null --max-time 6 "$@" >/dev/null 2>&1; }

if [[ $# -gt 0 ]]; then
  url="$1"; [[ "$url" == http* ]] || url="https://$url"
  if probe "$url"; then echo "🟢 reachable: $url"; else echo "🔴 blocked: $url"; fi
  exit 0
fi

echo "🛡️  Firewall status"
if [[ -f /run/firewall/ready ]]; then ok "active since $(cat /run/firewall/ready)"; else bad "not ready (see /run/firewall/init.log)"; fi

echo "🟢 Must be reachable:"
for u in https://api.anthropic.com https://claude.ai https://github.com https://api.github.com; do
  if probe "$u"; then ok "$u"; else bad "$u"; fi
done

echo "🔴 Must be blocked:"
for u in https://example.com https://www.google.com http://host.docker.internal http://192.168.65.254 http://172.17.0.1; do
  if probe "$u"; then bad "$u is reachable!"; else ok "$u"; fi
done
if dig +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1; then bad "Direct DNS (1.1.1.1) possible!"; else ok "Direct DNS to foreign resolvers"; fi

echo "📜 Recent DNS queries (to find missing allowlist entries):"
grep -F 'query[' /run/firewall/dnsmasq.log 2>/dev/null | tail -n 15 | sed 's/^/  /' || true

exit "${fail}"
