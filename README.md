# Remote coding container

A browser-based remote dev environment — OpenCode and OpenChamber in one
container, with key-only SSH for shell access (and Mosh for mobile). Runs
under Docker or Kubernetes; [`kubernetes.yaml`](kubernetes.yaml) is a worked
MicroK8s example (no Helm chart).

## What's inside

OpenCode, OpenChamber, backlog.md, GitHub CLI, uv, Node 26, Python 3.14, git,
tmux, neovim, nano, ripgrep, fd, jq, yq, direnv, mosh.

There is no C toolchain — `build-essential` and `python3-dev` are left out to
keep the image small, and prebuilt wheels and npm prebuilds cover normal use. If
you need to compile something:

```bash
sudo apt-get update && sudo apt-get install -y build-essential python3-dev
```

## Quick start

```bash
docker run -d --name opencode \
    -p 3000:3000 -p 2222:2222 -p 60000:60000/udp \
    -e OPENCHAMBER_PASSWORD='<ui-password>' \
    -e GIT_USER_NAME='Your Name' \
    -e GIT_USER_EMAIL='you@example.com' \
    -v "${PWD}:/workspace" \
    -v "${HOME}/.ssh:/home/dev/.ssh:ro" \
    -v opencode-host-keys:/etc/ssh/host-keys \
    ghcr.io/stephen-cox/opencode-container:latest
```

- SSH: `ssh -p 2222 dev@localhost` — public key in your `~/.ssh/authorized_keys`.
- Mosh (optional, mobile): `mosh -p 60000 --ssh="ssh -p 2222" dev@localhost`.
- OpenChamber: <http://localhost:3000>.

### Chrome DevTools MCP

The Compose deployment adds Chrome for Testing as a hardened, headless sidecar
while OpenCode runs the `chrome-devtools-mcp` process locally over stdio:

```bash
export OPENCHAMBER_PASSWORD='<ui-password>'
export SSH_AUTHORIZED_KEYS_DIR="${HOME}/.ssh"
export GIT_USER_NAME='Your Name'
export GIT_USER_EMAIL='you@example.com'
# Optional: export CONTEXT7_API_KEY='<context7-api-key>'
export WORKSPACE="${PWD}"
docker compose up -d --build
```

The two containers share a network namespace. Chrome therefore binds its DevTools
endpoint only to `127.0.0.1:9222`; that port is not published to the host. Confirm
the browser and MCP server from the OpenCode container:

```bash
docker compose exec opencode \
    curl -fsS http://127.0.0.1:9222/json/version
docker compose exec opencode opencode mcp list
```

Then ask OpenCode: `Use chrome-devtools to open https://developers.chrome.com
and take a snapshot.` The Chrome profile is ephemeral and is discarded whenever
the sidecar is recreated. Stop the deployment with `docker compose down`; add
`--volumes` only if you also want to remove the persisted OpenCode and
OpenChamber state.

The MCP configuration is injected as an additional config through
`OPENCODE_CONFIG`, so it merges with rather than replaces the user's config in
`/home/dev/.config/opencode`. OpenCode loads configuration only at startup;
restart the deployment after changing `config/opencode.json`.

### Context7 MCP

The Compose and Kubernetes deployments also register the hosted Context7 MCP at
`https://mcp.context7.com/mcp`. It provides current, version-specific library
documentation. Ask OpenCode to `use context7` when a prompt needs library or API
documentation.

`CONTEXT7_API_KEY` is optional. Without it, Context7 uses its anonymous rate
limit. For higher limits, create a key in the
[Context7 dashboard](https://context7.com/dashboard) and export it before
starting Compose as shown above. The key is passed at runtime and is not stored
in the image or OpenCode configuration.

For Kubernetes, add `CONTEXT7_API_KEY` to the `openchamber-secrets` Secret in
`kubernetes.yaml`, or manage that key with your normal Secret tooling. Omit the
key to use anonymous access. Restart the Compose deployment or roll out the
Kubernetes Deployment after adding or changing the key, then verify the server:

```bash
docker compose exec opencode opencode mcp list
kubectl -n openchamber exec deployment/openchamber -c openchamber -- \
    opencode mcp list
```

## Processes and ports

| Port        | Process           | Authentication                        | Expose externally?                       |
| ----------- | ----------------- | ------------------------------------- | ---------------------------------------- |
| `3000`      | OpenChamber UI    | `OPENCHAMBER_PASSWORD`                | Yes                                      |
| `2222/tcp`  | sshd              | Public key only, `dev` user           | Yes — SSH encrypts its own traffic       |
| `4096`      | OpenCode API      | **None**                              | No — trusted LAN or authenticating proxy |
| `60000/udp` | mosh-server       | Via SSH, then session keys            | Optional — only if you use Mosh          |

A fourth process, ssh-agent, listens on `/home/dev/.ssh-agent.sock`.
`SSH_AUTH_SOCK` is set for every shell, so run `ssh-add` once and Git over SSH
works for the life of the container. `start.sh` exits if any of the four dies.

OpenChamber reaches OpenCode over loopback, so port `4096` only needs publishing
if you want the API itself.

## SSH, tmux and Mosh

sshd is configured key-only (`PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers dev`);
the public keys live in `/home/dev/.ssh/authorized_keys`, typically delivered
by mounting your `~/.ssh` read-only. Startup fails closed if that file is
missing or empty.

Every interactive login attaches to one shared tmux session (`main`, in
`/workspace`, via `/etc/profile.d/tmux-attach.sh`). Dropping a connection
leaves work running and reconnecting reattaches to it; a second device joins
the *same* session, so run `tmux new -s other` for an independent one. A
system-wide `/etc/tmux.conf` enables mouse mode (touch scrolling in mobile SSH
apps) and a 50000-line history; your own `~/.tmux.conf` still overrides it.

`ClientAliveInterval 30` keeps NAT mappings warm and reaps dead clients, which
matters on mobile networks.

Mosh survives Wi-Fi↔cellular roaming and gives instant local echo on lossy
links. It authenticates through SSH and then moves to UDP — by default the
server picks a port from 60000–61000; pin it so your firewall only needs one
hole:

```bash
mosh -p 60000 --ssh="ssh -p 2222" dev@example.lan
```

Run mosh *inside* tmux if you want scrollback — mosh itself only redraws the
visible screen.

### Git credentials without leaving keys behind

Two ways to push from the container, both already wired up:

- **In-container agent**: run `ssh-add` once inside the container; every shell
  sees `SSH_AUTH_SOCK` and Git over SSH just works.
- **Agent forwarding**: connect with `ssh -A` (or `ForwardAgent yes` in your
  client config) and no key material is ever stored in the container. Only
  forward to hosts you trust — a rooted container could otherwise use your
  agent socket while you are connected.

### Client-side quality of life

```sshconfig
Host opencode
    HostName example.lan
    Port 2222
    User dev
    # Reuse one connection for scp/rsync/subsequent shells — no repeat handshakes
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
    # Forward your local agent instead of keeping keys in the container
    ForwardAgent yes
```

VS Code Remote-SSH and JetBrains Gateway also work against this container.
`~/.vscode-server` lands under `/home/dev`, so keep that path on a volume if
you use them and want updates to survive restarts.

## Environment variables

| Variable                 | Required | Default                | Purpose                            |
| ------------------------ | -------- | ---------------------- | ---------------------------------- |
| `OPENCHAMBER_PASSWORD`   | Yes      | —                      | OpenChamber UI password.           |
| `SSHD_PORT`              | No       | `2222`                 | sshd listen port.                  |
| `OPENCHAMBER_PORT`       | No       | `3000`                 | OpenChamber listen port.           |
| `OPENCODE_PORT`          | No       | `4096`                 | OpenCode listen port.              |
| `OPENCODE_HOSTNAME`      | No       | `0.0.0.0`              | OpenCode bind address.             |
| `OPENCODE_READY_TIMEOUT` | No       | `30`                   | Seconds to wait for OpenCode.      |
| `GIT_USER_NAME`          | No       | —                      | Global Git commit author name.     |
| `GIT_USER_EMAIL`         | No       | —                      | Global Git commit author email.    |
| `GITHUB_TOKEN`           | No       | —                      | Passed through for `gh`.           |
| `CONTEXT7_API_KEY`       | No       | —                      | Higher Context7 MCP rate limits.   |

Startup fails if `OPENCHAMBER_PASSWORD` is unset, or if
`/home/dev/.ssh/authorized_keys` is missing or empty — the container refuses
to start an sshd nobody can log into, or an OpenChamber anyone can reach.
Supply the password from Kubernetes Secrets, not the image. In Compose,
`SSHD_PORT` and `MOSH_PORT` also set the *host-side* published ports, and
`SSH_AUTHORIZED_KEYS_DIR` (default `${HOME}/.ssh`) is the directory mounted
read-only at `/home/dev/.ssh`.

## Kubernetes

Replace the manifest's placeholders — `USER` (hostPath owner), `example.lan`
(Ingress DNS suffix), `CHANGEME` (Secret and Git identity values) — then:

```bash
kubectl apply -f kubernetes.yaml
```

That creates a namespace, Secret, ConfigMaps, 4Gi PVC, Deployment, one NodePort
Service and two Ingresses. The Deployment includes the same headless Chrome
sidecar as the Compose setup. Chrome has its own readiness and liveness probes
on its pod-local DevTools endpoint; port `9222` is not included in a Service or
Ingress. One of the existing Ingresses publishes OpenCode's unauthenticated API
— delete it unless you want port `4096` reachable from the LAN. The image's
Docker `HEALTHCHECK` is ignored by Kubernetes, which is why the manifest defines
its own probes.

The pod runs with `hostNetwork` so sshd binds the node's `:2222` directly —
SSH is plain TCP and cannot go through the HTTP Ingress. Connect with
`ssh -p 2222 dev@<node>` (or `mosh -p 60000 --ssh="ssh -p 2222" dev@<node>`;
the UDP port also binds on the node). Make sure nothing else on the host
already binds `2222`, `3000` or `4096`, and restrict node-port access at the
firewall — SSH is key-only, but there is no rate limiting in front of it.

After applying the manifest, confirm Chrome is reachable only from the companion
OpenCode container:

```bash
kubectl -n openchamber rollout status deployment/openchamber
kubectl -n openchamber exec deployment/openchamber -c openchamber -- \
    curl -fsS http://127.0.0.1:9222/json/version
kubectl -n openchamber exec deployment/openchamber -c openchamber -- \
    opencode mcp list
```

The Ingress hosts route plain HTTP with long timeouts and buffering off
(WebSocket-friendly defaults for OpenChamber and OpenCode); nginx handles any
upgrade handshake itself.

### Persistence

Mount these to survive rescheduling:

| Path                              | Purpose                             |
| --------------------------------- | ----------------------------------- |
| `/workspace`                      | Repositories and working files.     |
| `/home/dev/.config/opencode`      | OpenCode configuration.             |
| `/home/dev/.local/share/opencode` | OpenCode sessions and data.         |
| `/home/dev/.local/state/opencode` | OpenCode runtime state.             |
| `/home/dev/.config/openchamber`   | OpenChamber configuration.          |
| `/home/dev/.ssh`                  | `authorized_keys` + Git keys — read-only. |
| `/home/dev/.ssh-state`            | `known_hosts`.                      |
| `/etc/ssh/host-keys`              | sshd host key — stable fingerprints.|
| `/home/dev/.config/gh`            | GitHub CLI auth (not in the example).|

Use Secrets for keys and tokens, PVCs for the rest.

## Security

- Shell access is root-equivalent: `dev` has passwordless sudo. A stolen
  private key with a line in `authorized_keys` owns the container, so treat
  that file as root-equivalent too — mount it read-only, as the examples do.
- sshd is configured key-only: `PasswordAuthentication no`,
  `KbdInteractiveAuthentication no`, `PermitRootLogin no`, `AllowUsers dev`,
  `MaxAuthTries 3`, `LoginGraceTime 30`. There is still no rate limiting or
  lockout in front of it — on an untrusted network, keep `2222` behind a
  firewall or reach the pod with `kubectl port-forward`.
- The sshd host key lives in `/etc/ssh/host-keys`. Persist it (the examples
  do) so client fingerprints stay stable across restarts; an unpersisted key
  regenerates on every container recreation and triggers host-key-mismatch
  warnings.
- Mosh derives its session key from the SSH exchange and encrypts all traffic
  (AES-128 OCB), but it does not encrypt host keystrokes you type *before*
  the mosh session starts, and a roaming client trusts the network it lands
  on for UDP delivery. Keep the SSH hop on a trusted path.
- Agent forwarding (`ssh -A`) exposes your agent socket to the container for
  as long as you are connected. Only forward to containers you trust.
- OpenCode's port `4096` has no authentication of any kind.
- Chrome's DevTools endpoint grants complete control of the browser. Never add
  port `9222` to Docker port publishing, a Kubernetes Service, or an Ingress.
- Do not use the automated Chrome profile for sensitive personal browsing or
  accounts. Browser content, cookies and credentials are available to the MCP
  client. The supplied configuration disables usage statistics and CrUX lookups
  and redacts sensitive network headers returned by MCP tools.
- Chrome runs with `--no-sandbox` inside a dedicated non-root sidecar with all
  Linux capabilities dropped, no privilege escalation and a read-only root
  filesystem. Keep those controls together; do not reuse the sidecar as a
  general-purpose browser service.
- Never bake tokens or keys into the image; pass them at runtime.
- Requires an AVX2-capable x86-64 CPU (Haswell, 2013 or later).

The remote `--browser-url` connection supports normal navigation, debugging,
network and performance tools. Features that require a direct browser pipe,
including some extension and PWA operations, are not available in this mode.
Chrome requests 512Mi memory and is limited to 2Gi in the example Kubernetes
manifest; tune those values for the pages and traces you run.

## Building

```bash
docker build -t opencode-remote:latest .
```

`start.sh` is the only file copied in; `.dockerignore` excludes the rest.

## Published image

[`.github/workflows/publish.yml`](.github/workflows/publish.yml) pushes to
`ghcr.io/stephen-cox/opencode-container`.

| Tag           | Written by                |
| ------------- | ------------------------- |
| `latest`      | pushes to `main`, weekly  |
| `sha-abc1234` | every build               |
| `YYYYMMDD`    | weekly rebuild — use to roll back a bad week |

The weekly run (Mondays 04:17 UTC) builds with `no-cache` and `pull`, which is
what picks up new Ubuntu patches (including `openssh-server` and `mosh`
security updates) and new `opencode-ai`, `@openchamber/web` and `backlog.md`
releases; a cached rebuild would change nothing. Every build publishes SBOM
and provenance attestations.

Two things to know:

- New GHCR packages are **private**. Make the package public after the first
  push, or nobody else can pull it.
- GitHub **disables scheduled workflows after 60 days** of repository
  inactivity, so a silent weekly build may mean the schedule is off, not
  passing.

Builds are `linux/amd64` only. For arm64, build on a native arm runner and merge
the manifests — QEMU emulation is painfully slow for this image.
