# claude-code-standalone

Security-hardened Docker container for running [Claude Code](https://docs.anthropic.com/claude-code)
as an autonomous agent over your project. Built on Node.js 22 LTS (Debian Trixie slim, glibc 2.41),
multi-arch (linux/amd64 + linux/arm64), with a pinned, lockfile-controlled CLI toolchain and a
curated set of MCP servers.

## Getting started

The prebuilt multi-arch image is published to GHCR — **you don't clone this repo or build anything**.
Three steps: save your token once, pull the image, run it over any project. No scripts required.

**Prerequisites**

- Docker, and a Claude Code OAuth token (`claude setup-token`).
- The GHCR package must be **public** for an anonymous `docker pull`. One-time, by the repo owner:
  *GitHub → repo → Packages → `claude-code-standalone` → Package settings → Change visibility → Public*.
  If it stays private, run `docker login ghcr.io` (with a PAT that has `read:packages`) first.

**1. Save your token once (used from any project)**

```bash
mkdir -p ~/.config/claude-standalone
curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/.env.example \
  -o ~/.config/claude-standalone/claude.env
# Edit the file: set CLAUDE_CODE_OAUTH_TOKEN (required). Context7 / Perplexity keys are optional.
```

**2. Pull the image**

```bash
docker pull ghcr.io/highload-zone/claude-code-standalone:latest
```

**3. Run the agent over your project**

From the project directory you want the agent to work on (it is mounted **read-write**):

```bash
docker run -it --rm \
  --cap-drop=ALL --security-opt=no-new-privileges:true --pids-limit=100 --network=bridge \
  --user "$(id -u):$(id -g)" \
  --tmpfs /home/agent:exec,mode=1777,size=512m -e HOME=/home/agent \
  --tmpfs /tmp:noexec,nosuid,size=100m \
  -v "$PWD:/workspace:rw" -w /workspace \
  --env-file ~/.config/claude-standalone/claude.env \
  ghcr.io/highload-zone/claude-code-standalone:latest
```

> **Why the command is long — and don't shorten it.** The image is self-contained (entrypoint, tools,
> config, MCP servers are all baked in), but the container's *protection* — `--cap-drop=ALL`, the
> non-root `--user`, the `noexec` tmpfs scratch, network isolation — are **`docker run` flags, not
> something an image can carry**: Docker's security model puts these in the operator's hands by
> design. `$(id -u):$(id -g)` (so the agent owns your files) and `$PWD` (which project to mount) are
> likewise resolved on the host at run time. Dropping the hardening flags to make the command shorter
> removes exactly the boundary this image exists to provide. To avoid retyping, wrap it in a shell
> function (below) — that's a wrapper, named honestly, not a shorter command.

### One command from any directory (shell function)

Add to `~/.bashrc` / `~/.zshrc` (a global shell setting, not a script committed to a repo):

```bash
claude-box() {
  docker run -it --rm \
    --cap-drop=ALL --security-opt=no-new-privileges:true --pids-limit=100 --network=bridge \
    --user "$(id -u):$(id -g)" \
    --tmpfs /home/agent:exec,mode=1777,size=512m -e HOME=/home/agent \
    --tmpfs /tmp:noexec,nosuid,size=100m \
    -v "$PWD:/workspace:rw" -w /workspace \
    --env-file ~/.config/claude-standalone/claude.env \
    ghcr.io/highload-zone/claude-code-standalone:latest "$@"
}
```

Then just `claude-box` from any project. (The repo also ships `run_claude.sh`, which is the same
command plus `git`-identity/deploy-key handling — use it if you cloned the repo.)

### Commits as you, and `git push`

The bare command lets the agent edit and commit locally with the container's default git identity.
To attribute commits to **you** and/or enable `git push`, add to the `docker run` (or the function):

```bash
  -e GIT_AUTHOR_NAME="$(git config user.name)"   -e GIT_COMMITTER_NAME="$(git config user.name)" \
  -e GIT_AUTHOR_EMAIL="$(git config user.email)" -e GIT_COMMITTER_EMAIL="$(git config user.email)" \
  # for push, mount a SCOPED, read-only deploy key (see SECURITY.md):
  -v /path/to/repo_deploy_key:/home/agent/deploy_key:ro \
  -e GIT_SSH_COMMAND="ssh -i /home/agent/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
```

### Token in the system keyring (optional)

`--env-file` keeps the token in a plaintext file. To hold it in the OS keyring and inject it at run
time instead (this is, honestly, a thin wrapper around `docker run` — name it as such), drop
`--env-file` and add `-e CLAUDE_CODE_OAUTH_TOKEN=...`:

```bash
# Linux (libsecret): store once, then look it up in the run command
secret-tool store --label='Claude Code' service claude-code key oauth
  -e CLAUDE_CODE_OAUTH_TOKEN="$(secret-tool lookup service claude-code key oauth)"

# macOS (Keychain): store once, then look it up
security add-generic-password -s claude-code -a oauth -w
  -e CLAUDE_CODE_OAUTH_TOKEN="$(security find-generic-password -s claude-code -a oauth -w)"
```

See [Requirements](#requirements), [Setup](#setup), and [Run](#run) below for building locally and
the script-based flow.

## Why

Running an autonomous coding agent with broad permissions directly on your host is risky. This image
confines Claude Code to a hardened container so that the **OS-level container boundary** — not
Claude's in-app permission prompts — is the security perimeter. The agent works read-write on your
project (edit / commit / push) inside that boundary.

## Security model

A single mode. The wrapper scripts (`run_claude.sh`, `debug-shell.sh`) apply hardening at
`docker run` time:

- **`--user $(id -u):$(id -g)`** — runs as your host user so it owns the read-write project mount
  (one image works for any uid). All Linux capabilities dropped (`--cap-drop=ALL`).
- No privilege escalation (`--security-opt=no-new-privileges:true`)
- `--pids-limit=100` (anti fork-bomb)
- Bridge network only (no access to the host network)
- Writable HOME on tmpfs; the baked agent state (config, RTK hook, caveman plugin, opsx commands)
  is copied into it by the entrypoint
- `/tmp` is tmpfs `noexec,nosuid`
- Footgun guards: the scripts refuse `--privileged`, `docker.sock`, `--pid=host`, `--network=host`,
  `--cap-add`, or running as host root

The entrypoint runs `claude --dangerously-skip-permissions --remote-control` — the container
boundary is the perimeter, and Remote Control lets you drive the in-container agent remotely.

> ⚠️ **On a host where the Docker daemon runs as root, `docker run` is equivalent to host root.**
> The wrapper scripts and their guards protect against *accidental* misconfiguration, **not** a
> hostile operator. Full threat model in [SECURITY.md](./SECURITY.md).

### Honest scope

- **The agent has full read-write access to your project** (edit, commit, push) and runs autonomously
  with skipped permissions. Use on **trusted projects**. A prompt injection in the project code can
  drive the agent. Residual risk is Medium with a scoped deploy key for push (below).
- **Network:** bridge mode blocks the *host* network but allows **outbound internet**. `context7` and
  `perplexity` MCP servers send data (incl. code context) to third parties — an exfiltration channel.
  No egress allowlist (cap-drop=ALL prevents in-container iptables); restrict at the Docker-network/
  daemon level or remove those MCP servers.
- **Remote Control** opens an outbound control channel (entrypoint default).
- **Resource limits:** only `--pids-limit` is enforced; the `RLIMIT_*`/`YAMA` env vars in the image
  are not effective by themselves.
- **Third-party tools:** RTK's `PreToolUse` hook rewrites every Bash command; CodeGraph ships a
  vendored prebuilt binary; caveman is a Claude Code plugin. All pinned, but third-party trust.

## What's inside

Base: `node:22-trixie-slim` (Node 22 LTS, Debian 13 / glibc 2.41). Multi-arch (amd64 + arm64).

Toolchain pinned in `tools/package.json`, locked in `tools/package-lock.json` (`npm ci`, sha512
integrity, exact versions):

- `@anthropic-ai/claude-code` (2.1.177), `@fission-ai/openspec` (1.4.1)
- `@agentclientprotocol/claude-agent-acp` (0.44.0) — ACP adapter for IDE use (Zed); reuses
  the pinned `claude` binary via `CLAUDE_CODE_EXECUTABLE`
- `@colbymchenry/codegraph` (1.0.0, MCP) wrapped by `caveman-shrink` (0.1.0)
- MCP servers: `sequential-thinking`, `context7` (HTTP), `perplexity`
- caveman skill (plugin, tag `v1.9.0`)
- Dev tools: `pnpm` 11.6.0, `typescript` 6.0.3, `ts-node` 10.9.2, `prettier` 3.8.4, `eslint` 10.5.0

GitHub-release binaries (per-arch, sha256-pinned): `rtk` (v0.42.4), `git-delta` (0.19.2).
CLI utilities: `jq`, `ripgrep`, `fd`, `tree`, `fzf`, `mc`, `gnupg`.

See [CLAUDE.md](./CLAUDE.md) for the full architecture and per-component details.

## Requirements

- Docker
- A Claude Code OAuth token (`claude setup-token`)
- (optional) Context7 / Perplexity API keys for those MCP servers
- (optional) a scoped git deploy key if you want the agent to `git push`

## Setup

```bash
cp .env.example .env
# Fill in CLAUDE_CODE_OAUTH_TOKEN (required) and any optional keys.
# .env is gitignored and must never be committed.
```

## Container image (GHCR)

CI publishes a multi-arch image (amd64 + arm64) to GitHub Container Registry:

```bash
docker pull ghcr.io/highload-zone/claude-code-standalone:latest
```

- **Versioning is pinned by releases.** A git tag `vX.Y.Z` (a Release) publishes `:X.Y.Z`, `:X.Y`,
  `:X`. `main` publishes `:latest`; every build also gets `:sha-<short>`.
- Built with the built-in `GITHUB_TOKEN` (`packages: write`) — no extra secrets. Pull requests only
  build for verification (no push).
- The GHCR package may be created **private** on first publish — make it public in the repo's
  *Packages* settings for anonymous `docker pull`.

## Build (locally)

```bash
./build.sh           # build claude-code-standalone:latest (npm versions from the lockfile)
./build-nocache.sh   # clean build
```

To change a pinned tool version, edit `tools/package.json`, then regenerate the lockfile inside
Node 22:

```bash
docker run --rm -v "$PWD/tools:/w" -w /w node:22-trixie-slim npm install --package-lock-only
```

## Run

From your project directory:

```bash
./run_claude.sh                 # autonomous Claude Code agent over the current dir (read-write)
./run_claude.sh --model opus    # pass-through Claude Code args
./run_acp.sh                    # expose the container as an ACP agent for an IDE (Zed) — see below
./debug-shell.sh                # bash shell inside the container
./run-diagnostics.sh            # MCP server diagnostics
```

The current directory is mounted **read-write at `/workspace`** and the container runs as your host
user, so the agent can edit, commit, and push. To enable `git push`, point `DEPLOY_KEY` at a
**scoped** repo deploy key (mounted read-only, used with `IdentitiesOnly` — the agent can push only
to that repo and cannot ssh elsewhere):

```bash
export DEPLOY_KEY=/path/to/repo_deploy_key
./run_claude.sh
```

Without `DEPLOY_KEY`, edit + local commit work; push does not. Git commit identity is taken from your
host `git config` (passed as env), so commits are attributed to you.

## Use from an IDE (Zed / ACP)

`run_acp.sh` exposes the container as an [Agent Client Protocol](https://agentclientprotocol.com)
agent (`@agentclientprotocol/claude-agent-acp`), which ACP-compatible editors like
[Zed](https://zed.dev/docs/ai/external-agents) launch and drive over **stdio**. The editor speaks
JSON-RPC to the in-container agent; tool calls (edits, commands) surface as **permission requests in
the editor UI** — a human approves them, so this path is *less* permissive than the autonomous
`run_claude.sh` entrypoint.

Two things make it work and differ from `run_claude.sh`:

- **stdio, not a TTY** (`docker run -i`). stdout carries only JSON-RPC; the wrapper prints all
  diagnostics to stderr.
- **Path coherence.** Zed sends host-absolute paths (cwd, `@`-mentions, diffs), so the project is
  mounted at the **identical absolute path** (`-v "$PWD:$PWD" -w "$PWD"`), not at `/workspace`.

Add this to Zed's `settings.json` (`~/.config/zed/settings.json`), using the **absolute** path to
`run_acp.sh` and running Zed from your project directory (the wrapper mounts `$PWD`):

```json
{
  "agent_servers": {
    "Claude (container)": {
      "command": "/absolute/path/to/claude-standalone/run_acp.sh",
      "args": [],
      "env": {}
    }
  }
}
```

Then pick "Claude (container)" in Zed's agent panel. Auth uses the same `CLAUDE_CODE_OAUTH_TOKEN`
from your `.env`/host env as the other modes (the ACP adapter delegates to the pinned `claude`
binary via `CLAUDE_CODE_EXECUTABLE`). `git push` works the same way via `DEPLOY_KEY`.

## Dev Container

`.devcontainer/devcontainer.json` opens your project **inside** the hardened image as an interactive
development environment (VS Code Dev Containers, JetBrains Gateway, GitHub Codespaces, or the
`devcontainer` CLI). Unlike the agent modes, you work in the container shell and run `claude`
yourself; the image's auto-launch ENTRYPOINT is suppressed (`overrideCommand: true`).

- Pulls `ghcr.io/highload-zone/claude-code-standalone:latest` (pin a release tag for reproducibility).
- Keeps the hardened profile (`cap-drop=ALL` + minimal caps for the uid-remap, `no-new-privileges`)
  with a raised `--pids-limit=512` for interactive tooling.
- Runs as the non-root `claude` user with `updateRemoteUserUID` so workspace files are owned by you.
- Reads `CLAUDE_CODE_OAUTH_TOKEN` / `CONTEXT7_API_KEY` / `PERPLEXITY_API_KEY` from your host env.

## Security disclosures

See [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)
