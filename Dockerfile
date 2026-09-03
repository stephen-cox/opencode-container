# Remote dev environment for OpenCode + Openchamber.
# Route Openchamber 3000 externally. OpenCode 4096 binds 0.0.0.0 by default --
# protect with trusted network or front it with auth. Shell access is sshd on
# 2222, key authentication only.

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# bash with pipefail: a failed `curl` in a `curl ... | sh` pipeline must fail
# the build rather than feeding an empty script to the shell.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg tzdata locales sudo \
        rsync less tini \
        git openssh-client openssh-server \
        ripgrep fd-find jq \
        python3 python3-venv python3-pip python3-requests \
        python-is-python3 \
        tmux nano neovim mosh \
        direnv \
    && locale-gen en_US.UTF-8 \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && mkdir -p /run/sshd /etc/ssh/host-keys \
    && printf '%s\n' \
        'Port 2222' \
        'PermitRootLogin no' \
        'PasswordAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'PubkeyAuthentication yes' \
        'AllowUsers dev' \
        'HostKey /etc/ssh/host-keys/ssh_host_ed25519_key' \
        'AuthorizedKeysFile /etc/ssh/authorized_keys/%u .ssh/authorized_keys' \
        'ClientAliveInterval 30' \
        'ClientAliveCountMax 3' \
        'LoginGraceTime 30' \
        'MaxAuthTries 3' \
        > /etc/ssh/sshd_config.d/00-opencode.conf \
    && chmod 0644 /etc/ssh/sshd_config.d/00-opencode.conf \
    && printf '%s\n' \
        'if [ -n "${SSH_TTY:-}" ] && [ -z "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then' \
        '    exec tmux new -A -s main -c /workspace' \
        'fi' \
        > /etc/profile.d/tmux-attach.sh \
    && chmod 0644 /etc/profile.d/tmux-attach.sh \
    && printf '%s\n' \
        'export SSH_AUTH_SOCK=/home/dev/.ssh-agent.sock' \
        > /etc/profile.d/ssh-agent.sh \
    && chmod 0644 /etc/profile.d/ssh-agent.sh \
    && printf '%s\n' \
        'Host *' \
        '    UserKnownHostsFile /home/dev/.ssh-state/known_hosts' \
        > /etc/ssh/ssh_config.d/00-known-hosts.conf \
    && chmod 0644 /etc/ssh/ssh_config.d/00-known-hosts.conf \
    && rm -rf /var/lib/apt/lists/*

# System-wide tmux defaults; a user's ~/.tmux.conf still overrides these.
# Mouse support gives touch scrolling in mobile SSH clients (Blink, Termius).
RUN printf '%s\n' \
        'set -g mouse on' \
        'set -g history-limit 50000' \
        > /etc/tmux.conf \
    && chmod 0644 /etc/tmux.conf

RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
        -o /usr/local/bin/yq \
    && chmod 0755 /usr/local/bin/yq

# Node 26 via NodeSource's distro-agnostic `nodistro` repo. The version check
# fails the build if the repo setup silently no-ops, which would otherwise leave
# the distro's Node 22 installed and only surface at runtime.
RUN set -eux; \
    curl -fsSL https://deb.nodesource.com/setup_26.x | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    node_version="$(node --version)"; \
    case "${node_version}" in \
        v26.*) echo "installed node ${node_version}" ;; \
        *) echo "ERROR: expected Node 26.x, got ${node_version}" >&2; exit 1 ;; \
    esac; \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | UV_INSTALL_DIR=/usr/local/bin sh

# `npm cache clean` matters here: `npm install -g` leaves the downloaded
# tarballs in /root/.npm, and without the clean they are committed into this
# layer for the life of the image.
RUN npm install -g --omit=dev \
        backlog.md \
        opencode-ai \
        @openchamber/web \
        chrome-devtools-mcp \
    && npm cache clean --force \
    && rm -rf /usr/lib/node_modules/opencode-ai/node_modules/*-baseline

ARG DEV_UID=1000
ARG DEV_GID=1000
RUN set -eux; \
    existing_group="$(getent group "${DEV_GID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_group}" ]; then \
        if [ "${existing_group}" != dev ]; then groupmod -n dev "${existing_group}"; fi; \
    else \
        groupadd -g "${DEV_GID}" dev; \
    fi; \
    existing_user="$(getent passwd "${DEV_UID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ]; then \
        if [ "${existing_user}" != dev ]; then usermod -l dev "${existing_user}"; fi; \
        usermod -u "${DEV_UID}" -g "${DEV_GID}" -d /home/dev -m -s /bin/bash dev; \
    else \
        useradd -m -u "${DEV_UID}" -g "${DEV_GID}" -s /bin/bash dev; \
    fi; \
    usermod -aG sudo dev; \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev; \
    chmod 0440 /etc/sudoers.d/dev; \
    mkdir -p \
        /workspace \
        /home/dev/.ssh-state \
        /home/dev/.config/opencode \
        /home/dev/.config/openchamber \
        /home/dev/.local/share/opencode \
        /home/dev/.local/state/opencode; \
    chown -R dev:dev /workspace /home/dev/.ssh-state /home/dev/.config /home/dev/.local

COPY --chmod=0755 start.sh /usr/local/bin/start.sh

USER dev
WORKDIR /workspace

ENV HOME=/home/dev \
    SHELL=/bin/bash \
    PATH=/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 3000 4096 2222 60000/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3000/ >/dev/null || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/start.sh"]
