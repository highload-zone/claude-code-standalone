# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a security-hardened Docker container that runs Claude Code with pre-installed tools for general software development. The container is designed for isolated, secure execution of development tasks.

## Architecture

### Container Structure

The container is built on Node.js 22 (LTS) with the following layers:

1. **Base System** - Debian Bookworm with hardened security settings
2. **Toolchain (npm)** - All global npm CLIs installed via `npm ci` from `tools/package.json` + `tools/package-lock.json` (sha512-integrity, exact pinned versions, no `@latest`). Bins exposed via PATH (`/opt/toolchain/node_modules/.bin`). Includes Claude Code (2.1.159), OpenSpec (1.3.1), CodeGraph (0.9.8), caveman-shrink (0.1.0), the MCP servers, and dev tools (pnpm 11.5.0, typescript 6.0.3, ts-node 10.9.2, prettier 3.8.3, eslint 10.4.1)
3. **OpenSpec** - initialized into `/workspace` at build time with telemetry disabled via `OPENSPEC_TELEMETRY=0`
4. **RTK** - Rust Token Killer; static musl binary in `/usr/local/bin` (version via `RTK_VERSION` build arg, sha256-verified); `rtk init -g --auto-patch` installs a Claude Code PreToolUse hook that rewrites Bash commands through `rtk`
5. **Caveman** - Output-compression skill for Claude Code, installed at build time via its plugin mechanism (`claude plugin install`), pinned to tag `v1.8.2`
6. **CodeGraph** - Code knowledge graph exposed as an MCP server (`@colbymchenry/codegraph`); ships a vendored prebuilt binary, runtime GitHub download disabled via `CODEGRAPH_NO_DOWNLOAD=1`
7. **MCP Servers** - Configured from MCP JSON configs; all stdio servers use pre-installed bins (no runtime `npx`)

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

### Volume Mounts

- `/workspace/input` - Read-only input directory (mounted from host)
- `/workspace/output` - Read-write output directory for reports
- `/workspace/data` - Optional read-only reference data directory
- `/workspace/temp` - Non-executable temporary workspace

### Configuration

Claude Code configuration is pre-configured in the container:
- `claude-config.json` - Main Claude configuration with all permissions enabled
- `settings.local.json` - Local settings copied to `~/.claude/` and `/workspace/.claude/`
- All permissions are auto-accepted for jailfree operation mode

## Common Commands

### Build and Run

```bash
# Build the container (with cache). npm CLI versions come from tools/package-lock.json
./build.sh

# Build without cache (clean build)
./build-nocache.sh

# Direct docker build command
docker build -t claude-code-container .

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
`install-mcp-servers.sh` into `~/.claude.json` under `.projects["/workspace"].mcpServers`.
`mcp-servers-optional.json` is currently empty (`{}`).

Servers defined in `mcp-servers.json`:
- **CodeGraph** - Code knowledge graph; wrapped by `caveman-shrink` (`command: caveman-shrink`, `args: ["codegraph","serve","--mcp"]`) to compress tool descriptions. Requires a per-project `.codegraph/` index (see "CodeGraph indexing" below). No API key. Both `caveman-shrink` and `codegraph` are pre-installed (local upstream, so no npx round-trip and no `MCP_TIMEOUT` risk)
- **Sequential Thinking** - Enhanced reasoning capabilities; pre-installed bin `mcp-server-sequential-thinking` (pkg `@modelcontextprotocol/server-sequential-thinking@2025.12.18`)
- **Context7** - Up-to-date documentation (`type: http`, sends header `CONTEXT7_API_KEY`)
- **Perplexity** - Web search and research; pre-installed bin `perplexity-mcp` (pkg `perplexity-mcp@0.2.3`, env `PERPLEXITY_API_KEY`)

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
`perplexity-mcp`, `codegraph`, plus the `caveman-shrink` wrapper), never `npx -y <pkg>`. Nothing
is fetched from the network at runtime. **Verified by build+run:** all four servers show
`✓ Connected` under the **default** `MCP_TIMEOUT=10000` (10s) — there is no package download to
race the timeout (the earlier `npx -y` form intermittently failed on a cold cache). When adding a
new server, pre-install its package globally in the `Dockerfile` at a pinned version and point the
config at the installed bin — do **not** use `npx -y`.

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
cat ~/.claude.json | jq '.projects["/workspace"].mcpServers | keys'

# View specific server configuration
cat ~/.claude.json | jq '.projects["/workspace"].mcpServers["perplexity"]'
```

### CodeGraph indexing (write-location constraint)

CodeGraph stores its index in a `.codegraph/` directory **inside the indexed code tree**
(`<path>/.codegraph/codegraph.db`). There is no flag/env to relocate the DB away from `[path]`.
This interacts with the container's read-only mount model — but works without copying code, as
**verified by a build + run** (read-only `/workspace/input` mounted, `--cap-drop=ALL`):

- ✅ **Index from the writable WORKDIR:** `cd /workspace && codegraph init -i /workspace`
  indexes the whole `/workspace` tree — **including the read-only `/workspace/input` subdir
  (read access is fine)** — and writes the DB to `/workspace/.codegraph/` (writable). Verified:
  it indexed the mounted source and wrote **nothing** into `/workspace/input`.
- ❌ **Do NOT** run `codegraph init -i /workspace/input` directly — it tries to `mkdir
  /workspace/input/.codegraph` and fails with `ENOENT` on the read-only mount.
- The MCP server (`codegraph serve --mcp`) is launched by Claude Code with the project as CWD
  (`/workspace`, writable) and uses `/workspace/.codegraph/` when it exists. Without an index the
  CodeGraph tools report "not initialized" (the MCP server itself still starts), so run
  `codegraph init -i /workspace` once per session/project first.
- The file watcher uses `inotify`; in a sandboxed/caps-dropped container it may not fire. If
  needed, disable it with `CODEGRAPH_NO_DAEMON=1` and rely on connect-time catch-up, or run
  `codegraph sync` manually.
- Permissions: the image already allows `mcp__*` (full bypass in `claude-config.json`), so the
  `mcp__codegraph__*` tools need no extra allow-list entry.

## Environment Variables

**npm CLI versions are NOT build args.** claude-code, openspec, codegraph, caveman-shrink,
the stdio MCP servers, and dev tools are all pinned in `tools/package.json` and locked (with
sha512 integrity) in `tools/package-lock.json`, installed via `npm ci`. To change a version:
edit `tools/package.json`, then regenerate the lockfile **inside node:22** (host npm may write a
different `lockfileVersion`):
```bash
docker run --rm -v "$PWD/tools:/w" -w /w node:22-bookworm-slim npm install --package-lock-only
```
Pin only Node-22-compatible versions — check `npm view <pkg>@<ver> engines.node`. The build-time
gate runs each dev tool's `--version` to catch an incompatible engine (this is how the earlier
pnpm 11 vs Node 20 mismatch was caught before the base was bumped to Node 22).

**Build-time variables** (set during `docker build`):
- `RTK_VERSION` - Git tag of the RTK release to download (default: `v0.42.0`); RTK is a
  GitHub-release binary, not npm. Override directly: `docker build --build-arg RTK_VERSION=...`
- `RTK_SHA256` - sha256 of the RTK tarball (default matches `v0.42.0`); bump together with
  `RTK_VERSION` or the integrity check fails by design

**Runtime variables** (set when running container):
- `CLAUDE_CODE_OAUTH_TOKEN` - OAuth token for Claude Code authentication (required)
- `MCP_TIMEOUT` - MCP server connection timeout in milliseconds (default: `10000` = 10 seconds)
- All variables from `.env` file are automatically passed to the container

**Baked-in `ENV` (set in the Dockerfile, not via `.env`):**
- `MCP_TIMEOUT=10000`, `ENABLE_EXPERIMENTAL_MCP_CLI=1`, `ENABLE_LSP_TOOL=1`
- `OPENSPEC_TELEMETRY=0` (disables OpenSpec telemetry at build and runtime)
- `CODEGRAPH_NO_DOWNLOAD=1` (forbids CodeGraph's runtime binary download from GitHub Releases; binary must come from the npm registry)
- `NODE_ENV=production`, plus security limits (`RLIMIT_CORE=0`, `RLIMIT_NOFILE=1024`, `YAMA_PTRACE_SCOPE=1`)

**Pre-configured behavior** (`claude-config.json`, copied to `~/.claude.json`):
- Full permission bypass for `/workspace`: `dangerouslySkipPermissions`, `autoAcceptPermissions`,
  `defaultMode: acceptEdits`, all tools + `mcp__*` allowed
- `alwaysThinkingEnabled: true`, `autoUpdates: false`
- The `typescript-lsp@claude-plugins-official` plugin is enabled (works with `ENABLE_LSP_TOOL=1`)
- The OAuth account is hard-coded in this file — replace it if using a different account

**Note:** Input/output directories are configured via volume mounts, not environment variables

## Development Workflow

1. **Prepare input**: `run_claude.sh`/`debug-shell.sh` mount the **current directory**
   (`$(pwd)`) as read-only at `/workspace/input` — there is no input-dir argument in
   `run_claude.sh`; `debug-shell.sh` accepts an optional `[INPUT_DIR] [DATA_DIR]`.
2. **Run container**: `./run_claude.sh` (the entrypoint runs `claude --dangerously-skip-permissions`)
3. **Interactive development**: the container WORKDIR is `/workspace` (writable), and Claude
   starts there — not in `/workspace/input`. Source mounted at `/workspace/input` is read-only;
   write results to `/workspace/output` (host `./reports/`).
4. **Review output**: Check `./reports/` directory for generated files

## Pre-installed Tools

### Package Managers
- **pnpm** - Fast, disk space efficient package manager (Node.js)
- **npm** - Node.js package manager

### Development Tools
- **TypeScript** - TypeScript compiler and runtime (ts-node)
- **ESLint** - JavaScript/TypeScript linting
- **Prettier** - Code formatting
- **OpenSpec** - `@fission-ai/openspec` CLI for spec-driven development (`openspec` binary)
  - Installed globally via npm; requires Node.js >= 20.19.0 (satisfied by the `node:22-bookworm-slim` base)
  - Initialized into `/workspace` at build time via `openspec init /workspace --tools claude --force` (non-interactive: `--tools`/`--force` skip all prompts, default profile `core`)
  - Scaffolds `/workspace/openspec/` (`specs/`, `changes/`, `config.yaml`) and `/workspace/.claude/` (`commands/opsx/` + `skills/`: `openspec-propose`, `openspec-explore`, `openspec-apply-change`, `openspec-archive-change`)
  - Does NOT overwrite an existing `settings.local.json` or `CLAUDE.md` in the target
  - Telemetry is opt-out only via the `OPENSPEC_TELEMETRY=0` env var (no `telemetry.enabled` config key exists); set as baked-in ENV, covering build and runtime
  - **Note:** the user's mounted project lives in the read-only `/workspace/input`; the OpenSpec scaffold is in the writable WORKDIR `/workspace`, where Claude Code starts
  - Source: https://github.com/Fission-AI/OpenSpec
- **RTK** - Rust Token Killer; CLI proxy that filters/compresses command output to cut LLM token usage (`rtk` binary)
  - Static musl binary downloaded from GitHub releases into `/usr/local/bin`; pinned via `RTK_VERSION` build arg (default `v0.42.0`), no Rust toolchain needed
  - `rtk init -g --auto-patch` runs at build time (as the `claude` user): installs a **Claude Code PreToolUse hook** that transparently rewrites Bash commands (`git status` → `rtk git status`), writes `~/RTK.md`, and patches `~/.bashrc`
  - `-g` targets Claude Code (there is no `--agent claude`); `--auto-patch` makes init non-interactive
  - Runtime needs only the `rtk` binary in PATH + the hook; no daemon. Optional config at `~/.config/rtk/config.toml`
  - Source: https://github.com/rtk-ai/rtk
- **Caveman** - Output-compression skill for Claude Code (terse "caveman-speak"), reduces output tokens (~65%)
  - Installed at build time via `npx -y github:JuliusBrussee/caveman#v1.8.2 --non-interactive --only claude` (as the `claude` user; requires Node.js >= 18)
  - For the `claude` provider the installer uses the Claude Code **plugin mechanism** (`claude plugin marketplace add` + `claude plugin install caveman@caveman`) and wires hooks (by default it would also add a `caveman-shrink` MCP entry — suppressed here with `--no-mcp-shrink`, see below)
  - **Verified by build:** the `claude plugin marketplace add` + `claude plugin install` steps succeed during `docker build` — `marketplace add` is a public HTTPS git clone and `plugin install` is a local copy, so neither hits the Claude auth API (and `configure-claude.sh` has already written `~/.claude.json` by that layer). Skill + hooks are installed. Not made best-effort, so any future failure stays visible
  - Installed with **`--no-mcp-shrink`**: caveman's auto-registration wired `caveman-shrink` as a standalone MCP server with no upstream command, which always `✗ Failed to connect` (it is middleware, not a server). Instead `caveman-shrink` is pre-installed globally and applied as a wrapper around the codegraph MCP server (see CodeGraph / MCP Servers)
  - Source: https://github.com/JuliusBrussee/caveman
- **CodeGraph** - Pre-indexed code knowledge graph (symbols, call graph, impact) served to agents over MCP (`codegraph` binary)
  - Installed via `npm ci` from the locked toolchain (`@colbymchenry/codegraph@0.9.8`); also registered as the `codegraph` MCP server, wrapped by `caveman-shrink` to compress its (verbose) tool descriptions — verified `✓ Connected` (see "MCP Servers")
  - **Not pure JS:** the npm package is a thin shim; the real artifact is a per-platform optionalDependency (`@colbymchenry/codegraph-linux-x64`) bundling a vendored Node 24 runtime + prebuilt binary. `codegraph --help` at build time verifies the binary runs (**verified**: the vendored Node 24 binary runs on `node:22-bookworm-slim`)
  - `CODEGRAPH_NO_DOWNLOAD=1` (baked-in ENV) forbids the shim's runtime fallback that fetches the binary from GitHub Releases — the binary must come from the npm registry only
  - 100% local: local SQLite index (`.codegraph/codegraph.db`, FTS5), no API keys, no external services
  - See "CodeGraph indexing" for the index write-location constraint in this container
  - Source: https://github.com/colbymchenry/codegraph
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
- pre-installed MCP server binaries (`mcp-server-sequential-thinking`, `perplexity-mcp`, `codegraph`, `caveman-shrink`)
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
- Check MCP configuration: `cat ~/.claude.json | jq '.projects["/workspace"].mcpServers'`
- Verify the server's pre-installed bin is on PATH (e.g. `command -v mcp-server-sequential-thinking perplexity-mcp codegraph caveman-shrink`)
- Check MCP timeout setting: `echo $MCP_TIMEOUT` (default: 10000ms = 10 seconds; all servers are pre-installed so no download races this)
- Run diagnostics: `./run-diagnostics.sh` or inside container: `/app/diagnose-mcp.sh`
- View MCP installation logs: Rebuild with `./build.sh` and check the `install-mcp-servers.sh` output

## Files of Interest

- `Dockerfile` - Complete container build configuration
- `tools/package.json` - Pinned npm CLI toolchain (claude-code, openspec, codegraph, caveman-shrink, MCP servers, dev tools) — exact versions, single source of truth
- `tools/package-lock.json` - Lockfile (sha512 integrity) for the toolchain; installed via `npm ci`. Regenerate inside node:22 after editing package.json
- `claude-config.json` - Claude Code configuration with all permissions
- `settings.local.json` - Local Claude settings
- `mcp-servers.json` - Base MCP server configurations (always installed)
- `mcp-servers-optional.json` - Optional MCP servers (require API keys)
- `install-mcp-servers.sh` - MCP installation script with variable substitution
- `.env.example` - Example environment variables for MCP servers
- `.env` - Your local environment variables (create from .env.example)
- `.dockerignore` - Files excluded from Docker build context
- `run_claude.sh` - Main entry point for running Claude Code
- `debug-shell.sh` - Debug shell access
- `run-diagnostics.sh` - Automated MCP server diagnostics (NEW)
- `diagnose-mcp.sh` - Diagnostics script (runs inside container)
- `build.sh` / `build-nocache.sh` - Container build scripts
