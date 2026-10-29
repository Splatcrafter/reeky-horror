#!/usr/bin/env bash
# =============================================================================
#  init-firewall.sh – Egress-Firewall für den Dev-Container
# =============================================================================
#  Läuft als root aus dem Container-Entrypoint (nie als User "dev").
#
#  Aufbau:
#    1. Fail-closed: alle Policies sofort auf DROP.
#    2. Lokaler DNS-Resolver (dnsmasq, User "dnsfw") auf 127.0.0.1:53.
#       - Löst NUR Domains aus /etc/firewall/allowed-domains.conf auf.
#       - Schreibt jede aufgelöste IPv4 live in ein ipset
#         -> überlebt IP-Rotationen von Cloudflare/CDNs ohne Cronjob.
#       - Nur dnsmasq darf den Upstream-DNS (Docker) erreichen.
#    3. Host, LAN, Docker-Netze, Link-Local/Metadata: hart REJECT.
#    4. Ausgehend nur TCP/443 (und TCP/22 für "ssh"-Domains) zu IPs im ipset.
#    5. Eingehend nur Loopback + Antworten auf eigene Verbindungen.
#       (Rojo-Port-Forwarding von VS Code läuft über Loopback im Container.)
#    6. IPv6 komplett zu.
#    7. Selbsttest; schlägt der fehl -> totaler Lockdown.
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

# Ziele, die NIE erreichbar sein dürfen (Host, LAN, Docker-Bridge,
# Docker-Desktop-VM 192.168.65.0/24, host.docker.internal, Cloud-Metadata …)
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
  # Alles zu, nur Loopback bleibt (damit der Container nicht hängt).
  "${IPT[@]}" -P INPUT DROP   || true
  "${IPT[@]}" -P FORWARD DROP || true
  "${IPT[@]}" -P OUTPUT DROP  || true
  "${IPT[@]}" -F || true
  "${IPT[@]}" -A INPUT  -i lo -j ACCEPT || true
  "${IPT[@]}" -A OUTPUT -o lo -j ACCEPT || true
}

die() {
  log "❌ FEHLER: $*"
  log "🔒 Aktiviere vollständigen Lockdown (kein ausgehender Traffic)."
  lockdown
  rm -f "${STATE_DIR}/ready"
  date -Is > "${STATE_DIR}/failed"
  exit 1
}

trap 'die "Unerwarteter Fehler in Zeile ${LINENO}: ${BASH_COMMAND}"' ERR

[[ "$(id -u)" -eq 0 ]] || { echo "init-firewall.sh muss als root laufen" >&2; exit 1; }

mkdir -p "${STATE_DIR}"
chmod 0755 "${STATE_DIR}"
rm -f "${STATE_DIR}/ready" "${STATE_DIR}/failed"

# -----------------------------------------------------------------------------
# 1. Fail-closed
# -----------------------------------------------------------------------------
log "🔒 Setze Default-Policies auf DROP …"
"${IPT[@]}" -P INPUT DROP
"${IPT[@]}" -P FORWARD DROP
"${IPT[@]}" -P OUTPUT DROP
# Nur die filter-Tabelle leeren. Die nat-Tabelle bleibt unangetastet,
# weil Docker dort seinen eingebetteten DNS (127.0.0.11) umleitet.
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
  log "🚫 IPv6: alles außer Loopback blockiert."
else
  log "ℹ️  IPv6 ist im Container deaktiviert/nicht verfügbar."
fi

# -----------------------------------------------------------------------------
# 2. Upstream-DNS ermitteln (der von Docker vorgegebene Resolver)
# -----------------------------------------------------------------------------
mapfile -t UPSTREAMS < <(
  awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | grep -vx '127.0.0.1' || true
)
if [[ ${#UPSTREAMS[@]} -eq 0 && -s "${UPSTREAM_FILE}" ]]; then
  # Neustart: resolv.conf zeigt schon auf uns -> gespeicherten Upstream nehmen.
  mapfile -t UPSTREAMS < "${UPSTREAM_FILE}"
fi
[[ ${#UPSTREAMS[@]} -gt 0 ]] || die "Kein IPv4-Upstream-DNS in /etc/resolv.conf gefunden."
printf '%s\n' "${UPSTREAMS[@]}" > "${UPSTREAM_FILE}"
[[ -e "${STATE_DIR}/resolv.conf.orig" ]] || cp /etc/resolv.conf "${STATE_DIR}/resolv.conf.orig"
log "🌐 Upstream-DNS: ${UPSTREAMS[*]}"

# -----------------------------------------------------------------------------
# 3. Allowlist einlesen
# -----------------------------------------------------------------------------
[[ -r "${ALLOWLIST}" ]] || die "Allowlist ${ALLOWLIST} fehlt."
DOMAINS=()
SSH_DOMAINS=()
while IFS=$' \t' read -r domain flag _rest || [[ -n "${domain:-}" ]]; do
  domain="${domain%%#*}"
  [[ -z "${domain}" ]] && continue
  domain="${domain,,}"
  domain="${domain%.}"
  if [[ ! "${domain}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
    die "Ungültige Domain in Allowlist: '${domain}'"
  fi
  DOMAINS+=("${domain}")
  if [[ "${flag:-}" == "ssh" ]]; then
    SSH_DOMAINS+=("${domain}")
  fi
done < "${ALLOWLIST}"
[[ ${#DOMAINS[@]} -gt 0 ]] || die "Allowlist ist leer."
log "📋 ${#DOMAINS[@]} erlaubte Domains (davon ${#SSH_DOMAINS[@]} mit SSH)."

is_ssh_domain() {
  local d
  for d in "${SSH_DOMAINS[@]}"; do [[ "$d" == "$1" ]] && return 0; done
  return 1
}

# -----------------------------------------------------------------------------
# 4. ipsets (werden von dnsmasq dynamisch befüllt)
# -----------------------------------------------------------------------------
for set in "${SET_HTTPS}" "${SET_SSH}"; do
  ipset create "${set}" hash:ip family inet maxelem 65536 -exist
  ipset flush "${set}"
done

# -----------------------------------------------------------------------------
# 5. dnsmasq konfigurieren und starten
# -----------------------------------------------------------------------------
if [[ -s "${DNSMASQ_PID}" ]] && kill -0 "$(cat "${DNSMASQ_PID}")" 2>/dev/null; then
  kill "$(cat "${DNSMASQ_PID}")" || true
  sleep 1
fi
pkill -x dnsmasq 2>/dev/null || true

{
  echo "# automatisch generiert von init-firewall.sh – nicht bearbeiten"
  echo "user=${DNS_USER}"
  echo "group=${DNS_USER}"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  echo "port=53"
  echo "pid-file=${DNSMASQ_PID}"
  # Kein Default-Upstream: nicht gelistete Domains -> REFUSED (auch gegen DNS-Exfiltration)
  echo "no-resolv"
  echo "no-hosts"
  echo "no-poll"
  # Kein Cache: jede Auflösung geht upstream und aktualisiert das ipset
  echo "cache-size=0"
  # IPv6 ist zu -> keine AAAA-Antworten ausliefern
  echo "filter-AAAA"
  echo "domain-needed"
  echo "bogus-priv"
  # Antworten mit privaten IPs verwerfen (DNS-Rebinding Richtung Host/LAN)
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
# 6. iptables-Regeln
# -----------------------------------------------------------------------------
log "🧱 Schreibe iptables-Regeln …"

# --- INPUT: nur Loopback + Antworten -----------------------------------------
"${IPT[@]}" -A INPUT -i lo -j ACCEPT
"${IPT[@]}" -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
"${IPT[@]}" -A INPUT -m conntrack --ctstate INVALID -j DROP

# --- OUTPUT ------------------------------------------------------------------
"${IPT[@]}" -A OUTPUT -m conntrack --ctstate INVALID -j DROP
"${IPT[@]}" -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Upstream-DNS dürfen nur dnsmasq (dnsfw) und root (dnsmasq vor dem Rechte-Drop).
# Der Arbeits-User "dev" kann nie root werden (kein sudo, no-new-privileges).
DNS_OWNERS=("${DNS_USER}" 0)

# Dockers eingebetteter DNS (127.0.0.11, liegt auf Loopback!) nur für dnsmasq
for owner in "${DNS_OWNERS[@]}"; do
  "${IPT[@]}" -A OUTPUT -d 127.0.0.11/32 -m owner --uid-owner "${owner}" -j ACCEPT
done
"${IPT[@]}" -A OUTPUT -d 127.0.0.11/32 -j REJECT --reject-with icmp-admin-prohibited

# Loopback (dnsmasq auf 127.0.0.1:53, Rojo auf 127.0.0.1:34872, VS-Code-Server)
"${IPT[@]}" -A OUTPUT -o lo -j ACCEPT

# Upstream-DNS: ausschließlich dnsmasq
for ns in "${UPSTREAMS[@]}"; do
  for proto in udp tcp; do
    for owner in "${DNS_OWNERS[@]}"; do
      "${IPT[@]}" -A OUTPUT -d "${ns}/32" -p "${proto}" --dport 53 \
        -m owner --uid-owner "${owner}" -j ACCEPT
    done
  done
done
# dnsmasq selbst darf sonst nirgendwo hin
"${IPT[@]}" -A OUTPUT -m owner --uid-owner "${DNS_USER}" -j REJECT --reject-with icmp-admin-prohibited

# Host / LAN / Docker / Metadata hart blocken (auch wenn eine IP im ipset landen sollte)
for net in "${BLOCKED_NETS[@]}"; do
  "${IPT[@]}" -A OUTPUT -d "${net}" -p tcp -j REJECT --reject-with tcp-reset
  "${IPT[@]}" -A OUTPUT -d "${net}" -j REJECT --reject-with icmp-admin-prohibited
done

# Erlaubte Ziele (dynamisch über dnsmasq -> ipset)
"${IPT[@]}" -A OUTPUT -p tcp --dport 443 -m set --match-set "${SET_HTTPS}" dst -j ACCEPT
"${IPT[@]}" -A OUTPUT -p tcp --dport 22  -m set --match-set "${SET_SSH}"   dst -j ACCEPT

# Rest: schnell und eindeutig ablehnen
"${IPT[@]}" -A OUTPUT -p tcp -j REJECT --reject-with tcp-reset
"${IPT[@]}" -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# -----------------------------------------------------------------------------
# 7. dnsmasq starten und Container-DNS umstellen
# -----------------------------------------------------------------------------
log "🧭 Starte dnsmasq (User ${DNS_USER}) …"
dnsmasq --conf-file="${DNSMASQ_CONF}"

for _ in $(seq 1 20); do
  dig +time=1 +tries=1 @127.0.0.1 api.anthropic.com A >/dev/null 2>&1 && break
  sleep 0.5
done

# /etc/resolv.conf ist von Docker bind-gemountet -> überschreiben statt ersetzen
printf 'nameserver 127.0.0.1\noptions edns0 trust-ad\n' > /etc/resolv.conf

# -----------------------------------------------------------------------------
# 8. Selbsttest
# -----------------------------------------------------------------------------
log "🧪 Selbsttest …"
trap - ERR

expect_blocked() {
  local desc="$1"; shift
  if curl -sS -o /dev/null --max-time 5 "$@" >/dev/null 2>&1; then
    die "Selbsttest: ${desc} ist erreichbar, sollte aber blockiert sein!"
  fi
  log "   ✅ blockiert: ${desc}"
}

# Nicht gelistete Domain (DNS REFUSED)
expect_blocked "https://example.com" https://example.com
# Direkte IP ohne DNS (Cloudflare-Resolver)
expect_blocked "https://1.1.1.1 (direkte IP)" --insecure https://1.1.1.1
# Docker-Gateway / Host
GATEWAY="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
if [[ -n "${GATEWAY}" ]]; then
  expect_blocked "Gateway/Host ${GATEWAY}" "http://${GATEWAY}/"
fi
expect_blocked "host.docker.internal" http://host.docker.internal/
# DNS an dnsmasq vorbei
if dig +time=2 +tries=1 @1.1.1.1 example.com A >/dev/null 2>&1; then
  die "Selbsttest: direkter DNS an 1.1.1.1 funktioniert, sollte blockiert sein!"
fi
log "   ✅ blockiert: direkter DNS an fremde Resolver"
if dig +time=2 +tries=1 +short @127.0.0.1 example.com A 2>/dev/null | grep -q .; then
  die "Selbsttest: dnsmasq löst nicht gelistete Domain auf!"
fi
log "   ✅ blockiert: DNS für nicht gelistete Domains"

# Positivtest – Netzwerkprobleme sind kein Sicherheitsfehler, nur Warnung
if curl -sS -o /dev/null --max-time 10 https://api.anthropic.com >/dev/null 2>&1; then
  log "   ✅ erreichbar: https://api.anthropic.com"
else
  log "   ⚠️  https://api.anthropic.com nicht erreichbar (offline? DNS?). Firewall bleibt aktiv."
fi

date -Is > "${STATE_DIR}/ready"
chmod 0644 "${STATE_DIR}/ready"
log "🛡️  Firewall aktiv. Erlaubte IPs werden live per DNS nachgetragen."
