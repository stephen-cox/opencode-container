#!/usr/bin/env bash
set -euo pipefail

OPENCODE_HOSTNAME="${OPENCODE_HOSTNAME:-0.0.0.0}"
OPENCODE_PORT="${OPENCODE_PORT:-4096}"
OPENCHAMBER_PORT="${OPENCHAMBER_PORT:-3000}"
WEB_TERMINAL_PORT="${WEB_TERMINAL_PORT:-7681}"
WEB_TERMINAL_USER="${WEB_TERMINAL_USER:-dev}"
OPENCODE_READY_TIMEOUT="${OPENCODE_READY_TIMEOUT:-30}"

if [ -z "${OPENCHAMBER_PASSWORD:-}" ]; then
    echo "ERROR: OPENCHAMBER_PASSWORD must be set (use a dummy value if ingress auth handles access)" >&2
    exit 1
fi

# The web terminal is a root-equivalent shell (dev has passwordless sudo), so it
# never starts unauthenticated. Falling back to OPENCHAMBER_PASSWORD keeps
# single-secret deployments working.
if [ -z "${WEB_TERMINAL_PASSWORD:-}" ]; then
    echo "[start] WEB_TERMINAL_PASSWORD unset; reusing OPENCHAMBER_PASSWORD for the web terminal"
    WEB_TERMINAL_PASSWORD="${OPENCHAMBER_PASSWORD}"
fi

mkdir -p /tmp/logs
cd /workspace

dump_logs() {
    for log in /tmp/logs/opencode.log /tmp/logs/openchamber.log /tmp/logs/ttyd.log /tmp/logs/ssh-agent.log; do
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

# ttyd hands every client the same tmux session, so a dropped browser tab or a
# reconnect from another device resumes the same shell. `bash -l` first so
# /etc/profile.d sets SSH_AUTH_SOCK for the agent started above.
echo "[start] ttyd web terminal on :${WEB_TERMINAL_PORT}"
ttyd \
    --port "${WEB_TERMINAL_PORT}" \
    --interface 0.0.0.0 \
    --credential "${WEB_TERMINAL_USER}:${WEB_TERMINAL_PASSWORD}" \
    --writable \
    --client-option 'titleFixed=opencode' \
    --client-option 'fontSize=14' \
    --client-option 'scrollback=10000' \
    --client-option 'disableLeaveAlert=true' \
    bash -lc 'exec tmux new -A -s main -c /workspace' \
    >/tmp/logs/ttyd.log 2>&1 &
ttyd_pid=$!

tail -F /tmp/logs/*.log &
tail_pid=$!

cleanup() {
    trap - EXIT INT TERM
    kill "${opencode_pid}" "${openchamber_pid}" "${ssh_agent_pid}" "${ttyd_pid}" "${tail_pid}" 2>/dev/null || true
    wait "${opencode_pid}" "${openchamber_pid}" "${ssh_agent_pid}" "${ttyd_pid}" "${tail_pid}" 2>/dev/null || true
}

wait_for_exit() {
    while true; do
        for name_pid in \
            "opencode:${opencode_pid}" \
            "openchamber:${openchamber_pid}" \
            "ttyd:${ttyd_pid}" \
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
