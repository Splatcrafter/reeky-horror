#!/usr/bin/env bash
# =============================================================================
#  init-firewall.sh – egress firewall for the dev container
# =============================================================================
#  Runs as root from the container entrypoint (never as user "dev").
#
#  Overview:
#    1. Fail-closed: all policies set to DROP immediately.
#    2. Local DNS resolver (dnsmasq, user "dnsfw") on 127.0.0.1:53.
#       - Resolves ONLY domains from /etc/firewall/allowed-domains.conf.
#       - Adds every resolved IPv4 address to an ipset on the fly
#         -> survives Cloudflare/CDN IP rotation without a cron job.
#       - Only dnsmasq may reach the upstream DNS (Docker).
#    3. Host, LAN, Docker networks, link-local/metadata: hard REJECT.
#    4. Outbound only TCP/443 (and TCP/22 for "ssh" domains) to IPs in the ipset.
#    5. Inbound only loopback + replies to our own connections.
#       (VS Code's Rojo port forwarding goes through loopback inside the container.)
#    6. IPv6 fully closed.
#    7. Self-test; on failure -> full lockdown.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

readonly STATE_DIR=/run/firewall
readonly ALLOWLIST=/etc/firewall/allowed-domains.conf
readonly DNS_USER=dnsfw
readonly SET_HTTPS=fw-allow-https
readonly SET_SSH=fw-allow-ssh
readonly DNSMASQ_CONF="${STATE_DIR}/dnsmasq.conf"
readonly DNSMASQ_LOG="${STATE_DIR}/dnsmasq.log"
readonly DNSMASQ_PID="${STATE_DIR}/dnsmasq.pid"
readonly UPSTREAM_FILE="${STATE_DIR}/upstream-dns"

# Destinations that must NEVER be reachable (host, LAN, Docker bridge,
# Docker Desktop VM 192.168.65.0/24, host.docker.internal, cloud metadata, ...)
readonly BLOCKED_NETS=(
  0.0.0.0/8
  10.0.0.0/8
  100.64.0.0/10
  127.0.0.0/8
  169.254.0.0/16
  172.16.0.0/12
  192.0.0.0/24
  192.0.2.0/24
  192.168.0.0/16
  198.18.0.0/15
  198.51.100.0/24
  203.0.113.0/24
  224.0.0.0/4
  240.0.0.0/4
)

IPT=(iptables -w 5)
IP6T=(ip6tables -w 5)

log() { printf '[firewall] %s\n' "$*"; }

lockdown() {
  # Close everything, keep only loopback (so the container doesn't hang).
  "${IPT[@]}" -P INPUT DROP   || true
  "${IPT[@]}" -P FORWARD DROP || true
  "${IPT[@]}" -P OUTPUT DROP  || true
  "${IPT[@]}" -F || true
  "${IPT[@]}" -A INPUT  -i lo -j ACCEPT || true
  "${IPT[@]}" -A OUTPUT -o lo -j ACCEPT || true
}

die() {
  log "❌ ERROR: $*"
  log "🔒 Enabling full lockdown (no outbound traffic)."
  lockdown
  rm -f "${STATE_DIR}/ready"
  date -Is > "${STATE_DIR}/failed"
  exit 1
}

trap 'die "Unexpected error on line ${LINENO}: ${BASH_COMMAND}"' ERR

[[ "$(id -u)" -eq 0 ]] || { echo "init-firewall.sh must run as root" >&2; exit 1; }

mkdir -p "${STATE_DIR}"
chmod 0755 "${STATE_DIR}"
rm -f "${STATE_DIR}/ready" "${STATE_DIR}/failed"

# -----------------------------------------------------------------------------
# 1. Fail-closed
# -----------------------------------------------------------------------------
log "🔒 Setting default policies to DROP ..."
"${IPT[@]}" -P INPUT DROP
"${IPT[@]}" -P FORWARD DROP
"${IPT[@]}" -P OUTPUT DROP
# Flush only the filter table. The nat table is left untouched because
# Docker uses it to redirect its embedded DNS (127.0.0.11).
"${IPT[@]}" -F
"${IPT[@]}" -X

if "${IP6T[@]}" -L >/dev/null 2>&1; then
  "${IP6T[@]}" -P INPUT DROP
  "${IP6T[@]}" -P FORWARD DROP
  "${IP6T[@]}" -P OUTPUT DROP
  "${IP6T[@]}" -F
  "${IP6T[@]}" -X
  "${IP6T[@]}" -A INPUT  -i lo -j ACCEPT
  "${IP6T[@]}" -A OUTPUT -o lo -j ACCEPT
  log "🚫 IPv6: everything except loopback blocked."
else
  log "ℹ️  IPv6 is disabled/unavailable in the container."
fi

# -----------------------------------------------------------------------------
# 2. Determine upstream DNS (the resolver provided by Docker)
# -----------------------------------------------------------------------------
mapfile -t UPSTREAMS < <(
  awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | grep -vx '127.0.0.1' || true
)
if [[ ${#UPSTREAMS[@]} -eq 0 && -s "${UPSTREAM_FILE}" ]]; then
  # Restart: resolv.conf already points to us -> use the saved upstream.
  mapfile -t UPSTREAMS < "${UPSTREAM_FILE}"
fi
[[ ${#UPSTREAMS[@]} -gt 0 ]] || die "No IPv4 upstream DNS found in /etc/resolv.conf."
printf '%s\n' "${UPSTREAMS[@]}" > "${UPSTREAM_FILE}"
[[ -e "${STATE_DIR}/resolv.conf.orig" ]] || cp /etc/resolv.conf "${STATE_DIR}/resolv.conf.orig"
log "🌐 Upstream DNS: ${UPSTREAMS[*]}"

# -----------------------------------------------------------------------------
# 3. Read the allowlist
# -----------------------------------------------------------------------------
[[ -r "${ALLOWLIST}" ]] || die "Allowlist ${ALLOWLIST} is missing."
DOMAINS=()
SSH_DOMAINS=()
while IFS=$' \t' read -r domain flag _rest || [[ -n "${domain:-}" ]]; do
  domain="${domain%%#*}"
  [[ -z "${domain}" ]] && continue
  domain="${domain,,}"
  domain="${domain%.}"
  if [[ ! "${domain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "Invalid domain in allowlist: '${domain}'"
  fi
  DOMAINS+=("${domain}")
  if [[ "${flag:-}" == "ssh" ]]; then
    SSH_DOMAINS+=("${domain}")
  fi
done < "${ALLOWLIST}"
[[ ${#DOMAINS[@]} -gt 0 ]] || die "Allowlist is empty."
log "📋 ${#DOMAINS[@]} allowed domains (${#SSH_DOMAINS[@]} with SSH)."

is_ssh_domain() {
  local d
  for d in "${SSH_DOMAINS[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  return 1
}

# -----------------------------------------------------------------------------
# 4. ipsets (populated dynamically by dnsmasq)
# -----------------------------------------------------------------------------
for set in "${SET_HTTPS}" "${SET_SSH}"; do
  ipset create "${set}" hash:ip family inet maxelem 65536 -exist
  ipset flush "${set}"
done

# -----------------------------------------------------------------------------
# 5. Configure dnsmasq
# -----------------------------------------------------------------------------
if [[ -s "${DNSMASQ_PID}" ]] && kill -0 "$(cat "${DNSMASQ_PID}")" 2>/dev/null; then
  kill "$(cat "${DNSMASQ_PID}")" || true
  sleep 1
fi
pkill -x dnsmasq 2>/dev/null || true

{
  echo "# generated by init-firewall.sh – do not edit"
  echo "user=${DNS_USER}"
  echo "group=${DNS_USER}"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "port=53"
  echo "pid-file=${DNSMASQ_PID}"
  # No default upstream: unlisted domains -> REFUSED (also prevents DNS exfiltration)
  echo "no-resolv"
  echo "no-hosts"
  echo "no-poll"
  # No cache: every lookup goes upstream and refreshes the ipset
  echo "cache-size=0"
  # IPv6 is closed -> don't hand out AAAA answers
  echo "filter-AAAA"
  echo "domain-needed"
  echo "bogus-priv"
  # Drop answers containing private IPs (DNS rebinding towards host/LAN)
  echo "stop-dns-rebind"
  echo "log-queries"
  echo "log-facility=${DNSMASQ_LOG}"
  for d in "${DOMAINS[@]}"; do
    for ns in "${UPSTREAMS[@]}"; do
      echo "server=/${d}/${ns}"
    done
    if is_ssh_domain "${d}"; then
      echo "ipset=/${d}/${SET_HTTPS},${SET_SSH}"
    else
      echo "ipset=/${d}/${SET_HTTPS}"
    fi
  done
} > "${DNSMASQ_CONF}"
chmod 0644 "${DNSMASQ_CONF}"

: > "${DNSMASQ_LOG}"
chown "${DNS_USER}:${DNS_USER}" "${DNSMASQ_LOG}"
chmod 0644 "${DNSMASQ_LOG}"

# -----------------------------------------------------------------------------
# 6. iptables rules
# -----------------------------------------------------------------------------
log "🧱 Writing iptables rules ..."

# --- INPUT: loopback + replies only ------------------------------------------
"${IPT[@]}" -A INPUT -i lo -j ACCEPT
"${IPT[@]}" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"${IPT[@]}" -A INPUT -m conntrack --ctstate INVALID -j DROP

# --- OUTPUT ------------------------------------------------------------------
"${IPT[@]}" -A OUTPUT -m conntrack --ctstate INVALID -j DROP
"${IPT[@]}" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Only dnsmasq (dnsfw) and root (dnsmasq before dropping privileges) may reach
# the upstream DNS. The working user "dev" can never become root
# (no sudo, no-new-privileges).
DNS_OWNERS=("${DNS_USER}" 0)

# Docker's embedded DNS (127.0.0.11, lives on loopback!) for dnsmasq only
for owner in "${DNS_OWNERS[@]}"; do
  "${IPT[@]}" -A OUTPUT -d 127.0.0.11/32 -m owner --uid-owner "${owner}" -j ACCEPT
done
"${IPT[@]}" -A OUTPUT -d 127.0.0.11/32 -j REJECT --reject-with icmp-admin-prohibited

# Loopback (dnsmasq on 127.0.0.1:53, Rojo on 127.0.0.1:34872, VS Code server)
"${IPT[@]}" -A OUTPUT -o lo -j ACCEPT

# Upstream DNS: dnsmasq only
for ns in "${UPSTREAMS[@]}"; do
  for proto in udp tcp; do
    for owner in "${DNS_OWNERS[@]}"; do
      "${IPT[@]}" -A OUTPUT -d "${ns}/32" -p "${proto}" --dport 53 \
        -m owner --uid-owner "${owner}" -j ACCEPT
    done
  done
done
# dnsmasq itself may not go anywhere else
"${IPT[@]}" -A OUTPUT -m owner --uid-owner "${DNS_USER}" -j REJECT --reject-with icmp-admin-prohibited

# Hard-block host / LAN / Docker / metadata (even if such an IP ends up in the ipset)
for net in "${BLOCKED_NETS[@]}"; do
  "${IPT[@]}" -A OUTPUT -d "${net}" -p tcp -j REJECT --reject-with tcp-reset
  "${IPT[@]}" -A OUTPUT -d "${net}" -j REJECT --reject-with icmp-admin-prohibited
done

# Allowed destinations (dynamic via dnsmasq -> ipset)
"${IPT[@]}" -A OUTPUT -p tcp --dport 443 -m set --match-set "${SET_HTTPS}" dst -j ACCEPT
"${IPT[@]}" -A OUTPUT -p tcp --dport 22  -m set --match-set "${SET_SSH}"   dst -j ACCEPT

# Everything else: reject fast and explicitly
"${IPT[@]}" -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
"${IPT[@]}" -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# -----------------------------------------------------------------------------
# 7. Start dnsmasq and switch the container's DNS over to it
# -----------------------------------------------------------------------------
log "🧭 Starting dnsmasq (user ${DNS_USER}) ..."
dnsmasq --conf-file="${DNSMASQ_CONF}"

for _ in $(seq 1 20); do
  dig +time=1 +tries=1 @127.0.0.1 api.anthropic.com A >/dev/null 2>&1 && break
  sleep 0.5
done

# /etc/resolv.conf is bind-mounted by Docker -> overwrite in place instead of replacing
printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf

# -----------------------------------------------------------------------------
# 8. Self-test
# -----------------------------------------------------------------------------
log "🧪 Self-test ..."
trap - ERR

expect_blocked() {
  local desc="$1"; shift
  if curl -sS -o /dev/null --max-time 5 "$@" >/dev/null 2>&1; then
    die "Self-test: ${desc} is reachable but should be blocked!"
  fi
  log "   ✅ blocked: ${desc}"
}

# Unlisted domain (DNS REFUSED)
expect_blocked "https://example.com" https://example.com
# Direct IP without DNS (Cloudflare resolver)
expect_blocked "https://1.1.1.1 (direct IP)" --insecure https://1.1.1.1
# Docker gateway / host
GATEWAY="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
if [[ -n "${GATEWAY}" ]]; then
  expect_blocked "gateway/host ${GATEWAY}" "http://${GATEWAY}/"
fi
expect_blocked "host.docker.internal" http://host.docker.internal/
# DNS bypassing dnsmasq
if dig +time=2 +tries=1 @1.1.1.1 example.com A >/dev/null 2>&1; then
  die "Self-test: direct DNS to 1.1.1.1 works but should be blocked!"
fi
log "   ✅ blocked: direct DNS to foreign resolvers"
if dig +time=2 +tries=1 +short @127.0.0.1 example.com A 2>/dev/null | grep -q .; then
  die "Self-test: dnsmasq resolves an unlisted domain!"
fi
log "   ✅ blocked: DNS for unlisted domains"

# Positive test – network problems are not a security failure, just a warning
if curl -sS -o /dev/null --max-time 10 https://api.anthropic.com >/dev/null 2>&1; then
  log "   ✅ reachable: https://api.anthropic.com"
else
  log "   ⚠️  https://api.anthropic.com unreachable (offline? DNS?). Firewall stays active."
fi

date -Is > "${STATE_DIR}/ready"
chmod 0644 "${STATE_DIR}/ready"
log "🛡️  Firewall active. Allowed IPs are added live via DNS."
