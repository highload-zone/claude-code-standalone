# agent-standalone

Security-hardened Docker images for running a coding agent — **[Claude
Code](https://docs.anthropic.com/claude-code)**, **Codex** or **OpenCode** — as an autonomous agent
over your project. One repository, three images, one shared toolchain (Node.js 24 LTS / Debian
Trixie slim, glibc 2.41, multi-arch linux/amd64 + linux/arm64), adapted per agent: MCP servers, RTK
command rewriting and OpenSpec are wired in each agent's own format.

| Tag | Agent CLI |
|-----|-----------|
| `:claude` (and `:latest`) | Claude Code 2.1.248 |
| `:codex` | Codex CLI 0.155.0 |
| `:opencode` | OpenCode 1.18.31 |

## Getting started

The prebuilt multi-arch images are published to GHCR — **you don't clone this repo or build
anything**. Requires Docker; each agent needs its own credentials (below).

### Quick install (Linux / macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/install.sh | bash
```

The installer pulls the three GHCR images, asks for your Claude OAuth token once (stored in
`~/.config/agent-standalone/agent.env`, `chmod 600`), and installs launchers into `~/.local/bin`.
Then, from any project directory (mounted **read-write**):

```bash
claude-box                  # hardened Claude Code over the current directory
codex-box                   # hardened Codex
opencode-box                # hardened OpenCode
agent-box codex mcp list    # generic launcher; args forward to the agent
claude-box --model opus     # extra args pass through to claude
```

Each launcher forwards its arguments verbatim, so introspection runs exactly the agent's command:
`claude-box mcp list` → `claude mcp list`, `codex-box mcp list` → `codex mcp list`, and so on. The
same holds for a raw `docker run`: `docker run … <image> mcp list`.

If `~/.local/bin` isn't on your `PATH`, the installer prints the line to add (e.g.
`echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc`).

```bash
# inspect before running (it's curl | bash, after all):
curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/install.sh -o install.sh
less install.sh && bash install.sh

CLAUDE_CODE_OAUTH_TOKEN=... bash install.sh   # non-interactive (skips the token prompt)
AGENT_IMAGES="claude codex" bash install.sh   # pull/install only a subset (default: all three)
CLAUDE_RESOURCES_MODE=mount bash install.sh   # non-interactive resource choice: mount | copy | skip
bash install.sh --uninstall                   # remove the launchers (config is left in place)
```

**Persistent logins.** Each launcher mounts a host directory for that agent's credentials
(`~/.config/agent-standalone/login/<agent>`), so `claude auth login`, `codex login` and
`opencode auth login` survive a container restart. On first start the baked config is seeded with
no-clobber, so a host credential/config file is never overwritten. Disable with `AGENT_LOGIN_MOUNT=0`.

**Your local Claude agents, commands, and skills.** If the installer finds `~/.claude/agents`,
`~/.claude/commands`, or `~/.claude/skills` on the host, it offers to pass them through to the
claude image: **mount** the live path (default — edits on the host show up next run), **copy** a
snapshot into `~/.config/agent-standalone/resources/`, or **skip**. `claude-box` mounts the chosen
paths read-only and the container merges them **over** its baked state, so your resources win on a
name clash while the image's own commands/skills (e.g. `opsx`) still work.

The launchers forward your host git identity (so commits are attributed to you) and, if you set
`DEPLOY_KEY=/path/to/scoped_key`, mount it read-only to enable `git push` (see [SECURITY.md](./SECURITY.md)).

### Without the installer — one `docker run`

Save your credentials once, then run the image directly. The env file is read by `--env-file`, so it
must be raw `KEY=value` (no quotes, no `export`):

```bash
mkdir -p ~/.config/agent-standalone
cat > ~/.config/agent-standalone/agent.env <<'EOF'
CLAUDE_CODE_OAUTH_TOKEN=YOUR_TOKEN     # claude
CODEX_API_KEY=sk-...                   # codex (or use `codex login`)
OPENAI_API_KEY=sk-...                  # opencode (or use `opencode auth login`)
CONTEXT7_API_KEY=...
PERPLEXITY_API_KEY=...
EOF
chmod 600 ~/.config/agent-standalone/agent.env

docker pull ghcr.io/highload-zone/claude-code-standalone:claude   # or :codex / :opencode
```

From the project directory you want the agent to work on (swap the image tag and, if you like, add a
`-v <host-login-dir>:/home/agent/<ctr-path>` mount for login persistence):

```bash
docker run -it --rm \
  --cap-drop=ALL --security-opt=no-new-privileges:true --pids-limit=100 --network=bridge \
  --user "$(id -u):$(id -g)" \
  --tmpfs /home/agent:exec,mode=1777,size=512m -e HOME=/home/agent \
  --tmpfs /tmp:noexec,nosuid,size=100m \
  -v "$PWD:/workspace/project:rw" -w /workspace/project \
  -v ~/.config/agent-standalone/login/claude:/home/agent/.claude \
  --env-file ~/.config/agent-standalone/agent.env \
  ghcr.io/highload-zone/claude-code-standalone:claude

# introspect without launching the TUI:
docker run --rm … ghcr.io/highload-zone/claude-code-standalone:codex mcp list
```

> **Why the command is long — and don't shorten it.** The image is self-contained (entrypoint, tools,
> config, MCP servers are all baked in), but the container's *protection* — `--cap-drop=ALL`, the
> non-root `--user`, the `noexec` tmpfs scratch, network isolation — are **`docker run` flags, not
> something an image can carry**: Docker's security model puts these in the operator's hands by
> design. `$(id -u):$(id -g)` (so the agent owns your files) and `$PWD` (which project to mount) are
> likewise resolved on the host at run time. Dropping the hardening flags to make the command shorter
> removes exactly the boundary this image exists to provide — that's why the installer above wraps
> the full command in `claude-box` rather than offering a trimmed-down one.

To attribute commits to **you** and/or enable `git push`, add to the `docker run`:

```bash
  -e GIT_AUTHOR_NAME="$(git config user.name)"   -e GIT_COMMITTER_NAME="$(git config user.name)" \
  -e GIT_AUTHOR_EMAIL="$(git config user.email)" -e GIT_COMMITTER_EMAIL="$(git config user.email)" \
  # for push, mount a SCOPED, read-only deploy key (see SECURITY.md):
  -v /path/to/repo_deploy_key:/home/agent/deploy_key:ro \
  -e GIT_SSH_COMMAND="ssh -i /home/agent/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
```

> **Token in the system keyring (optional).** To avoid a plaintext `--env-file`, store the token in
> the OS keyring and inject it at run time instead — drop `--env-file` and add
> `-e CLAUDE_CODE_OAUTH_TOKEN="$(secret-tool lookup service claude-code key oauth)"` on Linux
> (libsecret), or `$(security find-generic-password -s claude-code -a oauth -w)` on macOS (Keychain).

See [Requirements](#requirements), [Setup](#setup), and [Run](#run) below for building locally and
the repo's script-based flow.

## Why

Running an autonomous coding agent with broad permissions directly on your host is risky. This image
confines Claude Code to a hardened container so that the **OS-level container boundary** — not
Claude's in-app permission prompts — is the security perimeter. The agent works read-write on your
project (edit / commit / push) inside that boundary.

## Security model

A single mode. The wrapper scripts (`run_agent.sh`, `run_claude.sh`, `debug-shell.sh`) and the
installer's `agent-box` launchers apply hardening at `docker run` time:

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

The entrypoint runs `claude` in **auto mode** (`permissions.defaultMode: "auto"` in
`~/.claude/settings.json`) — autonomous, but with a background classifier that blocks dangerous
actions (prompt-injection-driven commands, `curl | bash`, force-push, pushing to `main`, prod
deploys). The OS-level container boundary is still the perimeter. Auto mode engages on the Anthropic
API with a supported model; if it's unavailable for your account it **silently falls back to
`default`** (prompts on each action) — confirm the status bar shows `auto` on first run.

Env vars that change how the entrypoint launches Claude Code:
- `CLAUDE_BYPASS_PERMISSIONS=1` — opt-in, off by default. Re-adds `--dangerously-skip-permissions`
  (full bypass, no in-app safety checks) for isolated/throwaway containers.
- `CLAUDE_REMOTE_CONTROL` — **on by default**; `--remote-control` is passed on every session. Set to
  `0` to opt out. It only takes effect with a full-scope `claude auth login` token: the inference-only
  `CLAUDE_CODE_OAUTH_TOKEN` is rejected for Remote Control, and the entrypoint prints that at startup
  rather than failing silently.
- `CLAUDE_REMOTE_CONTROL_PREFIX` — prefix for auto-generated Remote Control session names. Defaults to
  your project directory name (the CLI default would be the container's throwaway hostname).

Fan-out budgets are tightened for a `--pids-limit=100` container (all overridable from `.env`):
`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=12` (upstream 20), `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION=100`
and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION=100` (upstream 200 each), `CLAUDE_CODE_RETRY_WATCHDOG=1`
for unattended retries. `settings.json` additionally sets `autoMode.classifyAllShell: true` (every
shell command goes through the auto-mode classifier), `agentPushNotifEnabled: true` (proactive phone
push once Remote Control connects) and `workflowSizeGuideline: "small"`.

A stronger **advisor** model (`advisorModel: "opus"`) is configured by default: Claude consults Opus
at decision points (requires the Anthropic API). It's a no-op if you run a main model that outranks
Opus (e.g. `--model fable`, where an Opus advisor is rejected).

> ⚠️ **On a host where the Docker daemon runs as root, `docker run` is equivalent to host root.**
> The wrapper scripts and their guards protect against *accidental* misconfiguration, **not** a
> hostile operator. Full threat model in [SECURITY.md](./SECURITY.md).

### Honest scope

- **The agent has full read-write access to your project** (edit, commit, push) and runs autonomously
  with skipped permissions. Use on **trusted projects**. A prompt injection in the project code can
  drive the agent. Residual risk is Medium with a scoped deploy key for push (below).
- **Network:** bridge mode blocks the *host* network but allows **outbound internet**. The `context7`,
  `cloudflare-docs` and `perplexity` MCP servers send data (incl. code context) to third parties — an
  exfiltration channel. No egress allowlist (cap-drop=ALL prevents in-container iptables); restrict at
  the Docker-network/daemon level or remove those MCP servers.
- **Remote Control** opens an outbound control channel (entrypoint default).
- **Resource limits:** only `--pids-limit` is enforced; the `RLIMIT_*`/`YAMA` env vars in the image
  are not effective by themselves.
- **Third-party tools:** RTK's `PreToolUse` hook rewrites every Bash command; CodeGraph and
  codebase-memory-mcp ship vendored prebuilt binaries; caveman is a Claude Code plugin. All pinned,
  but third-party trust.

## What's inside

Base: `node:24-trixie-slim` (Node 24 LTS, Debian 13 / glibc 2.41). Multi-arch (amd64 + arm64).
Built from one `Dockerfile` with three targets (`--target claude|codex|opencode`).

Shared toolchain pinned in `tools/package.json`, locked in `tools/package-lock.json` (`npm ci`,
sha512 integrity, exact versions):

- `@fission-ai/openspec` (1.10.0)
- `@colbymchenry/codegraph` (1.5.0, MCP) wrapped by `caveman-shrink` (0.1.0)
- MCP servers: `sequential-thinking`, `context7` (HTTP), `cloudflare-docs` (HTTP, no API key),
  `perplexity`, `codebase-memory-mcp` (GitHub-release binary, see below)
- Dev tools: `pnpm` 11.24.0, `typescript` 6.0.3, `ts-node` 10.9.2, `prettier` 3.9.6, `eslint` 10.9.1

Per-agent CLI, installed only into its own image (`tools/agents/<agent>/`, own lockfile):
`@anthropic-ai/claude-code` 2.1.248, `@openai/codex` 0.155.0, `opencode-ai` 1.18.31. Each image also
carries that agent's baked config and integration:

- **MCP:** one source of truth (`mcp-servers.json`) rendered per agent by `render-mcp-configs.sh` —
  Claude's native format, Codex `[mcp_servers.*]` TOML, OpenCode's `mcp` JSON. Secrets are never
  baked: `${VAR}` becomes Claude's literal reference, Codex `env_vars`/`env_http_headers`, OpenCode
  `{env:VAR}`.
- **RTK** (v0.45.0): Claude Code PreToolUse hook, Codex `$CODEX_HOME/AGENTS.md` + `RTK.md`, OpenCode
  `~/.config/opencode/plugins/rtk.ts`.
- **OpenSpec:** `~/.claude/{commands/opsx,skills}`, `~/.agents/skills` (Codex), and
  `~/.config/opencode/{skills,commands}` (OpenCode).
- **Caveman** (plugin, tag `v1.9.1`) is Claude Code-only.

GitHub-release binaries (per-arch, sha256-pinned): `rtk` (v0.45.0), `git-delta` (0.19.2),
`codebase-memory-mcp` (v0.10.8, MCP — a ~280 MB static binary; installed from the release, not from
its npm shim, which would download the binary unverified at install/first run).
CLI utilities: `jq`, `ripgrep`, `fd`, `tree`, `fzf`, `mc`, `gnupg`.

See [CLAUDE.md](./CLAUDE.md) for the full architecture and per-component details.

## Requirements

- Docker
- Credentials for the agent(s) you run:
  - **claude:** an OAuth token (`claude setup-token`) or `claude auth login`
  - **codex:** `CODEX_API_KEY` (non-interactive) or `codex login`
  - **opencode:** provider keys (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …) or `opencode auth login`
- (optional) Context7 / Perplexity API keys for those MCP servers (`cloudflare-docs` needs none)
- (optional) a scoped git deploy key if you want the agent to `git push`

## Setup

```bash
cp .env.example .env
# Fill in the credentials for the agent(s) you use and any optional MCP keys.
# .env is gitignored and must never be committed.
```

## Container image (GHCR)

CI publishes three multi-arch images (amd64 + arm64) to GitHub Container Registry:

```bash
docker pull ghcr.io/highload-zone/claude-code-standalone:claude    # or :codex / :opencode
```

- **Versioning is pinned by releases.** A git tag `vX.Y.Z` (a Release) publishes `:X.Y.Z-<agent>`,
  `:X.Y-<agent>`, `:X-<agent>`. `main` publishes `:<agent>`; the claude image also gets `:latest`.
  Every build also gets `:sha-<short>-<agent>`.
- Built with the built-in `GITHUB_TOKEN` (`packages: write`) — no extra secrets. Pull requests only
  build for verification (no push).
- The GHCR package may be created **private** on first publish — make it public in the repo's
  *Packages* settings for anonymous `docker pull`.

## Build (locally)

```bash
./build.sh                  # all three: :claude, :codex, :opencode (and :latest = claude)
./build.sh codex            # just one target
./build-nocache.sh claude   # clean build of one target
```

To change a pinned tool version: edit `tools/package.json` (shared) or
`tools/agents/<agent>/package.json` (agent CLI), then regenerate the matching lockfile inside Node 24
(`--package-lock-only`, one command per changed package dir).

## Run

From your project directory:

```bash
./run_agent.sh claude                 # autonomous Claude Code agent over the current dir (read-write)
./run_agent.sh codex                  # Codex
./run_agent.sh opencode               # OpenCode
./run_agent.sh codex mcp list         # args forward to the agent ('codex mcp list')
./debug-shell.sh codex                # bash shell inside the codex image
./run-diagnostics.sh codex            # MCP server diagnostics for that image
```

`./run_claude.sh [args]` is kept as a back-compat alias for `./run_agent.sh claude [args]`.

The current directory is mounted **read-write at `/workspace/project`** and the container runs as your host
user, so the agent can edit, commit, and push. A per-agent login directory is mounted from
`~/.config/agent-standalone/login/<agent>` (disable with `AGENT_LOGIN_MOUNT=0`). To enable `git push`,
point `DEPLOY_KEY` at a **scoped** repo deploy key (mounted read-only, used with `IdentitiesOnly` —
the agent can push only to that repo and cannot ssh elsewhere):

```bash
export DEPLOY_KEY=/path/to/repo_deploy_key
./run_agent.sh claude
```

Without `DEPLOY_KEY`, edit + local commit work; push does not. Git commit identity is taken from your
host `git config` (passed as env), so commits are attributed to you.

> **The in-container path changed from `/workspace` to `/workspace/project`.** `codebase-memory-mcp`
> refuses to index any first-level path as a root since its v0.10.0 (upstream PR #1464 — the refusal
> exists to stop an accidental `index_repository` on `~` or `/`, and cannot be lifted with
> `allow-root`). Mounting one level down keeps the code-intelligence graph working, and `/workspace`
> is now the `CBM_ALLOWED_ROOT` boundary. If you scripted anything against the old path, update it.

## Dev Container

Three configs open your project **inside** a hardened image as an interactive development
environment (VS Code Dev Containers, JetBrains Gateway, GitHub Codespaces, or the `devcontainer`
CLI): `.devcontainer/devcontainer.json` (claude, the default), `.devcontainer/codex/` and
`.devcontainer/opencode/`. Unlike the agent entrypoint, you work in the container shell and run the
agent yourself; the image's auto-launch ENTRYPOINT is suppressed (`overrideCommand: true`).

- Pulls the matching `:<agent>` image tag (pin a release tag for reproducibility).
- Keeps the hardened profile (`cap-drop=ALL` + minimal caps for the uid-remap, `no-new-privileges`)
  with a raised `--pids-limit=512` for interactive tooling.
- Runs as the non-root `claude` user with `updateRemoteUserUID` so workspace files are owned by you.
- Reads the agent's credentials plus `CONTEXT7_API_KEY` / `PERPLEXITY_API_KEY` from your host env.

## Security disclosures

See [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)
