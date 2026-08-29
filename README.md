# Remote coding container

A browser-based remote dev environment — OpenCode, OpenChamber and a
[ttyd](https://github.com/tsl0922/ttyd) web terminal in one container. Runs
under Docker or Kubernetes; [`kubernetes.yaml`](kubernetes.yaml) is a worked
MicroK8s example (no Helm chart).

## What's inside

OpenCode, OpenChamber, backlog.md, GitHub CLI, uv, Node 26, Python 3.14, git,
tmux, neovim, nano, ripgrep, fd, jq, yq, direnv.

There is no C toolchain — `build-essential` and `python3-dev` are left out to
keep the image small, and prebuilt wheels and npm prebuilds cover normal use. If
you need to compile something:

```bash
sudo apt-get update && sudo apt-get install -y build-essential python3-dev
```

## Quick start

```bash
docker run -d --name opencode \
    -p 3000:3000 -p 7681:7681 \
    -e OPENCHAMBER_PASSWORD='<ui-password>' \
    -e WEB_TERMINAL_PASSWORD='<shell-password>' \
    -v "${PWD}:/workspace" \
    ghcr.io/stephen-cox/opencode-container:latest
```

- Web terminal: <http://localhost:7681> — log in as `dev`.
- OpenChamber: <http://localhost:3000>.

### Chrome DevTools MCP

The Compose deployment adds Chrome for Testing as a hardened, headless sidecar
while OpenCode runs the `chrome-devtools-mcp` process locally over stdio:

```bash
export OPENCHAMBER_PASSWORD='<ui-password>'
export WEB_TERMINAL_PASSWORD='<shell-password>'
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
restart the deployment after changing `config/chrome-devtools.json`.

## Processes and ports

| Port   | Process           | Authentication                        | Expose externally?                       |
| ------ | ----------------- | ------------------------------------- | ---------------------------------------- |
| `3000` | OpenChamber UI    | `OPENCHAMBER_PASSWORD`                | Yes                                      |
| `7681` | ttyd web terminal | Basic auth, `dev` + password          | Yes, over TLS                            |
| `4096` | OpenCode API      | **None**                              | No — trusted LAN or authenticating proxy |

A fourth process, ssh-agent, listens on `/home/dev/.ssh-agent.sock`.
`SSH_AUTH_SOCK` is set for every shell, so run `ssh-add` once and Git over SSH
works for the life of the container. `start.sh` exits if any of the four dies.

OpenChamber reaches OpenCode over loopback, so port `4096` only needs publishing
if you want the API itself.

## Web terminal

Every client attaches to one shared tmux session (`main`, in `/workspace`).
Closing the tab leaves work running and reopening reattaches to it; a second
device joins the *same* session, so run `tmux new -s other` if you want an
independent one.

## Environment variables

| Variable                 | Required | Default                | Purpose                            |
| ------------------------ | -------- | ---------------------- | ---------------------------------- |
| `OPENCHAMBER_PASSWORD`   | Yes      | —                      | OpenChamber UI password.           |
| `WEB_TERMINAL_PASSWORD`  | No       | `OPENCHAMBER_PASSWORD` | Web terminal password.             |
| `WEB_TERMINAL_USER`      | No       | `dev`                  | Web terminal username.             |
| `WEB_TERMINAL_PORT`      | No       | `7681`                 | ttyd listen port.                  |
| `OPENCHAMBER_PORT`       | No       | `3000`                 | OpenChamber listen port.           |
| `OPENCODE_PORT`          | No       | `4096`                 | OpenCode listen port.              |
| `OPENCODE_HOSTNAME`      | No       | `0.0.0.0`              | OpenCode bind address.             |
| `OPENCODE_READY_TIMEOUT` | No       | `30`                   | Seconds to wait for OpenCode.      |
| `GITHUB_TOKEN`           | No       | —                      | Passed through for `gh`.           |

Startup fails if `OPENCHAMBER_PASSWORD` is unset, so an unauthenticated
deployment cannot happen by accident. Supply both passwords from Kubernetes
Secrets, not the image.

## Kubernetes

Replace the manifest's placeholders — `USER` (hostPath owner), `example.lan`
(Ingress DNS suffix), `CHANGEME` (Secret values) — then:

```bash
kubectl apply -f kubernetes.yaml
```

That creates a namespace, Secret, ConfigMap, 4Gi PVC, Deployment, one NodePort
Service and three Ingresses. The Deployment includes the same headless Chrome
sidecar as the Compose setup. Chrome has its own readiness and liveness probes
on its pod-local DevTools endpoint; port `9222` is not included in a Service or
Ingress. One of the existing Ingresses publishes OpenCode's unauthenticated API
— delete it unless you want port `4096` reachable from the LAN. The image's
Docker `HEALTHCHECK` is ignored by Kubernetes, which is why the manifest defines
its own probes. `hostNetwork` is not used; traffic routes through the Ingress.

After applying the manifest, confirm Chrome is reachable only from the companion
OpenCode container:

```bash
kubectl -n openchamber rollout status deployment/openchamber
kubectl -n openchamber exec deployment/openchamber -c openchamber -- \
    curl -fsS http://127.0.0.1:9222/json/version
kubectl -n openchamber exec deployment/openchamber -c openchamber -- \
    opencode mcp list
```

The terminal is a WebSocket. The manifest's Ingress annotations (HTTP/1.1,
3600s timeouts, buffering off) cover it; nginx handles the upgrade itself.

### Persistence

Mount these to survive rescheduling:

| Path                              | Purpose                             |
| --------------------------------- | ----------------------------------- |
| `/workspace`                      | Repositories and working files.     |
| `/home/dev/.config/opencode`      | OpenCode configuration.             |
| `/home/dev/.local/share/opencode` | OpenCode sessions and data.         |
| `/home/dev/.local/state/opencode` | OpenCode runtime state.             |
| `/home/dev/.config/openchamber`   | OpenChamber configuration.          |
| `/home/dev/.ssh`                  | Git SSH keys — mount read-only.     |
| `/home/dev/.ssh-state`            | `known_hosts`.                      |
| `/home/dev/.config/gh`            | GitHub CLI auth (not in the example).|

Use Secrets for keys and tokens, PVCs for the rest.

## Security

- The web terminal is root-equivalent access: `dev` has passwordless sudo.
- Basic auth is weaker than the key-only sshd this replaced — passwords can be
  guessed or replayed and ttyd has no rate limiting. Use a long random password,
  serve it over TLS, and on any untrusted network leave `7681` unexposed and
  reach it with `kubectl port-forward`.
- Over plain HTTP the password and everything you type, including pasted
  secrets, cross the network in cleartext.
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
what picks up new Ubuntu patches and new `opencode-ai`, `@openchamber/web` and
`backlog.md` releases; a cached rebuild would change nothing. Only `ttyd` is
pinned (`ARG TTYD_VERSION`, checksum-verified). Every build publishes SBOM and
provenance attestations.

Two things to know:

- New GHCR packages are **private**. Make the package public after the first
  push, or nobody else can pull it.
- GitHub **disables scheduled workflows after 60 days** of repository
  inactivity, so a silent weekly build may mean the schedule is off, not
  passing.

Builds are `linux/amd64` only. For arm64, build on a native arm runner and merge
the manifests — QEMU emulation is painfully slow for this image.
