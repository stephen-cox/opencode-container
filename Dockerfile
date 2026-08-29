# Remote dev environment for OpenCode + Openchamber.
# Route Openchamber 3000 externally. OpenCode 4096 binds 0.0.0.0 by default --
# protect with trusted network or front it with auth. Shell access is the ttyd
# web terminal on 7681, behind HTTP basic auth.

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
        git openssh-client \
        ripgrep fd-find jq \
        python3 python3-venv python3-pip python3-requests \
        python-is-python3 \
        tmux nano neovim \
        direnv \
    && locale-gen en_US.UTF-8 \
    && ln -s /usr/bin/fdfind /usr/local/bin/fd \
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

# ttyd serves the web terminal. Static upstream binary, checksum-verified: the
# distro package lags and a silently-truncated download would otherwise only
# surface as a broken terminal at runtime.
ARG TTYD_VERSION=1.7.7
RUN set -eux; \
    case "$(dpkg --print-architecture)" in \
        amd64) ttyd_arch=x86_64 ;; \
        arm64) ttyd_arch=aarch64 ;; \
        *) echo "ERROR: unsupported architecture for ttyd: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}"; \
    curl -fsSL "${base}/ttyd.${ttyd_arch}" -o /usr/local/bin/ttyd; \
    curl -fsSL "${base}/SHA256SUMS" -o /tmp/ttyd.sums; \
    expected="$(awk -v f="ttyd.${ttyd_arch}" '$2 == f { print $1 }' /tmp/ttyd.sums)"; \
    test -n "${expected}"; \
    echo "${expected}  /usr/local/bin/ttyd" | sha256sum -c -; \
    rm -f /tmp/ttyd.sums; \
    chmod 0755 /usr/local/bin/ttyd; \
    ttyd --version

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
    mkdir -p /workspace /home/dev/.ssh-state; \
    chown dev:dev /workspace /home/dev/.ssh-state

COPY --chmod=0755 start.sh /usr/local/bin/start.sh

USER dev
WORKDIR /workspace

ENV HOME=/home/dev \
    SHELL=/bin/bash \
    PATH=/home/dev/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

EXPOSE 3000 4096 7681

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -fsS http://127.0.0.1:3000/ >/dev/null || exit 1

ENTRYPOINT ["tini", "--", "/usr/local/bin/start.sh"]
