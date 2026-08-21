# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a security-hardened Docker container that runs Claude Code with pre-installed tools for general software development. The container is designed for isolated, secure execution of development tasks.

## Architecture

### Container Structure

The container is built on Node.js 22 (LTS) with the following layers:

1. **Base System** - Debian Trixie (glibc 2.41) with hardened security settings
2. **Toolchain (npm)** - All global npm CLIs installed via `npm ci` from `tools/package.json` + `tools/package-lock.json` (sha512-integrity, exact pinned versions, no `@latest`). Bins exposed via PATH (`/opt/toolchain/node_modules/.bin`). Includes Claude Code (2.1.238), OpenSpec (1.10.0), CodeGraph (1.5.0), caveman-shrink (0.1.0), the MCP servers, and dev tools (pnpm 11.22.0, typescript 6.0.3, ts-node 10.9.2, prettier 3.9.6, eslint 10.8.1)
3. **OpenSpec** - initialized into the build HOME (`/home/claude`) at build time, with telemetry disabled via `OPENSPEC_TELEMETRY=0`. The project itself is NOT initialized at build — it is overlaid by the runtime mount
4. **RTK** - Rust Token Killer; static musl binary in `/usr/local/bin` (version via `RTK_VERSION` build arg, sha256-verified); `rtk init -g --auto-patch` installs a Claude Code PreToolUse hook that rewrites Bash commands through `rtk`
5. **Caveman** - Output-compression skill for Claude Code, installed at build time via its plugin mechanism (`claude plugin install`), pinned to tag `v1.9.1`
6. **CodeGraph** - Code knowledge graph exposed as an MCP server (`@colbymchenry/codegraph`); ships a vendored prebuilt binary, runtime GitHub download disabled via `CODEGRAPH_NO_DOWNLOAD=1`
7. **codebase-memory-mcp** - Tree-sitter code-intelligence graph exposed as an MCP server; a single static GitHub-release binary in `/usr/local/bin` (version via `CBM_VERSION` build arg, default `v0.10.8`, sha256-verified per arch). NOT installed from npm — see "codebase-memory-mcp" under Pre-installed Tools
8. **MCP Servers** - Configured from MCP JSON configs; all stdio servers use pre-installed bins (no runtime `npx`)

### Security Features

The container implements defense-in-depth:
- Runs as non-root user (UID 1001)
- All capabilities dropped (`--cap-drop=ALL`)
- No privilege escalation allowed
- Read-only input mounts
- Executable protection on temp filesystems (`noexec`, `nosuid`)
- PID limits to prevent fork bombs (100 processes)
- Network isolation (bridge mode only)
- Removed dangerous setuid binaries and network reconnaissance tools

### Volume Mounts (single read-write mode)

- `/workspace/project` - the host project, mounted **read-write** (`$(pwd)`). The agent edits/commits/pushes
  here. The container runs with `--user $(id -u):$(id -g)` so it owns this mount.
- `HOME` (`/home/agent`) - writable tmpfs; the entrypoint copies the baked agent state
  (`/home/claude`) into it at start.
- `/tmp` - non-executable tmpfs scratch (`noexec,nosuid`)
- optional `DEPLOY_KEY` - a scoped repo deploy key mounted read-only for `git push`

### Configuration

Claude Code configuration is pre-configured in the container:
- `claude-config.json` - Main Claude configuration with all permissions enabled
- `settings.local.json` - Local settings copied to `~/.claude/settings.local.json` (permissions allow/deny/ask)
- `settings.json` - User settings copied to `~/.claude/settings.json`: `permissions.defaultMode: "auto"`, `autoMode.classifyAllShell: true`, `advisorModel: "opus"`, `agentPushNotifEnabled: true`, `workflowSizeGuideline: "small"`, `autoUpdates: false`, `tui: "default"` (suppresses the fullscreen-renderer prompt), and the `statusLine` (must be in settings.json, not settings.local.json — that's where Claude Code reads it). Auto mode must be in user-home, not project scope
- All permissions are auto-accepted for jailfree operation mode

## Common Commands

### Build and Run

```bash
# Build the container (with cache). npm CLI versions come from tools/package-lock.json
./build.sh

# Build without cache (clean build)
./build-nocache.sh

# Direct docker build command
docker build -t claude-code-standalone .

# To change a pinned npm CLI version: edit tools/package.json, then regenerate the
# lockfile inside node:22 (see "Environment Variables" → npm CLI versions), and rebuild.

# Run Claude Code interactively
./run_claude.sh

# Run with specific Claude Code arguments
./run_claude.sh --model opus --verbose


# Open debug shell in container
./debug-shell.sh

# Run MCP server diagnostics
./run-diagnostics.sh
```

### Inside Container

Once inside the container (via `debug-shell.sh` or `run_claude.sh`):

```bash
# Check Claude configuration
cat ~/.claude.json
ls -la ~/.claude/

# Verify installed tools and versions
claude-code --version  # Check Claude Code version
claude --version       # Alternative command
pnpm --version
node --version
npm --version

# Verify command line utilities
jq --version
rg --version
fdfind --version
tree --version
delta --version

# Test git delta configuration
git config --global --get core.pager
git diff --help  # Will show diff with delta formatting
```

### MCP Servers

MCP (Model Context Protocol) servers are configured via JSON files and installed automatically during container build.

All MCP servers currently live in `mcp-servers.json` and are installed verbatim by
`install-mcp-servers.sh` into `~/.claude.json` under `.projects["/workspace/project"].mcpServers`.
`mcp-servers-optional.json` is currently empty (`{}`).

Servers defined in `mcp-servers.json`:
- **CodeGraph** - Code knowledge graph; wrapped by `caveman-shrink` (`command: caveman-shrink`, `args: ["codegraph","serve","--mcp"]`) to compress tool descriptions. Requires a per-project `.codegraph/` index (see "CodeGraph indexing" below). No API key. Both `caveman-shrink` and `codegraph` are pre-installed (local upstream, so no npx round-trip and no `MCP_TIMEOUT` risk)
- **Sequential Thinking** - Enhanced reasoning capabilities; pre-installed bin `mcp-server-sequential-thinking` (pkg `@modelcontextprotocol/server-sequential-thinking@2026.7.4`)
- **Context7** - Up-to-date documentation (`type: http`, sends header `CONTEXT7_API_KEY`)
- **Cloudflare docs** - Cloudflare / Vite / Vitest documentation retrieval (`type: http`, url `https://stack.mcp.cloudflare.com/mcp?libs=…`). **No API key, no headers, no npm package** — there is nothing to pre-install and nothing to add to `.env`; the `?libs=…` query string selects the indexed library set and must be copied verbatim
- **Perplexity** - Web search and research; pre-installed bin `perplexity-mcp` (pkg `perplexity-mcp@0.2.3`, env `PERPLEXITY_API_KEY`)
- **codebase-memory-mcp** - Tree-sitter code-intelligence graph; pre-installed static binary `codebase-memory-mcp` (GitHub release `v0.10.8`, sha256-pinned per arch), invoked with no args — the binary detects MCP stdio mode itself. No API key. Requires an explicit `index_repository` call per repo (see "codebase-memory-mcp indexing" below)

**Important about API-key substitution:** `install-mcp-servers.sh` performs `${VAR}`
substitution **only** for entries read from `mcp-servers-optional.json`. Servers in the
base `mcp-servers.json` are copied as-is, so Context7/Perplexity are written into
`~/.claude.json` with **literal** `${CONTEXT7_API_KEY}` / `${PERPLEXITY_API_KEY}`
placeholders. **Verified by build+run:** Claude Code **does** expand these `${VAR}` references
at connect time from the container env (passed via `--env-file .env`) — `claude mcp list`
shows both `context7` and `perplexity` as ✓ Connected. So the literal placeholders are fine
as long as the vars are present in the runtime env; build-time substitution is not required.

**No runtime installs — all MCP servers are pre-installed (supply-chain hardening):** every
stdio MCP server invokes a **pre-installed, pinned binary** (`mcp-server-sequential-thinking`,
`perplexity-mcp`, `codegraph`, `codebase-memory-mcp`, plus the `caveman-shrink` wrapper), never
`npx -y <pkg>`. Nothing is fetched from the network to start a server. HTTP servers (`context7`,
`cloudflare-docs`) have nothing to pre-install by construction. **Verified by build+run:** all **six**
servers show `✓ Connected` under the **default** `MCP_TIMEOUT=10000` (10s) — the whole
`claude mcp list` health check takes ~5.7s wall-clock, including the 280 MB `codebase-memory-mcp`
binary (its size does not cost cold-start latency). There is no package download to
race the timeout (the earlier `npx -y` form intermittently failed on a cold cache). When adding a
new server, pre-install its package globally in the `Dockerfile` at a pinned version and point the
config at the installed bin — do **not** use `npx -y`. For an **HTTP** server there is nothing to
pre-install: add the `type: http` + `url` entry only.

**Adding new MCP servers:**
1. **Pre-install the server package** globally in the `Dockerfile` at a **pinned** version
   (supply-chain policy: no runtime installs — see the note above). For an stdio server, do
   `npm install -g <pkg>@<version>`; point the config at the installed bin, not `npx -y <pkg>`.
2. Edit `mcp-servers.json` (copied as-is, no env substitution) or
   `mcp-servers-optional.json` (only this file gets `${VAR}` substitution at build time, and
   a server is skipped if any referenced variable is unset)
3. Use standard MCP server JSON format (see files for examples)
4. Add required environment variables to `.env` file (e.g., `NEW_SERVICE_API_KEY=xxx`)
5. Rebuild container: `./build.sh`

Variables from `.env` are automatically passed to the container at runtime - no script modifications needed.

**Environment variables for MCP servers:**

All environment variables from `.env` file are automatically passed to the container:

```bash
# 1. Create .env file from example
cp .env.example .env

# 2. Edit .env and add your API keys
nano .env  # or use any text editor

# 3. Run container - all variables from .env will be automatically loaded
./run_claude.sh
```

The scripts (`run_claude.sh` and `debug-shell.sh`) dynamically read all variables from `.env` and pass them to Docker. You can add any new API keys or environment variables to `.env` without modifying the scripts.

**Checking installed MCP servers:**
```bash
# Inside container
cat ~/.claude.json | jq '.projects["/workspace/project"].mcpServers | keys'

# View specific server configuration
cat ~/.claude.json | jq '.projects["/workspace/project"].mcpServers["perplexity"]'
```

### CodeGraph indexing

CodeGraph stores its index in `.codegraph/codegraph.db` inside the indexed tree. Since
`/workspace/project` is mounted **read-write**, this is straightforward:

- Run `codegraph init -i /workspace/project` once per project/session to build the index (writes
  `/workspace/project/.codegraph/`). The MCP server (`codegraph serve --mcp`) is launched by Claude
  Code with `/workspace/project` as CWD and uses that index; without it the tools report "not
  initialized" (the server itself still starts).
- The file watcher uses `inotify`; in a caps-dropped container it may not fire. If needed, disable it
  with `CODEGRAPH_NO_DAEMON=1` and rely on connect-time catch-up, or run `codegraph sync` manually.
- Permissions: the image allows `mcp__*` (full bypass in `claude-config.json`), so the
  `mcp__codegraph__*` tools need no extra allow-list entry.

### codebase-memory-mcp indexing

Unlike CodeGraph, codebase-memory-mcp does **not** write into the indexed tree: its graph lives in
`$CBM_CACHE_DIR`, default `~/.cache/codebase-memory-mcp/`, keyed by project.

- **Why the project is mounted at `/workspace/project` and not `/workspace`.** Since v0.10.0 the
  binary refuses to index any **first-level** path as a root: `index_repository` on `/workspace`
  answers `"/workspace: path is too broad to index as one root; name a project directory below it"`.
  Measured: `/workspace` and `/proj` are refused, `/workspace/repo`, `/srv/x` and `/w/x` are indexed.
  The rule comes from upstream PR #1464 (`src/foundation/workspace.{c,h}`, first shipped in v0.10.0),
  which rejects a candidate root less than two components below the volume; its motivation is issue
  #1241, an OOM from indexing `~`. It **cannot be lifted**: `allow-root /workspace` answers
  `refused`, and `--approve-sensitive` does not apply. Hence the mount lives one level down.
- **`CBM_ALLOWED_ROOT=/workspace` is baked in** (see "Baked-in `ENV`"), confining indexing to the
  project mount. This became possible only because `/workspace` is now the single entrypoint path;
  the previous ACP adapter mounted the project at its host-absolute path, which is why the variable
  used to be left unset. **Verified as a live control, not a dead knob:** `index_repository` on
  `/home/agent` is refused with `"/home/agent is outside the allowed root. To allow it, run:
  codebase-memory-mcp allow-root /home/agent"`, while `/workspace/project` indexes normally.
- **The graph UI is turned OFF at build time** (`codebase-memory-mcp config set ui_enabled false`).
  Upstream defaults `ui_enabled` to **true**, so the coordination daemon otherwise binds
  `127.0.0.1:9749` on the first MCP session — measured, and contrary to the upstream README, which
  documents the UI as needing an explicit `--ui=true --port=9749`. **Verified in the built image:**
  `/proc/net/tcp` and `/proc/net/tcp6` show no listening socket, and the daemon log has no
  `ui.serving` line.
- **v0.10.x runs a background daemon.** The first MCP session starts a detached
  `codebase-memory-mcp --cbm-daemon-internal`, and there is no setting to opt out. **Measured in the
  built image** under the production profile: **2 processes** for this server (frontend + daemon)
  versus 1 on v0.9.0, and a `watcher.start` entry in the daemon log (`auto_watch` defaults to true).
  Two PIDs fit the `--pids-limit=100` budget comfortably, so `auto_watch` is left alone. Idle CPU is
  a spike to ~100% of one core at daemon start, then 2.1–2.4% steady (v0.9.0: 0.01–0.03%) — see the
  open upstream issue #1764, whose severe form is reported on Windows.
- **The cache dir is deliberately left at its default.** In this image HOME is a writable **tmpfs**
  populated by the entrypoint, so the index does **not** survive a container restart and must be
  rebuilt per session (`index_repository` — for typical repos this is seconds). A baked
  `CBM_CACHE_DIR=/workspace/...` was rejected because writing an index directory into the user's repo
  is not this container's business. If you want persistence, pass it per-run:
  `-e CBM_CACHE_DIR=/workspace/project/.cache/codebase-memory-mcp` in `run_claude.sh`.
- **Consequence of that default:** the graph lands in the HOME tmpfs, which `run_claude.sh` sizes at
  **512 MB** and which also holds all Claude Code agent state. 2.3 MB for this repo, but the graph
  grows with the tree — on a large monorepo the same `-e CBM_CACHE_DIR=…` override (pointing at the
  rw project mount) is the way to keep the index out of that tmpfs budget.
- Indexing is explicit: call the `index_repository` tool (`{"repo_path": "/workspace/project"}`).
  Until then the query tools have no graph to answer from (the server itself still starts).
  **Verified in the built image** (caps dropped, `--pids-limit=100`, tmpfs HOME, host uid): indexing
  this repo yields **231 nodes / 279 edges** in ~6s and a **2.3 MB** cache.
- Permissions: covered by the image-wide `mcp__*` allow (`claude-config.json`), like CodeGraph.
- Other env knobs (all unset here, upstream defaults apply): `CBM_LOG_LEVEL`, `CBM_WORKERS`,
  `CBM_MEM_BUDGET_MB`, `CBM_DIAGNOSTICS`, `CBM_DOWNLOAD_URL`. With `CBM_MEM_BUDGET_MB` unset the
  binary auto-sizes from **host** RAM (observed on this host: `mem.init budget_mb=31876
  total_ram_mb=63752`) — the container has no `--memory` cap, so on a memory-tight host set this
  explicitly. Upstream also documents `CBM_WORKERS` as the knob for containers, where
  `sysconf(_SC_NPROCESSORS_ONLN)` reports host CPUs rather than the cgroup quota.

## Environment Variables

**npm CLI versions are NOT build args.** claude-code, openspec, codegraph, caveman-shrink,
the stdio MCP servers, and dev tools are all pinned in `tools/package.json` and locked (with
sha512 integrity) in `tools/package-lock.json`, installed via `npm ci`. To change a version:
edit `tools/package.json`, then regenerate the lockfile **inside node:22** (host npm may write a
different `lockfileVersion`):
```bash
docker run --rm -v "$PWD/tools:/w" -w /w node:22-trixie-slim npm install --package-lock-only
```
After regenerating, run `npm audit` in the same `node:22` image — and, when a clean non-breaking
fix is offered, `npm audit fix --package-lock-only` — so transitive security advisories surface and
get patched instead of silently shipping. `npm install` keeps in-range pinned transitive versions,
so an already-applied patch is not downgraded by a later regen. Pin only Node-22-compatible versions — check `npm view <pkg>@<ver> engines.node`. The build-time
gate runs each dev tool's `--version` to catch an incompatible engine (this is how the earlier
pnpm 11 vs Node 20 mismatch was caught before the base was bumped to Node 22).

**`typescript` is deliberately held at 6.0.3, NOT the `latest` dist-tag.** `latest` is 7.x, the
native (Go) compiler rewrite, whose npm package no longer exposes the full JS compiler API. Under
typescript 7.0.2 `ts-node` 10.9.2 crashes on any invocation (`TypeError: Cannot read properties of
undefined (reading 'fileExists')` — `ts.sys` is undefined), while `tsc` itself still compiles and
type-checks correctly. 6.0.3 is the head of the 6.x line. Do not bump to 7.x until `ts-node` is
replaced (e.g. by `tsx`) or gains TS-7 support. Note `ts-node --version` does NOT detect this — it
prints a constant without loading the compiler; the build gate therefore also runs
`ts-node -e '<typed snippet>'`.

**Build-time variables** (set during `docker build`):
- `RTK_VERSION` - Git tag of the RTK release to download (default: `v0.45.0`); RTK is a
  GitHub-release binary, not npm. Override directly: `docker build --build-arg RTK_VERSION=...`
- `CBM_VERSION` - Git tag of the codebase-memory-mcp release to download (default: `v0.10.8`); also a
  GitHub-release binary, not npm (its npm package would download the binary unverified — see
  Pre-installed Tools). Override: `docker build --build-arg CBM_VERSION=...`
- The per-arch **sha256 values are not build args** — they are hardcoded in the `case "$TARGETARCH"`
  blocks of the `RUN` layers (RTK, git-delta, codebase-memory-mcp). Bumping a version without
  refreshing both hashes fails the `sha256sum -c` check by design.

**Runtime variables** (set when running container):
- `CLAUDE_CODE_OAUTH_TOKEN` - OAuth token for Claude Code authentication (required)
- `CLAUDE_BYPASS_PERMISSIONS` - set to `1` to add `--dangerously-skip-permissions` to the entrypoint
  (off by default; default is auto mode). Full bypass, no in-app safety checks — for isolated/throwaway
  containers only.
- `CLAUDE_REMOTE_CONTROL` - **on by default**; the entrypoint adds `--remote-control` to every
  session. Set to `0` to opt out. Requires a full-scope login token (`claude auth login` run inside
  the container); with the inference-only `CLAUDE_CODE_OAUTH_TOKEN` the flag is inert — verified via
  `claude doctor`, which reports "Remote Control requires a full-scope login token. Long-lived tokens
  (from claude setup-token or CLAUDE_CODE_OAUTH_TOKEN) are limited to inference-only for security
  reasons". The entrypoint prints that caveat at startup whenever `CLAUDE_CODE_OAUTH_TOKEN` is set,
  so the default is never a silent no-op. There is no settings.json key that turns RC on (only
  `disableRemoteControl` to turn it off), which is why this is a CLI flag and not a config key.
- `CLAUDE_REMOTE_CONTROL_PREFIX` - prefix for auto-generated Remote Control session names
  (`<prefix>-<random-words>`). The CLI default is the hostname, which in a container is a throwaway
  hex id; `run_claude.sh` and the `claude-box` launcher pass the host project directory name, and the
  entrypoint falls back to `claude-box`. Sanitised to `[[:alnum:]._-]`, truncated to 40 chars.
- `MCP_TIMEOUT` - MCP server connection timeout in milliseconds (default: `10000` = 10 seconds)
- All variables from `.env` file are automatically passed to the container

**Baked-in `ENV` (set in the Dockerfile, not via `.env`):**
- `MCP_TIMEOUT=10000`, `ENABLE_EXPERIMENTAL_MCP_CLI=1`, `ENABLE_LSP_TOOL=1`
- Runaway-fan-out budgets (all overridable from `.env` — `docker -e` wins over image `ENV`):
  `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=12` (upstream default 20),
  `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION=100` and
  `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION=100` (upstream default 200 each),
  `CLAUDE_CODE_RETRY_WATCHDOG=1`. The concurrency number is derived from a measurement in
  this image: 4 processes before `claude`, ~11 with `claude` + the four MCP servers, peaking
  at 15 with three parallel Bash tool calls — so ~1-2 PIDs per in-flight tool call over an
  ~11-PID floor, and the upstream 20 crowds the `--pids-limit=100` cgroup cap. **`0` does NOT
  disable the session counters** — observed: with either counter set to `0` the action still
  ran, i.e. `0` behaves as if the variable were unset. Use `1` for the tightest real limit.
- `OPENSPEC_TELEMETRY=0` (disables OpenSpec telemetry at build and runtime)
- `CODEGRAPH_NO_DOWNLOAD=1` (forbids CodeGraph's runtime binary download from GitHub Releases; binary must come from the npm registry)
- `CBM_ALLOWED_ROOT=/workspace` — confines codebase-memory-mcp's indexing to the project mount; an
  `index_repository` whose `repo_path` resolves outside it is refused. Correct because every
  entrypoint mounts the project at `/workspace/project` (see "codebase-memory-mcp indexing")
- `NODE_ENV=production`, plus security limits (`RLIMIT_CORE=0`, `RLIMIT_NOFILE=1024`, `YAMA_PTRACE_SCOPE=1`)

**Pre-configured behavior:**
- **Permission mode = `auto`** (set in `~/.claude/settings.json`, NOT `claude-config.json`). `auto`
  must live in user-home `settings.json` — Claude Code (v2.1.142+) ignores `defaultMode: "auto"` from
  project-scope settings. `claude-config.json` (`~/.claude.json`) is deliberately stripped of all
  mode/auto-accept-forcing keys (`dangerouslySkipPermissions`, `autoAcceptPermissions`,
  `defaultPermissionMode`, project `permissions.defaultMode`, `autoAccept*`) so settings.json is the
  single source of mode. Trust/onboarding keys (`hasTrustDialogAccepted`, `hasCompletedOnboarding`,
  `autoTrustNewProjects`, `suppressTrustPrompts`, `bypassPermissionsModeAccepted`) are kept to avoid
  first-run dialogs in headless.
- **`advisorModel: "opus"`** (in `settings.json`) — Claude consults Opus at decision points (Anthropic
  API only). No-op if the main model outranks Opus (e.g. Fable).
- `claude-config.json` still pre-approves tools for `/workspace/project` (`allow` rules + `mcp__*`); note auto
  mode drops blanket `Bash(*)`/`Agent` rules at runtime (the classifier takes over).
- **`autoMode.classifyAllShell: true`** (in `settings.json`) — routes *every* Bash/PowerShell command
  through the auto-mode classifier instead of only arbitrary-code-execution patterns. Upstream default
  is `false`; enabled here because the agent runs unattended.
- **`agentPushNotifEnabled: true`** (in `settings.json`) — lets Claude push proactively to the phone
  when Remote Control is connected. Upstream default is `false`. Inert until Remote Control actually
  establishes (see `CLAUDE_REMOTE_CONTROL`).
- **`workflowSizeGuideline: "small"`** (in `settings.json`) — advisory guideline for how large Claude
  makes dynamic workflows. Accepted values are `unrestricted` / `small` / `medium` / `large`; upstream
  default is `medium`. Set to `small` to match this container's constrained fan-out budget — this is a
  judgement call, not a hard limit, and is the one key here worth revisiting if workflows feel starved.
- **Verification status of the four keys above.** Two are behaviourally verified. With
  `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION=1` the second WebSearch is refused: "this session has
  used its web search budget (1 of 1 WebSearch calls)". With `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=1`,
  two of three parallel Agent calls are refused: "Concurrent subagent limit reached. You can run 1
  subagents at once." `CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION` was not exercised directly — it shares
  the read path of the two that were. `CLAUDE_CODE_RETRY_WATCHDOG` is read through the boolean env
  parser (`1/true/yes/on`). `autoMode.classifyAllShell`,
  `agentPushNotifEnabled` and `workflowSizeGuideline` are *accepted* — they appear in the 2.1.220
  settings-key table, their values come from the binary's own enum/parser, and `claude doctor` on
  **2.1.238** reports "No installation issues found." (the only note is the expected Remote Control
  full-scope-token caveat) — but their runtime effect was **not** observed: the workflow-size system
  reminder is not injected in `-p`/headless runs, and `agentPushNotifEnabled` cannot do anything until
  Remote Control actually connects (which needs `claude auth login`).
- `alwaysThinkingEnabled: true`, `autoUpdates: false`
- The `typescript-lsp@claude-plugins-official` plugin is enabled (works with `ENABLE_LSP_TOOL=1`)
- The OAuth account is hard-coded in `claude-config.json` — replace it if using a different account

## Development Workflow (single read-write mode)

1. **Run from your project**: `cd /path/to/repo && ./run_claude.sh`. The current directory is mounted
   **read-write** at `/workspace/project`; the container runs as your host user (`--user $(id -u):$(id -g)`).
2. **Entrypoint**: `claude` (auto mode via settings.json); the entrypoint first copies the baked
   agent state from `/home/claude` into the writable tmpfs HOME. `CLAUDE_BYPASS_PERMISSIONS=1` is
   opt-in and adds `--dangerously-skip-permissions` (full bypass for isolated containers).
   `--remote-control` is added by **default** (opt out with `CLAUDE_REMOTE_CONTROL=0`), together with
   `--remote-control-session-name-prefix` from `CLAUDE_REMOTE_CONTROL_PREFIX`; it needs a full-scope
   `claude auth login` token — the inference-only `CLAUDE_CODE_OAUTH_TOKEN` cannot drive it, and the
   entrypoint says so at startup.
3. **Autonomous agent**: Claude edits/commits the project directly in `/workspace/project`. For `git push`,
   set `DEPLOY_KEY=/path/to/repo_deploy_key` (scoped, read-only mounted). Commit identity comes from
   your host `git config` (passed as env).
4. **Trust**: the project is read-write and the agent is autonomous — use on trusted projects (see
   [SECURITY.md](./SECURITY.md)).

## IDE integration (Dev Container)

One extra entrypoint exists beside the autonomous `run_claude.sh`; it shares the same image.

- **Dev Container — `.devcontainer/devcontainer.json`**. Opens the project *inside* the image as an
  interactive dev environment. Pulls the GHCR image; `overrideCommand: true` suppresses the
  auto-launch ENTRYPOINT (you run `claude` yourself). Hardened (`cap-drop=ALL` + the minimal caps the
  `updateRemoteUserUID` remap needs: `CHOWN`/`DAC_OVERRIDE`/`FOWNER`/`SETUID`/`SETGID`),
  `no-new-privileges`, `--pids-limit=512`, non-root `claude` user.

## Pre-installed Tools

### Package Managers
- **pnpm** - Fast, disk space efficient package manager (Node.js)
- **npm** - Node.js package manager

### Development Tools
- **TypeScript** - TypeScript compiler and runtime (ts-node)
- **ESLint** - JavaScript/TypeScript linting
- **Prettier** - Code formatting
- **OpenSpec** - `@fission-ai/openspec` CLI for spec-driven development (`openspec` binary)
  - Installed globally via npm; requires Node.js >= 20.19.0 (satisfied by the `node:22-trixie-slim` base)
  - Initialized at build time into the build HOME via `openspec init /home/claude --tools claude --force` (non-interactive). This bakes `~/.claude/commands/opsx` + skills, which the entrypoint copies into the runtime HOME — so the opsx slash-commands are available. (The project mount is NOT initialized at build because it is overlaid at runtime.)
  - Run `openspec init` inside the actual project (`/workspace/project`, read-write) on demand
  - Telemetry is opt-out only via the `OPENSPEC_TELEMETRY=0` env var (no `telemetry.enabled` config key exists); set as baked-in ENV, covering build and runtime
  - Source: https://github.com/Fission-AI/OpenSpec
- **RTK** - Rust Token Killer; CLI proxy that filters/compresses command output to cut LLM token usage (`rtk` binary)
  - Static musl binary downloaded from GitHub releases into `/usr/local/bin`; pinned via `RTK_VERSION` build arg (default `v0.45.0`), no Rust toolchain needed
  - `rtk init -g --auto-patch` runs at build time (as the `claude` user): installs a **Claude Code PreToolUse hook** that transparently rewrites Bash commands (`git status` → `rtk git status`), writes `~/RTK.md`, and patches `~/.bashrc`
  - `-g` targets Claude Code (there is no `--agent claude`); `--auto-patch` makes init non-interactive
  - Runtime needs only the `rtk` binary in PATH + the hook; no daemon. Optional config at `~/.config/rtk/config.toml`
  - Source: https://github.com/rtk-ai/rtk
- **Caveman** - Output-compression skill for Claude Code (terse "caveman-speak"), reduces output tokens (~65%)
  - Installed at build time via `npx -y github:JuliusBrussee/caveman#v1.9.1 --non-interactive --only claude --no-mcp-shrink` (as the `claude` user; requires Node.js >= 18)
  - For the `claude` provider the installer uses the Claude Code **plugin mechanism** (`claude plugin marketplace add` + `claude plugin install caveman@caveman`); by default it would also add a `caveman-shrink` MCP entry — suppressed here with `--no-mcp-shrink`, see below
  - **Verified by build+run:** the `claude plugin marketplace add` + `claude plugin install` steps succeed during `docker build` — `marketplace add` is a public HTTPS git clone and `plugin install` is a local copy, so neither hits the Claude auth API (and `configure-claude.sh` has already written `~/.claude.json` by that layer). The hooks come from the **plugin manifest**, not from `settings.json`: measured in the built image, `.hooks.SessionStart` and `.hooks.UserPromptSubmit` are empty and `.hooks.PreToolUse` holds only RTK's `rtk hook claude`, with `.statusLine` intact — i.e. the caveman layer does not clobber RTK's hook. Not made best-effort, so any future failure stays visible
  - **Held at `v1.9.1`; do NOT bump to v2.x without redoing this analysis.** Measured against v2.2.0: it adds a runtime dependency `@caveman-ai/cli: ^1.1.0` that ships its own `caveman` bin, which **shadows** the installer's bin under `npx` — so `npx -y github:JuliusBrussee/caveman#v2.2.0 --non-interactive …` never reaches `bin/install.js` and instead answers `unknown command "--non-interactive"` from the cloud CLI. The installer script itself still accepts the old flags; it is simply unreachable that way. Worse for this image, that dependency is a **floating** range in a build layer (against the exact-pin policy), and `@caveman-ai/cli` is an account/cloud CLI whose compression runs in "companion Go binaries" fetched by `caveman setup` — a runtime download this image forbids. `v1.9.1` has no dependencies at all
  - Installed with **`--no-mcp-shrink`**: caveman's auto-registration wired `caveman-shrink` as a standalone MCP server with no upstream command, which always `✗ Failed to connect` (it is middleware, not a server). Instead `caveman-shrink` is pre-installed globally and applied as a wrapper around the codegraph MCP server (see CodeGraph / MCP Servers)
  - Source: https://github.com/JuliusBrussee/caveman
- **CodeGraph** - Pre-indexed code knowledge graph (symbols, call graph, impact) served to agents over MCP (`codegraph` binary)
  - Installed via `npm ci` from the locked toolchain (`@colbymchenry/codegraph@1.5.0`); also registered as the `codegraph` MCP server, wrapped by `caveman-shrink` to compress its (verbose) tool descriptions — verified `✓ Connected` (see "MCP Servers")
  - **Not pure JS:** the npm package is a thin shim; the real artifact is a per-platform optionalDependency (`@colbymchenry/codegraph-linux-x64`) bundling a vendored Node 24 runtime + prebuilt binary. `codegraph --help` at build time verifies the binary runs (**verified**: the vendored Node 24 binary runs on `node:22-trixie-slim`)
  - `CODEGRAPH_NO_DOWNLOAD=1` (baked-in ENV) forbids the shim's runtime fallback that fetches the binary from GitHub Releases — the binary must come from the npm registry only
  - 100% local: local SQLite index (`.codegraph/codegraph.db`, FTS5), no API keys, no external services
  - See "CodeGraph indexing" for the index write-location constraint in this container
  - Source: https://github.com/colbymchenry/codegraph
- **codebase-memory-mcp** - Tree-sitter code-intelligence engine (knowledge graph of functions, classes, call chains, HTTP routes) served over MCP (`codebase-memory-mcp` binary)
  - **Installed from the GitHub release, NOT from npm** (`ARG CBM_VERSION=v0.10.8`, per-arch `-portable` static asset, sha256-pinned in the Dockerfile). The npm package `codebase-memory-mcp` is a 12 kB shim: its `postinstall` downloads the binary from GitHub Releases outside npm's sha512 integrity, treats a missing `checksums.txt` as non-fatal (silently skipping verification), and `bin.js` re-downloads the binary on first run if absent — a runtime fetch, which this image forbids
  - Single static binary, **280 MB** unpacked (vendored tree-sitter grammars + a vendored embedding model). **Measured on the built image:** it occupies a **279.6 MB** layer — third-largest, behind the `npm ci` toolchain layer (**1030.7 MB**) and the `apt-get install` system-deps layer (**426.2 MB**); the whole image is **2.01 GB**
  - The `-portable` Linux asset is the fully-static build; the plain `linux-*` asset needs glibc >= 2.38 (trixie has 2.41, so both would run — static is chosen to avoid the libc coupling)
  - Local SQLite graph under `$CBM_CACHE_DIR`, no API keys. Upstream states "zero network requests, no telemetry, no background version checks" — **not independently verified here**; note the binary does have a manual `update` subcommand and a `CBM_DOWNLOAD_URL` override, i.e. a download path exists (unlike codegraph, there is no env switch to forbid it; nothing invokes it in this image)
  - Registered as the `codebase-memory-mcp` MCP server, invoked with **no args** (the binary detects MCP stdio mode itself)
  - **Measured, not from the vendor README:** the MCP surface in v0.10.8 is **15** tools — `index_repository`, `search_graph`, `query_graph`, `trace_path`, `get_code_snippet`, `get_graph_schema`, `get_architecture`, `search_code`, `list_projects`, `delete_project`, `index_status`, `check_index_coverage`, `detect_changes`, `manage_adr`, `ingest_traces` (`tools/list` over stdio against the built image). That is up from **8** in v0.9.0: `list_projects`, `index_status`, `detect_changes`, `manage_adr` and `ingest_traces` used to be CLI-only and are now exposed over MCP, and `delete_project` / `check_index_coverage` are new
  - All query tools take a required `project` argument; the project name is derived from the indexed root path (`/workspace/project` → `workspace-project`) and is returned by `index_repository`. `list_projects` is now an MCP tool, so an agent that did not index in this session can enumerate project names without dropping to the CLI
  - See "codebase-memory-mcp indexing" for the cache-dir/tmpfs consequence and the explicit indexing step
  - Source: https://github.com/DeusData/codebase-memory-mcp
- **Git** - Version control with git-delta pre-configured for enhanced diffs
  - Delta is configured globally with side-by-side view and navigation
  - Automatically used for `git diff`, `git log -p`, and `git show`

### Command Line Utilities
- **jq** - JSON processor for parsing and manipulating JSON data
- **mc** - Midnight Commander file manager
- **fzf** - Fuzzy finder for interactive filtering
- **tree** - Display directory structure as tree
- **ripgrep (rg)** - Fast recursive search tool
- **fd-find** - Fast and user-friendly alternative to find
- **unzip** - Archive extraction utility
- **gnupg** - GPG encryption and signing tools

## Security Considerations

This container is designed for secure, isolated development:
- Never mount sensitive host directories as read-write
- The container cannot access host network (only bridge mode)
- Temp filesystems prevent execution of uploaded binaries
- Process limits prevent resource exhaustion attacks
- All network reconnaissance tools are removed

## Troubleshooting

### MCP Server Diagnostics
```bash
# Run automated diagnostics for MCP servers
./run-diagnostics.sh
```

This script checks:
- pre-installed MCP server binaries (`mcp-server-sequential-thinking`, `perplexity-mcp`, `codegraph`, `caveman-shrink`, `codebase-memory-mcp`)
- PATH configuration
- Claude Code MCP configuration
- File permissions

### Debug Shell Access
```bash
./debug-shell.sh
```

This opens a bash shell inside the container for debugging.

Inside the debug shell, you can run diagnostics manually:
```bash
/app/diagnose-mcp.sh
```

### Common Issues

**Claude Code doesn't start:**
- Verify `CLAUDE_CODE_OAUTH_TOKEN` is set: `echo $CLAUDE_CODE_OAUTH_TOKEN`
- Check configuration: `cat ~/.claude.json`

**Permission errors:**
- Input directory must exist before running
- Output directory is created automatically as `./reports/`

**MCP server not loading:**
- Check MCP configuration: `cat ~/.claude.json | jq '.projects["/workspace/project"].mcpServers'`
- Verify the server's pre-installed bin is on PATH (e.g. `command -v mcp-server-sequential-thinking perplexity-mcp codegraph caveman-shrink codebase-memory-mcp`)
- Check MCP timeout setting: `echo $MCP_TIMEOUT` (default: 10000ms = 10 seconds; all servers are pre-installed so no download races this)
- Run diagnostics: `./run-diagnostics.sh` or inside container: `/app/diagnose-mcp.sh`
- View MCP installation logs: Rebuild with `./build.sh` and check the `install-mcp-servers.sh` output

## Files of Interest

- `Dockerfile` - Complete container build configuration
- `tools/package.json` - Pinned npm CLI toolchain (claude-code, openspec, codegraph, caveman-shrink, MCP servers, dev tools) — exact versions, single source of truth
- `tools/package-lock.json` - Lockfile (sha512 integrity) for the toolchain; installed via `npm ci`. Regenerate inside node:22 after editing package.json
- `claude-config.json` - Claude Code configuration with all permissions
- `settings.local.json` - Local Claude settings (permissions allow/deny/ask)
- `settings.json` - User Claude settings baked to `~/.claude/settings.json`: `permissions.defaultMode: "auto"`, `autoMode.classifyAllShell: true`, `advisorModel: "opus"`, `agentPushNotifEnabled: true`, `workflowSizeGuideline: "small"`, `autoUpdates: false`, `tui: "default"`, and the `statusLine` (wired to `/usr/local/bin/claude-statusline.sh`)
- `statusline-command.sh` - Claude Code statusLine script (compact line: dir, git branch/dirty, model, duration, context %, 5h/7d rate limits); baked to `/usr/local/bin/claude-statusline.sh` (fixed, HOME-independent path). Deps (jq, git, awk, date, grep) are all present in the image
- `mcp-servers.json` - Base MCP server configurations (always installed)
- `mcp-servers-optional.json` - Optional MCP servers (require API keys)
- `install-mcp-servers.sh` - MCP installation script with variable substitution
- `.env.example` - Example environment variables for MCP servers
- `.env` - Your local environment variables (create from .env.example)
- `.dockerignore` - Files excluded from Docker build context
- `install.sh` - One-line installer (`curl … | bash`): pulls the GHCR image, stores the OAuth token in `~/.config/claude-standalone/claude.env` (chmod 600), and installs a `claude-box` launcher into `~/.local/bin` (the hardened `docker run` wrapped as an executable; supports `--uninstall` and a non-interactive path via `CLAUDE_CODE_OAUTH_TOKEN`). Also detects host `~/.claude/{agents,commands,skills}` and offers to pass them through — **mount** the live path (default), **copy** a snapshot to `~/.config/claude-standalone/resources/`, or **skip** (override non-interactively with `CLAUDE_RESOURCES_MODE`); the choice is written to `resources.conf`, `claude-box` mounts the paths read-only at `/host-claude/*`, and the entrypoint merges them OVER the baked state (host wins on collision; baked `opsx`/openspec skills survive)
- `run_claude.sh` - Main entry point for running Claude Code (autonomous agent)
- `.devcontainer/devcontainer.json` - Dev Container definition (interactive dev inside the image)
- `debug-shell.sh` - Debug shell access
- `run-diagnostics.sh` - Automated MCP server diagnostics (NEW)
- `diagnose-mcp.sh` - Diagnostics script (runs inside container)
- `build.sh` / `build-nocache.sh` - Container build scripts
