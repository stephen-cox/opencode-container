# Remote coding container

This image runs a remote coding environment with OpenCode, OpenChamber, and an
sshd for shell access. It is designed to run well in Kubernetes. An example
MicroK8s manifest is available at [`kubernetes.yaml`](kubernetes.yaml), but this
repository does not include a Helm chart.

## Runtime model

The container starts four processes:

- OpenCode on `0.0.0.0:4096` by default.
- OpenChamber on `0.0.0.0:3000`.
- sshd on `0.0.0.0:2222` (key-only auth, `dev` user only).
- ssh-agent listening on `/home/dev/.ssh-agent.sock`. `SSH_AUTH_SOCK` is
  exported globally via `/etc/profile.d/ssh-agent.sh`, so every interactive
  shell sees the same agent. Run `ssh-add` once after connecting; the
  passphrase is cached for the lifetime of the container.

OpenChamber connects to OpenCode over loopback. OpenCode itself has no
built-in authentication, so binding `0.0.0.0` exposes its API to whatever
network the pod is on. Run only on a trusted LAN, or front it with an Ingress
that adds auth.

sshd runs via passwordless `sudo` from the `dev` entrypoint so that `USER dev`
is preserved for OpenCode and OpenChamber. It refuses password and root logins;
public keys must be in `/home/dev/.ssh/authorized_keys` (typically delivered by
mounting the host's `~/.ssh` directory there).

## Required environment variables

Set these values from Kubernetes Secrets rather than baking them into the
image:

| Variable               | Required | Purpose                          |
| ---------------------- | -------- | -------------------------------- |
| `OPENCHAMBER_PASSWORD` | Yes      | Password for the OpenChamber UI. |

Optional port overrides:

| Variable            | Default   | Purpose                  |
| ------------------- | --------- | ------------------------ |
| `OPENCHAMBER_PORT`  | `3000`    | OpenChamber listen port. |
| `OPENCODE_PORT`     | `4096`    | OpenCode listen port.    |
| `OPENCODE_HOSTNAME` | `0.0.0.0` | OpenCode bind address.   |
| `SSHD_PORT`         | `2222`    | sshd listen port.        |

## Kubernetes exposure

Recommended Service/Ingress routing:

| Port   | Expose externally? | Notes                                                                                       |
| ------ | ------------------ | ------------------------------------------------------------------------------------------- |
| `3000` | Yes                | Route this to OpenChamber via Ingress (`openchamber.pythagoras.lan`).                       |
| `4096` | Yes                | OpenCode API via Ingress (`opencode.pythagoras.lan`). No built-in auth; trust LAN only.     |
| `2222` | Optional           | SSH access for the `dev` user. Bound directly on the host via hostNetwork.                  |

If your ingress already handles authentication, still set a non-empty
`OPENCHAMBER_PASSWORD`. The startup script requires it so accidental unauthenticated
deployments fail closed.

The included [`kubernetes.yaml`](kubernetes.yaml) is a local MicroK8s example.
It uses `hostPath` volumes under `/home/stephen/...`, runs the pod with
`hostNetwork: true` so sshd binds the host's `:2222` directly, and exposes
OpenChamber via a Service+Ingress on port `3000`. Connect with
`ssh -p 2222 dev@opencode.pythagoras.lan` after pointing that hostname at the
node IP and putting your public key in the host's `~/.ssh/authorized_keys`.

## Persistence

Use persistent volumes for state that should survive pod rescheduling. Common
mounts are:

| Path                              | Recommended storage         | Purpose                                 |
| --------------------------------- | --------------------------- | --------------------------------------- |
| `/workspace`                      | PVC                         | Project repositories and working files. |
| `/home/dev/.config/opencode`      | PVC or Secret-backed config | OpenCode configuration.                 |
| `/home/dev/.local/share/opencode` | PVC                         | OpenCode state and session data.        |
| `/home/dev/.config/gh`            | Secret or PVC               | GitHub CLI authentication.              |
| `/home/dev/.ssh`                  | Secret or PVC               | SSH keys and known hosts.               |

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

The startup script also exits if OpenCode, OpenChamber, or sshd exits. Use a
Kubernetes restart policy appropriate for your workload.

## Security notes

- The `dev` user has passwordless sudo inside the container. Treat shell access
  as administrative access to the container.
- sshd is configured key-only (`PasswordAuthentication no`, `PermitRootLogin no`,
  `AllowUsers dev`). Only public keys present in `/home/dev/.ssh/authorized_keys`
  can log in.
- The sshd host key (ed25519) lives in `/etc/ssh/host-keys/`, which is mounted
  from a persistent volume. The key is generated on first run and reused on
  subsequent rebuilds, so client fingerprints stay stable across image updates.
- With `hostNetwork: true`, the pod's listen ports collide with anything on the
  node using the same port. Make sure nothing else on the host already binds
  `2222`, `3000`, or `4096`.
- OpenCode `4096` is bound on `0.0.0.0` and has no built-in auth. Only run
  this image on a trusted network or behind an authenticating Ingress.
- Do not bake API tokens, SSH keys, or GitHub credentials into the image.
- If mounting `/var/run/docker.sock` for Docker access, remember that it grants
  root-equivalent control over the node. This image does not require that mount.

## Building

Build from the repository root:

```bash
docker build -f docker/Dockerfile -t opencode-remote:latest docker
```

The build context is `docker/` because `start.sh` is copied from that directory.
