# Remote coding container

This image runs a remote coding environment with OpenCode, OpenChamber, and a
browser-based terminal for shell access. It is designed to run well in
Kubernetes. An example MicroK8s manifest is available at
[`kubernetes.yaml`](kubernetes.yaml), but this repository does not include a
Helm chart.

## Runtime model

The container starts four processes:

- OpenCode on `0.0.0.0:4096` by default.
- OpenChamber on `0.0.0.0:3000`.
- [ttyd](https://github.com/tsl0922/ttyd) on `0.0.0.0:7681` — a web terminal
  served over HTTP/WebSocket, behind HTTP basic auth.
- ssh-agent listening on `/home/dev/.ssh-agent.sock`. `SSH_AUTH_SOCK` is
  exported globally via `/etc/profile.d/ssh-agent.sh`, so every interactive
  shell sees the same agent. Run `ssh-add` once after connecting; the
  passphrase is cached for the lifetime of the container.

OpenChamber connects to OpenCode over loopback. OpenCode itself has no
built-in authentication, so binding `0.0.0.0` exposes its API to whatever
network the pod is on. Run only on a trusted LAN, or front it with an Ingress
that adds auth.

### Web terminal

Open the terminal port in a browser and authenticate with
`WEB_TERMINAL_USER` / `WEB_TERMINAL_PASSWORD`. ttyd runs as the `dev` user and
attaches every client to a shared `tmux` session (`main`, rooted at
`/workspace`) via `bash -lc 'exec tmux new -A -s main -c /workspace'`, so:

- Closing the tab or losing the network leaves the session running; reopening
  reattaches to the same shell with scrollback intact.
- Connecting from a second device joins the *same* session rather than starting
  a new one. Use `tmux new -s other` if you want an independent one.
- The login shell picks up `/etc/profile.d/ssh-agent.sh`, so `git push` over SSH
  works after a single `ssh-add`.

No SSH client, host key, or `authorized_keys` file is involved — the container
ships `openssh-client` for outbound Git over SSH only.

## Required environment variables

Set these values from Kubernetes Secrets rather than baking them into the
image:

| Variable               | Required | Purpose                          |
| ---------------------- | -------- | -------------------------------- |
| `OPENCHAMBER_PASSWORD` | Yes      | Password for the OpenChamber UI. |

Optional overrides:

| Variable                | Default                | Purpose                            |
| ----------------------- | ---------------------- | ---------------------------------- |
| `OPENCHAMBER_PORT`      | `3000`                 | OpenChamber listen port.           |
| `OPENCODE_PORT`         | `4096`                 | OpenCode listen port.              |
| `OPENCODE_HOSTNAME`     | `0.0.0.0`              | OpenCode bind address.             |
| `WEB_TERMINAL_PORT`     | `7681`                 | ttyd listen port.                  |
| `WEB_TERMINAL_USER`     | `dev`                  | Web terminal basic-auth user.      |
| `WEB_TERMINAL_PASSWORD` | `OPENCHAMBER_PASSWORD` | Web terminal basic-auth password.  |

The web terminal never starts without a password. If `WEB_TERMINAL_PASSWORD` is
unset it falls back to `OPENCHAMBER_PASSWORD` (which is already required), so a
single-secret deployment works without extra configuration; set it explicitly to
give the shell its own credential.

## Kubernetes exposure

Recommended Service/Ingress routing:

| Port   | Expose externally? | Notes                                                                                   |
| ------ | ------------------ | --------------------------------------------------------------------------------------- |
| `3000` | Yes                | Route this to OpenChamber via Ingress (`openchamber.pythagoras.lan`).                   |
| `4096` | Yes                | OpenCode API via Ingress (`opencode.pythagoras.lan`). No built-in auth; trust LAN only. |
| `7681` | Optional           | Web terminal via Ingress (`terminal.pythagoras.lan`). Basic auth, WebSocket upgrade.    |

If your ingress already handles authentication, still set a non-empty
`OPENCHAMBER_PASSWORD`. The startup script requires it so accidental unauthenticated
deployments fail closed.

Because all three ports are now plain HTTP, the pod no longer needs
`hostNetwork: true` — that was only there so sshd could bind the node's
`:2222`. Everything routes through the Ingress.

The included [`kubernetes.yaml`](kubernetes.yaml) is a local MicroK8s example.
It uses `hostPath` volumes under `/home/stephen/...` and exposes OpenChamber,
OpenCode, and the web terminal through one NodePort Service with three Ingress
hosts. Point `terminal.pythagoras.lan` at the ingress controller and open it in
a browser to get a shell.

The ttyd session is a WebSocket, so the Ingress needs HTTP/1.1, a long read
timeout, and buffering off. The annotations already on the manifest's Ingresses
cover that; nginx handles the `Upgrade` handshake itself.

## Persistence

Use persistent volumes for state that should survive pod rescheduling. Common
mounts are:

| Path                              | Recommended storage         | Purpose                                 |
| --------------------------------- | --------------------------- | --------------------------------------- |
| `/workspace`                      | PVC                         | Project repositories and working files. |
| `/home/dev/.config/opencode`      | PVC or Secret-backed config | OpenCode configuration.                 |
| `/home/dev/.local/share/opencode` | PVC                         | OpenCode state and session data.        |
| `/home/dev/.config/gh`            | Secret or PVC               | GitHub CLI authentication.              |
| `/home/dev/.ssh`                  | Secret or PVC               | Outbound Git SSH keys.                  |

Prefer Kubernetes Secrets for credentials and private keys. If you use a PVC for
SSH or CLI credentials, restrict access to the namespace and workload.

## Probes and health checks

The Dockerfile includes a Docker healthcheck against OpenChamber:

```text
http://127.0.0.1:3000/
```

Kubernetes does not automatically use Docker healthchecks. Configure pod probes
explicitly. A typical readiness probe is:

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 10
```

A conservative liveness probe is:

```yaml
livenessProbe:
  httpGet:
    path: /
    port: 3000
  initialDelaySeconds: 30
  periodSeconds: 30
```

The startup script also exits if OpenCode, OpenChamber, ttyd, or ssh-agent
exits. Use a Kubernetes restart policy appropriate for your workload.

## Security notes

- The `dev` user has passwordless sudo inside the container. Treat access to
  the web terminal as administrative access to the container.
- The web terminal's only protection is HTTP basic auth, which is weaker than
  the key-only sshd it replaces: a password can be guessed or replayed where a
  private key cannot, and ttyd applies no rate limiting or lockout. Use a long
  random `WEB_TERMINAL_PASSWORD`, and prefer putting the terminal behind an
  authenticating Ingress (or leaving `7681` unexposed and reaching it by
  `kubectl port-forward`) on any network you do not fully trust.
- Serve the terminal over TLS. On plain HTTP the basic-auth credential and the
  entire terminal stream — including anything you type, such as secrets pasted
  into a shell — cross the network in cleartext.
- ttyd is started with `--writable`; without it the terminal would be
  read-only. There is no way to expose a view-only terminal and a writable one
  on the same port.
- OpenCode `4096` is bound on `0.0.0.0` and has no built-in auth. Only run
  this image on a trusted network or behind an authenticating Ingress.
- Do not bake API tokens, SSH keys, or GitHub credentials into the image.
- If mounting `/var/run/docker.sock` for Docker access, remember that it grants
  root-equivalent control over the node. This image does not require that mount.

## Building

Build from the repository root:

```bash
docker build -t opencode-remote:latest .
```

`start.sh` is the only file copied into the image; `.dockerignore` excludes
everything else from the context.
