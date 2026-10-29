# 👻 reeky-horror – Dev Container

A locked-down development container for the Roblox game **reeky-horror**:
Rojo + Luau toolchain, **natively installed Claude Code**, an **egress firewall** that only
lets allowlisted domains through, and **no way back to the host**.

---

## 📦 What's inside?

| Area | Contents |
|---|---|
| 🐧 Base | `debian:trixie-slim`, user **`dev`** (UID 1000), **no sudo** |
| 🤖 Claude Code | Native installer (`claude.ai/install.sh`) → `~/.local/bin/claude`, auto-update enabled |
| 🧰 Toolchain | [Rokit](https://github.com/rojo-rbx/rokit) + `rokit.toml` in the project root: **Rojo**, **StyLua**, **Selene**, **luau-lsp**, **Wally** |
| 🧩 VS Code extensions | Claude Code, Rojo, Luau LSP, StyLua, Selene |
| 🛡️ Firewall | iptables + ipset + dnsmasq (DNS-driven allowlist) |
| 🔌 Port | only **34872** (Rojo) via VS Code port forwarding |
| 💾 Volumes | `~/.claude` (login/settings/sessions) and bash history, isolated per project |
| 🛠️ Extras | git, ripgrep, fd, jq, curl, dig, nano, less |

## 🗂️ Files

```
.devcontainer/
├── devcontainer.json          ⚙️  container config (privileges, mounts, port, extensions)
├── Dockerfile                 🐳 image (tools, Claude Code, Rokit, users)
├── README.md                  📖 this file
├── firewall/
│   ├── init-firewall.sh       🧱 firewall setup (runs as root in the entrypoint)
│   └── allowed-domains.conf   📋 allowlist – allow domains HERE
└── scripts/
    ├── entrypoint.sh          🚪 container start: firewall → sleep infinity
    ├── firewall-wait.sh       ⏳ waits until the firewall is up (postStart)
    ├── firewall-check.sh      🩺 `firewall-check` – self-test for you
    └── post-create.sh         🧰 one-time: git safe.directory + `rokit install`
rokit.toml                     🔧 tool versions (project root)
.gitattributes                 ↩️  LF for scripts (Windows host!)
```

---

## 🚀 Getting started

1. **Prerequisites:** Docker Desktop (WSL2 backend) + VS Code with the
   *Dev Containers* extension (`ms-vscode-remote.remote-containers`).
2. Open the project folder in VS Code → **"Reopen in Container"**
   (or Command Palette → *Dev Containers: Rebuild and Reopen in Container*).
3. Wait for `postCreate` to finish (firewall check + `rokit install`).
4. In the container terminal:
   ```bash
   claude            # 🤖 log in & get going
   rojo serve        # 🔄 start live sync (once a *.project.json exists)
   firewall-check    # 🩺 check the firewall
   ```
5. **Roblox Studio** (on Windows) → Rojo plugin → **Connect** to `localhost:34872`.

> 🔑 **Login note:** The OAuth callback to a random `localhost` port is deliberately
> **not** forwarded. Claude Code then shows a login URL – open it in your browser,
> sign in and paste the code shown into the terminal. The login persists in the volume,
> even across rebuilds.

---

## 🛡️ Security model

### 🔒 No escape to the host

- **Only the project folder** is mounted – no Docker socket, no `~/.ssh`,
  no cloud credentials, no home directory.
- **`.devcontainer/` is read-only inside the container**, so Claude can't grant itself
  extra privileges, ports or mounts for the next rebuild.
- All work happens as **`dev` without sudo**, plus `no-new-privileges` → there is no path to root.
- **`--cap-drop=ALL`**, with only the minimum added back for firewall/dnsmasq. Those
  capabilities belong to the entrypoint's root process only, never to user `dev`.
- **Network towards the host is blocked:** `host.docker.internal`, the Docker gateway,
  the Docker Desktop VM (`192.168.65.0/24`), the entire LAN (RFC1918), link-local/metadata
  (`169.254.0.0/16`), CGNAT and multicast → **REJECT**. This also applies if an allowed domain
  suddenly resolves to a private IP (plus `stop-dns-rebind` in dnsmasq).
- **IPv6 is fully disabled** (sysctl + ip6tables DROP).
- The host's **SSH agent** is not forwarded (`SSH_AUTH_SOCK` empty).

### 🌐 Egress firewall – survives Cloudflare IP rotation

Many targets (claude.ai, CDNs, ...) sit behind Cloudflare and change IPs constantly.
Static IP lists go stale quickly, and allowing *all* Cloudflare ranges would open up half the
internet. That's why the firewall is **DNS-driven**:

```
 process ──DNS──▶ dnsmasq (127.0.0.1, user dnsfw)
                     │ domain in allowlist?
                     ├─ no ──▶ REFUSED  (also no DNS exfiltration)
                     └─ yes ─▶ upstream DNS ──▶ answer
                                  │
                                  └─▶ every IPv4 ──▶ ipset fw-allow-https
 process ──TCP/443──▶ iptables: destination IP in ipset? ─ yes ▶ ✅  / no ▶ ❌ REJECT
```

- dnsmasq adds **every freshly resolved IP to the ipset immediately**, before the application
  receives the answer. When Cloudflare rotates, the new IP lands in the set on the next lookup.
  **No cron job, no race condition.**
- `cache-size=0` → every lookup really goes upstream and refreshes the ipset.
- **Only the dnsmasq user** may reach the upstream DNS (Docker). Direct DNS to
  `8.8.8.8`/`1.1.1.1`, or bypassing it via Docker's `127.0.0.11`, is blocked.
- Outbound, **only TCP/443** is allowed (plus TCP/22 for `github.com` → git over SSH).
  No HTTP/80, no UDP/QUIC.
- Inbound, only **loopback** and replies to our own connections.
- **Fail-closed:** policies are DROP from the very first line. If setup or the self-test
  fails → **lockdown without any network** (log: `/run/firewall/init.log`).
- Allowlist & scripts are **root-owned inside the image** (`/etc/firewall`), not in the
  writable workspace.

### 📋 Allowed domains (subdomains included)

| Purpose | Domains |
|---|---|
| 🤖 Claude Code | `api.anthropic.com`, `claude.ai` (incl. `downloads.claude.ai`), `claude.com`, `platform.claude.com` |
| 🐙 GitHub | `github.com` (+SSH), `githubusercontent.com` |
| 📦 Wally | `api.wally.run` |
| 🧩 VS Code | `update.code.visualstudio.com`, `vscode.download.prss.microsoft.com`, `marketplace.visualstudio.com`, `gallerycdn.vsassets.io`, `vscode-cdn.net` |

Deliberately **not** allowed: telemetry/Datadog (disabled via env), claude.ai MCP connectors
(`mcp-proxy.anthropic.com`, disabled via env), artifact content (`*.frame.claudeusercontent.com`)
and npm.

### ➕ Allowing a domain

1. Run `firewall-check` → "Recent DNS queries" shows what was requested.
2. Add the domain on the **host** to `.devcontainer/firewall/allowed-domains.conf`
   (the folder is read-only inside the container – on purpose).
3. **Dev Containers: Rebuild Container**.

---

## 🎮 Rojo & Roblox Studio

- `rojo serve` listens inside the container on `127.0.0.1:34872`.
- VS Code forwards **exactly this one port** to `localhost:34872` on the Windows host
  (through its own tunnel, no `docker -p`). All other ports are ignored.
- In the Studio Rojo plugin, simply connect to `localhost:34872`.
- **Claude ↔ Studio:** Claude edits the Luau files in the project and Rojo syncs them live
  into Studio. That's the intended, safe workflow.

> 🧪 **Roblox Studio MCP:** The official Studio MCP server runs as a local stdio process
> **on Windows** (`%LOCALAPPDATA%\Roblox\mcp.bat`). It can't be reached from the container
> without breaking host isolation, so it is **intentionally not connected** here. If you need
> direct Studio access, use a separate Claude Code instance on the host for that.

---

## ⚠️ Residual risks & recommendations

- 📝 **Workspace files end up on the host.** Claude can change anything in the project folder.
  Especially critical are `.git/hooks/*` and `.git/config` (`core.fsmonitor`, `core.hooksPath`):
  if **Git on Windows** (terminal, GitHub Desktop, TortoiseGit, local VS Code) runs anything in
  this repo, that code runs **on the host**.
  👉 Ideally use Git **only inside the container**, or review `.git/config` and `.git/hooks` first.
  👉 Likewise, review `.vscode/` (tasks/settings) before opening the folder **locally** (without the container).
- 🔁 **Before every rebuild**, review changes to `.devcontainer/` (read-only inside the
  container, but you could edit them on the host).
- 🔑 **Git credentials:** By default VS Code forwards the host's Git credential helper into the
  container. If Claude should **not** be able to push on your behalf, disable this in your
  **user settings on the host**: search for *"Dev › Containers: Git Credential Helper Config
  Location"* → `none` and *"Dev › Containers: Copy Git Config"* → off. Better still: a
  fine-grained GitHub token scoped to this repo only.
- 🐙 **GitHub is open** (for git/Rokit). In theory this allows pushing to other repos if
  credentials are available. If you don't need GitHub, remove those lines from the allowlist
  (but install the tools beforehand).
- 🧾 **`--dangerously-skip-permissions`** technically works here, but doesn't protect against
  exfiltration to allowed domains. **Auto mode** or regular permission prompts are recommended.
- 🐢 **Performance:** Bind mounts from `E:\` are slow on Windows. It's faster with the repo in
  the WSL2 file system or via *Clone Repository in Container Volume*.

---

## 🩺 Troubleshooting

| Problem | Solution |
|---|---|
| ❌ `Firewall not ready` | Read `cat /run/firewall/init.log`. The container is then in lockdown. → Rebuild |
| 🌐 Tool reports "could not resolve host" | Domain missing from the allowlist → `firewall-check` → add it → rebuild |
| 🧩 Extension won't install | A VS Code CDN domain is missing → `firewall-check` shows it |
| 🔄 Studio won't connect | Is `rojo serve` running? Does the *Ports* tab in VS Code show `34872`? Port in use on Windows? |
| 🪟 `bad interpreter: ^M` | CRLF in scripts → `.gitattributes` handles it; the Dockerfile also strips CR |
| 🔐 Login gone after rebuild | Volume `reeky-horror-claude-*` deleted? `CLAUDE_CONFIG_DIR` set? |

---

## 📚 Sources

- Claude Code: [Dev containers](https://code.claude.com/docs/en/devcontainer) ·
  [Setup / native installer](https://code.claude.com/docs/en/setup) ·
  [Network requirements](https://code.claude.com/docs/en/network-config)
- Reference firewall: [anthropics/claude-code `.devcontainer`](https://github.com/anthropics/claude-code/tree/main/.devcontainer)
- [Rojo](https://rojo.space/docs/v7/) · [Rokit](https://github.com/rojo-rbx/rokit) ·
  [Roblox Studio MCP](https://create.roblox.com/docs/en-us/studio/mcp)
- [dnsmasq man page (`--ipset`, `--server`, `--no-resolv`)](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html)
