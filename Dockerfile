# Remote dev environment for OpenCode + Openchamber.
# Route Openchamber 3000 externally. OpenCode 4096 binds 0.0.0.0 by default --
# protect with trusted network or front it with auth. sshd 2222 is key-only.

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# bash with pipefail: a failed `curl` in a `curl ... | sh` pipeline must fail
# the build rather than feeding an empty script to the shell.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg tzdata locales sudo \
        rsync less tini \
        git openssh-client openssh-server \
        ripgrep fd-find jq \
        build-essential libffi-dev libssl-dev \
        python3 python3-venv python3-pip python3-dev python3-full python3-requests \
        python-is-python3 \
        tmux nano neovim \
        direnv \
    && locale-gen en_US.UTF-8 \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
    && mkdir -p /run/sshd /etc/ssh/host-keys \
    && printf 'Port 2222\nPermitRootLogin no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nPubkeyAuthentication yes\nAllowUsers dev\nHostKey /etc/ssh/host-keys/ssh_host_ed25519_key\n' \
        > /etc/ssh/sshd_config.d/00-opencode.conf \
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

RUN npm install -g --omit=dev \
        backlog.md \
        opencode-ai \
        @openchamber/web \
        @anthropic-ai/claude-code \
        @openai/codex

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
    mkdir -p /workspace /home/dev/.ssh-state; \
    chown dev:dev /workspace /home/dev/.ssh-state

COPY --chmod=0755 start.sh /usr/local/bin/start.sh

USER dev
WORKDIR /workspace

ENV HOME=/home/dev \
    SHELL=/bin/bash \
    PATH=/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 3000 4096 2222

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3000/ >/dev/null || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/start.sh"]
