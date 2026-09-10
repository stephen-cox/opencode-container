# Container environment

You run in the OpenCode/OpenChamber development container, not on the user's
workstation or directly on the container host. OpenChamber is the UI; OpenCode
executes agent tools in this container.

- Base OS: Ubuntu 26.04; shell: Bash; user: `dev`; home: `/home/dev`.
- `/workspace` is the default working directory. Work in the selected repository.
  Persistence depends on deployment mounts; do not assume the entire home or
  container filesystem is persistent. Treat `/tmp` as disposable.
- Passwordless `sudo` is available inside the container. This is a capability,
  not permission to change the system or host without user approval. Packages
  installed interactively do not survive container replacement.

## Curated software inventory

This lists software deliberately installed by the image, not a live discovery
result. Exact versions can change on image rebuilds; check a tool's version when
it matters to the task.

| Purpose | Available software |
| --- | --- |
| Agent and browser tooling | OpenCode (`opencode`), OpenChamber (`openchamber`), backlog.md (`backlog`), `chrome-devtools-mcp` |
| JavaScript | Node.js 26, npm |
| Python | Python 3 (`python` and `python3`), pip, venv, requests, uv |
| PHP | PHP CLI, Composer 2; extensions: date, dom, filter, gd, hash, json, pcre, PDO, session, SimpleXML, SPL, tokenizer, xml, mbstring, curl, zip |
| Source control and transfer | Git, GitHub CLI (`gh`), OpenSSH client/server, curl, rsync |
| Search and structured data | ripgrep (`rg`), fd (`fd`, alias via symlink to `fdfind`), jq, Mike Farah's yq |
| Terminal and editing | tmux, Mosh, Neovim (`nvim`), nano, less, direnv |
| Supporting utilities | sudo, unzip, GnuPG, CA certificates, locales, timezone data, tini |

## Boundaries and omissions

- The image does not install `build-essential`, `python3-dev`, Docker CLI/daemon,
  or `kubectl`. Do not assume native compilation or cluster administration is
  available. Ask before installing missing system dependencies.
- Credentials and authenticated access are supplied separately. An installed
  CLI does not imply it is authenticated. Never dump environment variables,
  private keys, or tokens into prompts or logs.
- Chrome and code-server are not installed in this image. The example deployments
  provide them as companion containers. Use configured Chrome DevTools MCP tools
  for browser work; the browser has a separate filesystem, so local file paths
  and upload files are not automatically available there.
- code-server terminals execute in a different container with different software,
  even when they share the workspace. Do not confuse them with this environment.
