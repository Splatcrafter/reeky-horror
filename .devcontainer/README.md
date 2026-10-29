# 👻 reeky-horror – Dev-Container

Abgeschotteter Entwicklungs-Container für das Roblox-Spiel **reeky-horror**:
Rojo + Luau-Toolchain, **Claude Code nativ installiert**, eine **Egress-Firewall**, die
nur freigegebene Domains durchlässt, und **keinen Weg zurück auf den Host**.

---

## 📦 Was ist drin?

| Bereich | Inhalt |
|---|---|
| 🐧 Basis | `debian:trixie-slim`, User **`dev`** (UID 1000), **kein sudo** |
| 🤖 Claude Code | Nativer Installer (`claude.ai/install.sh`) → `~/.local/bin/claude`, Auto-Update aktiv |
| 🧰 Toolchain | [Rokit](https://github.com/rojo-rbx/rokit) + `rokit.toml` im Projekt-Root: **Rojo**, **StyLua**, **Selene**, **luau-lsp**, **Wally** |
| 🧩 VS Code Extensions | Claude Code, Rojo, Luau LSP, StyLua, Selene |
| 🛡️ Firewall | iptables + ipset + dnsmasq (DNS-gesteuerte Allowlist) |
| 🔌 Port | nur **34872** (Rojo) per VS Code Port-Forwarding |
| 💾 Volumes | `~/.claude` (Login/Settings/Sessions) und Bash-History, pro Projekt isoliert |
| 🛠️ Extras | git, ripgrep, fd, jq, curl, dig, nano, less |

## 🗂️ Dateien

```
.devcontainer/
├── devcontainer.json          ⚙️  Container-Config (Rechte, Mounts, Port, Extensions)
├── Dockerfile                 🐳 Image (Tools, Claude Code, Rokit, User)
├── README.md                  📖 diese Datei
├── firewall/
│   ├── init-firewall.sh       🧱 Firewall-Setup (läuft als root im Entrypoint)
│   └── allowed-domains.conf   📋 Allowlist – HIER Domains freigeben
└── scripts/
    ├── entrypoint.sh          🚪 Container-Start: Firewall → sleep infinity
    ├── firewall-wait.sh       ⏳ wartet, bis die Firewall steht (postStart)
    ├── firewall-check.sh      🩺 `firewall-check` – Selbsttest für dich
    └── post-create.sh         🧰 einmalig: git safe.directory + `rokit install`
rokit.toml                     🔧 Tool-Versionen (Projekt-Root)
.gitattributes                 ↩️  LF für Skripte (Windows-Host!)
```

---

## 🚀 Loslegen

1. **Voraussetzungen:** Docker Desktop (WSL2-Backend) + VS Code mit der Extension
   *Dev Containers* (`ms-vscode-remote.remote-containers`).
2. Projektordner in VS Code öffnen → **„Reopen in Container“**
   (oder Command Palette → *Dev Containers: Rebuild and Reopen in Container*).
3. Warten, bis `postCreate` durch ist (Firewall-Check + `rokit install`).
4. Im Container-Terminal:
   ```bash
   claude            # 🤖 einloggen & loslegen
   rojo serve        # 🔄 Live-Sync starten (sobald ein *.project.json existiert)
   firewall-check    # 🩺 Firewall prüfen
   ```
5. **Roblox Studio** (auf Windows) → Rojo-Plugin → **Connect** auf `localhost:34872`.

> 🔑 **Login-Hinweis:** Der OAuth-Callback auf einen zufälligen `localhost`-Port wird bewusst
> **nicht** weitergeleitet. Claude Code zeigt dann eine Login-URL – im Browser öffnen,
> anmelden und den angezeigten Code ins Terminal einfügen. Der Login bleibt im Volume
> erhalten, auch nach Rebuilds.

---

## 🛡️ Sicherheitskonzept

### 🔒 Kein Ausbruch auf den Host

- **Nur der Projektordner** ist gemountet – kein Docker-Socket, kein `~/.ssh`,
  keine Cloud-Credentials, kein Home-Verzeichnis.
- **`.devcontainer/` ist im Container read-only.** Claude kann sich also nicht selbst
  mehr Rechte, Ports oder Mounts für den nächsten Rebuild eintragen.
- Gearbeitet wird als **`dev` ohne sudo**, dazu `no-new-privileges` → es gibt keinen Weg zu root.
- **`--cap-drop=ALL`**, nur das Nötigste für Firewall/dnsmasq kommt zurück. Diese Capabilities
  hat nur der root-Prozess des Entrypoints, nie der User `dev`.
- **Netzwerk Richtung Host gesperrt:** `host.docker.internal`, Docker-Gateway,
  Docker-Desktop-VM (`192.168.65.0/24`), das gesamte LAN (RFC1918), Link-Local/Metadata
  (`169.254.0.0/16`), CGNAT, Multicast → **REJECT**. Das gilt auch dann, wenn eine erlaubte Domain
  plötzlich auf eine private IP zeigen sollte (zusätzlich `stop-dns-rebind` in dnsmasq).
- **IPv6 ist komplett aus** (sysctl + ip6tables DROP).
- **SSH-Agent** vom Host wird nicht durchgereicht (`SSH_AUTH_SOCK` leer).

### 🌐 Egress-Firewall – überlebt Cloudflare-IP-Rotation

Viele Ziele (claude.ai, CDNs …) liegen hinter Cloudflare und wechseln ständig ihre IPs.
Statische IP-Listen veralten deshalb schnell, und *alle* Cloudflare-Ranges freizugeben
würde das halbe Internet öffnen. Darum funktioniert die Firewall **DNS-gesteuert**:

```
 Prozess ──DNS──▶ dnsmasq (127.0.0.1, User dnsfw)
                     │ Domain in Allowlist?
                     ├─ nein ─▶ REFUSED  (auch keine DNS-Exfiltration)
                     └─ ja ──▶ Upstream-DNS ──▶ Antwort
                                  │
                                  └─▶ jede IPv4 ──▶ ipset fw-allow-https
 Prozess ──TCP/443──▶ iptables: Ziel-IP im ipset? ─ ja ▶ ✅  / nein ▶ ❌ REJECT
```

- dnsmasq trägt **jede frisch aufgelöste IP sofort** ins ipset ein, und zwar bevor die
  Anwendung die Antwort bekommt. Rotiert Cloudflare, landet die neue IP beim nächsten
  Lookup automatisch im Set. **Kein Cronjob, keine Race-Condition.**
- `cache-size=0` → jeder Lookup geht wirklich upstream und aktualisiert das ipset.
- **Nur der dnsmasq-User** darf den Upstream-DNS (Docker) erreichen. Direkter DNS zu
  `8.8.8.8`/`1.1.1.1` oder an Dockers `127.0.0.11` vorbei ist blockiert.
- Ausgehend sind **nur TCP/443** erlaubt (plus TCP/22 für `github.com` → git über SSH).
  Kein HTTP/80, kein UDP/QUIC.
- Eingehend nur **Loopback** und Antworten auf eigene Verbindungen.
- **Fail-closed:** Policies stehen ab der ersten Zeile auf DROP. Schlägt Setup oder Selbsttest
  fehl → **Lockdown ohne jedes Netzwerk** (Log: `/run/firewall/init.log`).
- Allowlist & Skripte liegen **root-owned im Image** (`/etc/firewall`), nicht im
  beschreibbaren Workspace.

### 📋 Freigegebene Domains (Subdomains inklusive)

| Zweck | Domains |
|---|---|
| 🤖 Claude Code | `api.anthropic.com`, `claude.ai` (inkl. `downloads.claude.ai`), `claude.com`, `platform.claude.com` |
| 🐙 GitHub | `github.com` (+SSH), `githubusercontent.com` |
| 📦 Wally | `api.wally.run` |
| 🧩 VS Code | `update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `marketplace.visualstudio.com`, `gallerycdn.vsassets.io`, `vscode-cdn.net` |

Bewusst **nicht** freigegeben: Telemetrie/Datadog (per Env deaktiviert), claude.ai-MCP-Connectors
(`mcp-proxy.anthropic.com`, per Env deaktiviert), Artifact-Inhalte (`*.frame.claudeusercontent.com`)
sowie npm.

### ➕ Domain freigeben

1. `firewall-check` ausführen → unter „Letzte DNS-Anfragen“ steht, was angefragt wurde.
2. Domain auf dem **Host** in `.devcontainer/firewall/allowed-domains.conf` eintragen
   (im Container ist der Ordner read-only, das ist Absicht).
3. **Dev Containers: Rebuild Container**.

---

## 🎮 Rojo & Roblox Studio

- `rojo serve` lauscht im Container auf `127.0.0.1:34872`.
- VS Code leitet **genau diesen einen Port** auf `localhost:34872` des Windows-Hosts weiter
  (über den eigenen Tunnel, kein `docker -p`). Alle anderen Ports werden ignoriert.
- Im Studio-Rojo-Plugin einfach auf `localhost:34872` verbinden.
- **Claude ↔ Studio:** Claude bearbeitet die Luau-Dateien im Projekt, Rojo synct sie live
  ins Studio. Das ist der vorgesehene, sichere Weg.

> 🧪 **Roblox Studio MCP:** Der offizielle Studio-MCP-Server läuft als lokaler
> stdio-Prozess **auf Windows** (`%LOCALAPPDATA%\Roblox\mcp.bat`). Aus dem Container ist er
> nicht erreichbar, ohne die Host-Isolation aufzubrechen, und deshalb ist er hier **absichtlich
> nicht angebunden**. Wenn du direkten Studio-Zugriff brauchst, nutze dafür eine separate
> Claude-Code-Instanz auf dem Host.

---

## ⚠️ Restrisiken & Empfehlungen

- 📝 **Workspace-Dateien landen auf dem Host.** Claude kann alles im Projektordner ändern.
  Besonders kritisch sind `.git/hooks/*` und `.git/config` (`core.fsmonitor`, `core.hooksPath`):
  Führt **Git auf Windows** (Terminal, GitHub Desktop, TortoiseGit, VS Code lokal) etwas in
  diesem Repo aus, läuft dieser Code **auf dem Host**.
  👉 Git am besten **nur im Container** benutzen, oder vorher `.git/config` und `.git/hooks` prüfen.
  👉 Ebenso `.vscode/` (Tasks/Settings) prüfen, bevor du den Ordner **lokal** (ohne Container) öffnest.
- 🔁 **Vor jedem Rebuild** Änderungen an `.devcontainer/` gegenlesen (im Container
  read-only, aber du könntest sie auf dem Host bearbeiten).
- 🔑 **Git-Credentials:** VS Code reicht standardmäßig den Git-Credential-Helper des Hosts in
  den Container weiter. Wenn Claude **nicht** in deinem Namen pushen soll, deaktiviere das in den
  **User-Settings auf dem Host**: Suche nach *„Dev › Containers: Git Credential Helper Config
  Location“* → `none` und *„Dev › Containers: Copy Git Config“* → aus. Besser: ein fein
  granulares GitHub-Token nur für dieses Repo.
- 🐙 **GitHub ist offen** (für git/Rokit). Damit wäre theoretisch ein Push in fremde Repos
  möglich, wenn Credentials vorhanden sind. Brauchst du kein GitHub, entferne die Zeilen aus der
  Allowlist (dann aber Tools vorher installieren).
- 🧾 **`--dangerously-skip-permissions`** funktioniert hier technisch, schützt aber nicht vor
  Exfiltration zu erlaubten Domains. Empfohlen ist **Auto-Mode** bzw. normale Permission-Prompts.
- 🐢 **Performance:** Bind-Mounts von `E:\` sind unter Windows langsam. Schneller geht es mit
  dem Repo im WSL2-Dateisystem oder per *Clone Repository in Container Volume*.

---

## 🩺 Troubleshooting

| Problem | Lösung |
|---|---|
| ❌ `Firewall nicht bereit` | `cat /run/firewall/init.log` lesen. Der Container ist dann im Lockdown. → Rebuild |
| 🌐 Tool meldet „could not resolve host“ | Domain fehlt in der Allowlist → `firewall-check` → eintragen → Rebuild |
| 🧩 Extension lässt sich nicht installieren | VS-Code-CDN-Domain fehlt → `firewall-check` zeigt sie |
| 🔄 Studio verbindet nicht | Läuft `rojo serve`? Tab *Ports* in VS Code zeigt `34872`? Port auf Windows belegt? |
| 🪟 `bad interpreter: ^M` | CRLF in Skripten → `.gitattributes` greift; der Dockerfile entfernt CR zusätzlich |
| 🔐 Login weg nach Rebuild | Volume `reeky-horror-claude-*` gelöscht? `CLAUDE_CONFIG_DIR` gesetzt? |

---

## 📚 Quellen

- Claude Code: [Dev Containers](https://code.claude.com/docs/en/devcontainer) ·
  [Setup / nativer Installer](https://code.claude.com/docs/en/setup) ·
  [Netzwerk-Anforderungen](https://code.claude.com/docs/en/network-config)
- Referenz-Firewall: [anthropics/claude-code `.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
- [Rojo](https://rojo.space/docs/v7/) · [Rokit](https://github.com/rojo-rbx/rokit) ·
  [Roblox Studio MCP](https://create.roblox.com/docs/en-us/studio/mcp)
- [dnsmasq Manpage (`--ipset`, `--server`, `--no-resolv`)](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
