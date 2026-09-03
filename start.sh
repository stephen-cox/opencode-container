#!/usr/bin/env bash
set -euo pipefail

OPENCODE_HOSTNAME="${OPENCODE_HOSTNAME:-0.0.0.0}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
SSHD_PORT="${SSHD_PORT:-2222}"
OPENCODE_READY_TIMEOUT="${OPENCODE_READY_TIMEOUT:-30}"

if [ -z "${OPENCHAMBER_PASSWORD:-}" ]; then
    echo "ERROR: OPENCHAMBER_PASSWORD must be set (use a dummy value if ingress auth handles access)" >&2
    exit 1
fi

# sshd allows key authentication only, so an authorized_keys file is the minimum
# viable credential. Fail closed rather than start an unreachable sshd.
if [ ! -s "${HOME}/.ssh/authorized_keys" ]; then
    echo "ERROR: ${HOME}/.ssh/authorized_keys is missing or empty; sshd allows key auth only" >&2
    exit 1
fi

if [ -n "${GIT_USER_NAME:-}" ]; then
    echo "[start] configuring global Git user name"
    git config --global user.name "${GIT_USER_NAME}"
fi

if [ -n "${GIT_USER_EMAIL:-}" ]; then
    echo "[start] configuring global Git user email"
    git config --global user.email "${GIT_USER_EMAIL}"
fi

mkdir -p /tmp/logs
cd /workspace

dump_logs() {
    for log in /tmp/logs/opencode.log /tmp/logs/openchamber.log /tmp/logs/sshd.log /tmp/logs/ssh-agent.log; do
        if [ -f "${log}" ]; then
            echo "==> ${log} <=="
            sed -n '1,200p' "${log}" || true
        fi
    done
}

echo "[start] opencode serve on ${OPENCODE_HOSTNAME}:${OPENCODE_PORT}"
opencode serve --hostname "${OPENCODE_HOSTNAME}" --port "${OPENCODE_PORT}" \
    >/tmp/logs/opencode.log 2>&1 &
opencode_pid=$!

echo "[start] waiting up to ${OPENCODE_READY_TIMEOUT}s for opencode on 127.0.0.1:${OPENCODE_PORT}"
for second in $(seq 1 "${OPENCODE_READY_TIMEOUT}"); do
    if ! kill -0 "${opencode_pid}" 2>/dev/null; then
        echo "ERROR: opencode exited before becoming ready" >&2
        dump_logs >&2
        exit 1
    fi
    if timeout 1 bash -c "</dev/tcp/127.0.0.1/${OPENCODE_PORT}" 2>/dev/null; then
        echo "[start] opencode is accepting connections"
        break
    fi
    if [ "${second}" = "${OPENCODE_READY_TIMEOUT}" ]; then
        echo "ERROR: timed out waiting for opencode on 127.0.0.1:${OPENCODE_PORT}" >&2
        dump_logs >&2
        exit 1
    fi
    sleep 1
done

echo "[start] clearing stale openchamber state on :${OPENCHAMBER_PORT}"
openchamber stop --port "${OPENCHAMBER_PORT}" >/tmp/logs/openchamber-stop.log 2>&1 || true

echo "[start] openchamber on :${OPENCHAMBER_PORT}"
OPENCODE_HOST="http://127.0.0.1:${OPENCODE_PORT}" OPENCODE_SKIP_START=true \
    openchamber serve \
    --host 0.0.0.0 \
    --port "${OPENCHAMBER_PORT}" \
    --ui-password "${OPENCHAMBER_PASSWORD}" \
    --foreground \
    >/tmp/logs/openchamber.log 2>&1 &
openchamber_pid=$!

echo "[start] ssh-agent on /home/dev/.ssh-agent.sock"
rm -f /home/dev/.ssh-agent.sock
ssh-agent -D -a /home/dev/.ssh-agent.sock \
    >/tmp/logs/ssh-agent.log 2>&1 &
ssh_agent_pid=$!

# sshd needs root to bind and manage ptys; it runs via passwordless sudo while
# everything else stays under the `dev` entrypoint user. The host key lives on
# a persisted path so client fingerprints survive container restarts. The
# ClientAlive keepalives in sshd_config reap dead mobile clients instead of
# leaving them holding the shared tmux session.
echo "[start] sshd on :${SSHD_PORT}"
sudo mkdir -p /run/sshd /etc/ssh/host-keys
if [ ! -f /etc/ssh/host-keys/ssh_host_ed25519_key ]; then
    sudo ssh-keygen -q -t ed25519 -f /etc/ssh/host-keys/ssh_host_ed25519_key -N ''
fi
sudo /usr/sbin/sshd -D -e -p "${SSHD_PORT}" \
    >/tmp/logs/sshd.log 2>&1 &
sshd_pid=$!

tail -F /tmp/logs/*.log &
tail_pid=$!

cleanup() {
    trap - EXIT INT TERM
    kill "${opencode_pid}" "${openchamber_pid}" "${ssh_agent_pid}" "${tail_pid}" 2>/dev/null || true
    sudo kill "${sshd_pid}" 2>/dev/null || true
    wait "${opencode_pid}" "${openchamber_pid}" "${ssh_agent_pid}" "${tail_pid}" 2>/dev/null || true
}

wait_for_exit() {
    while true; do
        for name_pid in \
            "opencode:${opencode_pid}" \
            "openchamber:${openchamber_pid}" \
            "sshd:${sshd_pid}" \
            "ssh-agent:${ssh_agent_pid}"; do
            name="${name_pid%%:*}"
            pid="${name_pid#*:}"
            if ! kill -0 "${pid}" 2>/dev/null; then
                wait "${pid}" 2>/dev/null
                exit_code=$?
                echo "ERROR: ${name} exited with status ${exit_code}" >&2
                dump_logs >&2
                return "${exit_code}"
            fi
        done
        sleep 1
    done
}

trap cleanup EXIT INT TERM
wait_for_exit
exit_code=$?
cleanup
exit "${exit_code}"
