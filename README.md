# Remote coding container

A browser-based remote dev environment — OpenCode, OpenChamber and a
[ttyd](https://github.com/tsl0922/ttyd) web terminal in one container. Runs
under Docker or Kubernetes; [`kubernetes.yaml`](kubernetes.yaml) is a worked
MicroK8s example (no Helm chart). The Compose and Kubernetes deployments add
two companion containers: headless Chrome for the DevTools MCP, and
[code-server](https://github.com/coder/code-server) for browser VS Code.

## What's inside

OpenCode, OpenChamber, backlog.md, GitHub CLI, uv, Node 26, Python 3.14, git,
tmux, neovim, nano, ripgrep, fd, jq, yq, direnv. code-server and Chrome are
not baked into this image — they run as separate companion containers in the
Compose and Kubernetes deployments.

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

| Port   | Process           | Authentication                        | Expose externally?                       |
| ------ | ----------------- | ------------------------------------- | ---------------------------------------- |
| `3000` | OpenChamber UI    | `OPENCHAMBER_PASSWORD`                | Yes                                      |
| `7681` | ttyd web terminal | Basic auth, `dev` + password          | Yes, over TLS                            |
| `8080` | code-server       | Password login (`CODE_SERVER_PASSWORD`) | Yes, over TLS                          |
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

## Code editor (code-server)

The Compose and Kubernetes deployments also run
[code-server](https://github.com/coder/code-server) — VS Code in the browser —
as a companion container using the official `codercom/code-server` image. It
is deliberately in its **own container and network namespace** (unlike the
Chrome sidecar, which shares the main container's network): VS Code's Ports
panel can then only forward ports inside the code-server container, so the
main container's loopback-only OpenCode API (`:4096`) and Chrome DevTools
(`:9222`) stay invisible to it. Do not "simplify" this into
`network_mode: service:opencode` or a pod sidecar.

It is not supervised by `start.sh`: it restarts independently, and a
code-server crash never restarts OpenCode or the web terminal.

- It opens `/workspace`, mounted from the same place as the main container.
  The image's `coder` user is UID 1000, same as `dev`, so files keep
  consistent ownership. The Kubernetes example shares the workspace through
  its single-node hostPath; multi-node clusters need RWX storage, where VS
  Code's file watcher also loses inotify events and falls back to polling.
- Your `~/.ssh` is mounted read-only, so git over SSH works from VS Code
  terminals. Extensions come from [Open VSX](https://open-vsx.org), not the
  Microsoft marketplace, so proprietary extensions are unavailable.
- VS Code terminals run inside the code-server container — Debian with git,
  git-lfs, curl and not much else. They are not the main container's
  environment (no `gh`, `uv`, Node 26, and no access to the shared tmux
  session); use the web terminal for those.
- Log in at `http://localhost:8080` (Compose) or `code-server.example.lan`
  (Kubernetes) with `CODE_SERVER_PASSWORD`.
- The image floats: `latest` with `pull_policy: always` in Compose and
  `imagePullPolicy: Always` in Kubernetes, so the next `docker compose up` or
  pod restart picks up new releases.

## Environment variables

| Variable                 | Required | Default                | Purpose                            |
| ------------------------ | -------- | ---------------------- | ---------------------------------- |
| `OPENCHAMBER_PASSWORD`   | Yes      | —                      | OpenChamber UI password.           |
| `WEB_TERMINAL_PASSWORD`  | No       | `OPENCHAMBER_PASSWORD` | Web terminal password.             |
| `WEB_TERMINAL_USER`      | No       | `dev`                  | Web terminal username.             |
| `WEB_TERMINAL_PORT`      | No       | `7681`                 | ttyd listen port.                  |
| `CODE_SERVER_PORT`       | No       | `8080`                 | Host port for code-server (Compose). |
| `CODE_SERVER_PASSWORD`   | No       | `OPENCHAMBER_PASSWORD` | code-server login password (Compose; the Kubernetes Secret key has the same name). |
| `OPENCHAMBER_PORT`       | No       | `3000`                 | OpenChamber listen port.           |
| `OPENCODE_PORT`          | No       | `4096`                 | OpenCode listen port.              |
| `OPENCODE_HOSTNAME`      | No       | `0.0.0.0`              | OpenCode bind address.             |
| `OPENCODE_READY_TIMEOUT` | No       | `30`                   | Seconds to wait for OpenCode.      |
| `GITHUB_TOKEN`           | No       | —                      | Passed through for `gh`.           |
| `CONTEXT7_API_KEY`       | No       | —                      | Higher Context7 MCP rate limits.   |

Startup fails if `OPENCHAMBER_PASSWORD` is unset, so an unauthenticated
deployment cannot happen by accident. Supply both passwords from Kubernetes
Secrets, not the image.

## Kubernetes

Replace the manifest's placeholders — `USER` (hostPath owner), `example.lan`
(Ingress DNS suffix), `CHANGEME` (Secret values) — then:

```bash
kubectl apply -f kubernetes.yaml
```

That creates a namespace, Secret, ConfigMap, two PVCs, two Deployments, one
NodePort Service, one ClusterIP Service and four Ingresses. The openchamber
Deployment includes the same headless Chrome sidecar as the Compose setup; the
code-server Deployment runs browser VS Code in its own pod and network (see
[Code editor](#code-editor-code-server)). Chrome has its own readiness and liveness probes
on its pod-local DevTools endpoint; port `9222` is not included in a Service or
Ingress. One of the existing Ingresses publishes OpenCode's unauthenticated API
— delete it unless you want port `4096` reachable from the LAN. The image's
Docker `HEALTHCHECK` is ignored by Kubernetes, which is why the manifest defines
its own probes. `hostNetwork` is not used; traffic routes through the Ingress.

After applying the manifest, confirm Chrome is reachable only from the companion
OpenCode container:

```bash
kubectl -n openchamber rollout status deployment/openchamber
kubectl -n openchamber rollout status deployment/code-server
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
| `/home/coder/.local/share/code-server` | code-server data and extensions — own container (Compose volume `code-server-data`, PVC `code-server-pvc`). |

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
- code-server runs in its own container and network namespace on purpose: VS
  Code's Ports panel can only forward ports inside that container, so the main
  container's unauthenticated OpenCode API (`:4096`) and Chrome's DevTools
  port (`:9222`) stay unreachable from it. Keep it that way.
- A code-server login is a shell in the code-server container (which has
  passwordless sudo there) plus read-only access to your `~/.ssh`. It is not
  root in the main container, but the SSH keys alone justify a long password
  and TLS.
- The Kubernetes code-server pod is hardened less than the Chrome sidecar —
  the image's `fixuid` setuid helper conflicts with no-new-privileges
  hardening. It is still non-root, seccomp-confined, and code-server
  rate-limits password attempts.
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
