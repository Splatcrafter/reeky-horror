# syntax=docker/dockerfile:1
#
# reeky-horror – Dev-Container für Roblox (Rojo + Luau-Toolchain) mit nativ
# installiertem Claude Code und einer Egress-Firewall (iptables + ipset + dnsmasq).
#
# Sicherheitsprinzip:
#   * Der Container startet als root NUR für den Entrypoint (Firewall aufsetzen).
#   * Gearbeitet wird als unprivilegierter User "dev" – ohne sudo, ohne Capabilities,
#     mit no-new-privileges (siehe devcontainer.json -> runArgs).
#   * Firewall-Skripte und Allowlist liegen root-owned im Image, NICHT im Workspace.

FROM debian:trixie-slim

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG TZ=Europe/Berlin
# "latest", "stable" oder eine feste Version wie "2.1.89"
ARG CLAUDE_CODE_VERSION=latest
ARG ROKIT_VERSION=1.2.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- System-Pakete -----------------------------------------------------------
# Bewusst schlank: kein sudo, kein Docker-CLI, kein Compiler.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      bash-completion \
      bind9-dnsutils \
      ca-certificates \
      curl \
      dnsmasq-base \
      fd-find \
      git \
      iproute2 \
      ipset \
      iptables \
      jq \
      less \
      nano \
      openssh-client \
      procps \
      ripgrep \
      tzdata \
      unzip \
 && ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime \
 && echo "${TZ}" > /etc/timezone \
 && rm -rf /var/lib/apt/lists/*

# --- User -------------------------------------------------------------------
# dev   = Arbeits-User (VS Code, Terminal, Claude Code)
# dnsfw = System-User, unter dem dnsmasq läuft. Nur dieser darf Upstream-DNS sprechen.
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
 && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dnsfw \
 && mkdir -p /workspace /commandhistory "/home/${USERNAME}/.claude" \
 && touch /commandhistory/.bash_history \
 && chown -R "${USERNAME}:${USERNAME}" /workspace /commandhistory "/home/${USERNAME}/.claude"

# --- Firewall & Hilfsskripte (root-owned, für dev nur les-/ausführbar) ---------
COPY firewall/init-firewall.sh        /usr/local/sbin/init-firewall.sh
COPY firewall/allowed-domains.conf    /etc/firewall/allowed-domains.conf
COPY scripts/entrypoint.sh            /usr/local/sbin/container-entrypoint.sh
COPY scripts/firewall-wait.sh         /usr/local/bin/firewall-wait
COPY scripts/firewall-check.sh        /usr/local/bin/firewall-check
COPY scripts/post-create.sh           /usr/local/bin/devcontainer-post-create

# CRLF entfernen (Windows-Host!) und Rechte hart setzen.
RUN for f in /usr/local/sbin/init-firewall.sh /usr/local/sbin/container-entrypoint.sh \
             /usr/local/bin/firewall-wait /usr/local/bin/firewall-check \
             /usr/local/bin/devcontainer-post-create /etc/firewall/allowed-domains.conf; do \
      sed -i 's/\r$//' "$f"; chown root:root "$f"; \
    done \
 && chmod 0700 /usr/local/sbin/init-firewall.sh /usr/local/sbin/container-entrypoint.sh \
 && chmod 0755 /usr/local/bin/firewall-wait /usr/local/bin/firewall-check /usr/local/bin/devcontainer-post-create \
 && chmod 0755 /etc/firewall \
 && chmod 0644 /etc/firewall/allowed-domains.conf

# --- Claude Code (nativer Installer) + Rokit, als User dev --------------------
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Nativer Installer -> ~/.local/bin/claude (Symlink) + ~/.local/share/claude/versions/
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
 && "/home/${USERNAME}/.local/bin/claude" --version

# Rokit (Toolchain-Manager für Rojo, StyLua, Selene, luau-lsp, Wally …)
# Gepinnte Version direkt aus dem GitHub-Release statt "curl | bash".
RUN case "$(uname -m)" in \
      x86_64)        arch=x86_64 ;; \
      aarch64|arm64) arch=aarch64 ;; \
      *) echo "Nicht unterstützte Architektur: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && tmp="$(mktemp -d)" \
 && curl -fsSL -o "${tmp}/rokit.zip" \
      "https://github.com/rojo-rbx/rokit/releases/download/v${ROKIT_VERSION}/rokit-${ROKIT_VERSION}-linux-${arch}.zip" \
 && unzip -q "${tmp}/rokit.zip" -d "${tmp}" \
 && chmod +x "${tmp}/rokit" \
 && "${tmp}/rokit" self-install \
 && rm -rf "${tmp}"

ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.rokit/bin:${PATH}"

# Persistente Bash-History + kleiner Prompt-Hinweis zum Firewall-Status
RUN { \
      echo ''; \
      echo '# --- devcontainer ---'; \
      echo 'export HISTFILE=/commandhistory/.bash_history'; \
      echo 'export PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"'; \
      echo 'alias fd=fdfind'; \
      echo '[ -f /run/firewall/ready ] || echo "⚠️  Firewall ist NICHT bereit – siehe /run/firewall/init.log"'; \
    } >> "/home/${USERNAME}/.bashrc"

# --- Laufzeit ---------------------------------------------------------------
# Der Container-Hauptprozess läuft als root (nur Firewall-Setup + sleep).
# VS Code / Terminals / Claude laufen als "dev" (remoteUser).
USER root
WORKDIR /workspace

ENTRYPOINT ["/usr/local/sbin/container-entrypoint.sh"]
CMD ["sleep", "infinity"]
