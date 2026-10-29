# syntax=docker/dockerfile:1
#
# reeky-horror – dev container for Roblox (Rojo + Luau toolchain) with a natively
# installed Claude Code and an egress firewall (iptables + ipset + dnsmasq).
#
# Security model:
#   * The container starts as root ONLY for the entrypoint (firewall setup).
#   * All work happens as the unprivileged user "dev" – no sudo, no capabilities,
#     with no-new-privileges (see devcontainer.json -> runArgs).
#   * Firewall scripts and the allowlist are root-owned inside the image, NOT in the workspace.

FROM debian:trixie-slim

ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000
ARG TZ=Europe/Berlin
# "latest", "stable" or a pinned version such as "2.1.89"
ARG CLAUDE_CODE_VERSION=latest
ARG ROKIT_VERSION=1.2.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=${TZ}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# --- System packages ---------------------------------------------------------
# Deliberately lean: no sudo, no Docker CLI, no compiler.
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

# --- Users -------------------------------------------------------------------
# dev   = working user (VS Code, terminal, Claude Code)
# dnsfw = system user dnsmasq runs as. Only this user may talk to the upstream DNS.
RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
 && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home --shell /bin/bash "${USERNAME}" \
 && useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dnsfw \
 && mkdir -p /workspace /commandhistory "/home/${USERNAME}/.claude" \
 && touch /commandhistory/.bash_history \
 && chown -R "${USERNAME}:${USERNAME}" /workspace /commandhistory "/home/${USERNAME}/.claude"

# --- Firewall & helper scripts (root-owned, read/execute only for dev) --------
COPY firewall/init-firewall.sh        /usr/local/sbin/init-firewall.sh
COPY firewall/allowed-domains.conf    /etc/firewall/allowed-domains.conf
COPY scripts/entrypoint.sh            /usr/local/sbin/container-entrypoint.sh
COPY scripts/firewall-wait.sh         /usr/local/bin/firewall-wait
COPY scripts/firewall-check.sh        /usr/local/bin/firewall-check
COPY scripts/post-create.sh           /usr/local/bin/devcontainer-post-create

# Strip CRLF (Windows host!) and enforce permissions.
RUN for f in /usr/local/sbin/init-firewall.sh /usr/local/sbin/container-entrypoint.sh \
             /usr/local/bin/firewall-wait /usr/local/bin/firewall-check \
             /usr/local/bin/devcontainer-post-create /etc/firewall/allowed-domains.conf; do \
      sed -i 's/\r$//' "$f"; chown root:root "$f"; \
    done \
 && chmod 0700 /usr/local/sbin/init-firewall.sh /usr/local/sbin/container-entrypoint.sh \
 && chmod 0755 /usr/local/bin/firewall-wait /usr/local/bin/firewall-check /usr/local/bin/devcontainer-post-create \
 && chmod 0755 /etc/firewall \
 && chmod 0644 /etc/firewall/allowed-domains.conf

# --- Claude Code (native installer) + Rokit, as user dev ----------------------
USER ${USERNAME}
WORKDIR /home/${USERNAME}

# Native installer -> ~/.local/bin/claude (symlink) + ~/.local/share/claude/versions/
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_CODE_VERSION}" \
 && "/home/${USERNAME}/.local/bin/claude" --version

# Rokit (toolchain manager for Rojo, StyLua, Selene, luau-lsp, Wally, ...)
# Pinned version straight from the GitHub release instead of "curl | bash".
RUN case "$(uname -m)" in \
      x86_64)        arch=x86_64 ;; \
      aarch64|arm64) arch=aarch64 ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
 && tmp="$(mktemp -d)" \
 && curl -fsSL -o "${tmp}/rokit.zip" \
      "https://github.com/rojo-rbx/rokit/releases/download/v${ROKIT_VERSION}/rokit-${ROKIT_VERSION}-linux-${arch}.zip" \
 && unzip -q "${tmp}/rokit.zip" -d "${tmp}" \
 && chmod +x "${tmp}/rokit" \
 && "${tmp}/rokit" self-install \
 && rm -rf "${tmp}"

ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.rokit/bin:${PATH}"

# Persistent bash history + a prompt warning if the firewall is not up
RUN { \
      echo ''; \
      echo '# --- devcontainer ---'; \
      echo 'export HISTFILE=/commandhistory/.bash_history'; \
      echo 'export PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; $PROMPT_COMMAND}"'; \
      echo 'alias fd=fdfind'; \
      echo '[ -f /run/firewall/ready ] || echo "⚠️  Firewall is NOT ready – see /run/firewall/init.log"'; \
    } >> "/home/${USERNAME}/.bashrc"

# --- Runtime -------------------------------------------------------------------
# The container's main process runs as root (firewall setup + sleep only).
# VS Code / terminals / Claude run as "dev" (remoteUser).
USER root
WORKDIR /workspace

ENTRYPOINT ["/usr/local/sbin/container-entrypoint.sh"]
CMD ["sleep", "infinity"]
