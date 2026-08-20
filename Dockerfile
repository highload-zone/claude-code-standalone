FROM node:22-trixie-slim

# Build arguments
ARG USER_ID=1001
ARG USER_NAME=claude
# npm CLI versions (claude-code, openspec, codegraph, caveman-shrink, MCP servers,
# dev tools) are NOT build args — they are pinned in tools/package.json and locked
# in tools/package-lock.json (installed via `npm ci`). Change versions there.
# RTK is a GitHub-release binary (not npm), so it keeps a version + sha256 arg.
ARG RTK_VERSION=v0.45.0
# codebase-memory-mcp is likewise installed from its GitHub release, NOT from its
# npm package: that package is a 12 kB shim whose postinstall downloads the real
# binary from GitHub Releases (outside npm's sha512 integrity), treats a missing
# checksums.txt as non-fatal, and whose bin.js re-downloads on first run if the
# binary is absent — i.e. an unverified runtime fetch. Pinned tag + sha256 here.
ARG CBM_VERSION=v0.10.8

# Create non-root user with specific UID/GID.
# Free the requested UID/GID if the base image already uses it (node:22 ships a
# `node` user at uid/gid 1000) so the image can be built with --build-arg
# USER_ID=$(id -u) for the read-write dev mode without a uid clash.
# ALSO remove the base `node` user (uid/gid 1000) unconditionally: the Dev
# Container uid-remap (updateRemoteUserUID) refuses to remap `claude` onto the
# host uid if that uid is already taken by another /etc/passwd entry. Since 1000
# is the most common host uid and `node` is unused here (everything runs as
# root-then-claude), leaving it would silently break devcontainer writes to the
# bind-mounted workspace on a uid-1000 host. Removing it frees 1000 for the remap.
RUN if id node >/dev/null 2>&1; then userdel -r node 2>/dev/null || true; fi && \
    if getent group node >/dev/null 2>&1; then groupdel node 2>/dev/null || true; fi && \
    if getent passwd ${USER_ID} >/dev/null 2>&1; then userdel -r "$(getent passwd ${USER_ID} | cut -d: -f1)" 2>/dev/null || true; fi && \
    if getent group ${USER_ID} >/dev/null 2>&1; then groupdel "$(getent group ${USER_ID} | cut -d: -f1)" 2>/dev/null || true; fi && \
    groupadd -g ${USER_ID} ${USER_NAME} && \
    useradd -m -u ${USER_ID} -g ${USER_ID} -s /bin/bash ${USER_NAME}

# Install system dependencies with security hardening
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget ca-certificates python3 python3-pip build-essential \
    # Security packages
    dumb-init \
    # Developer tools
    jq mc gnupg unzip fzf tree ripgrep fd-find \
    # Required for envsubst in MCP install script
    gettext-base \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/* \
    && rm -rf /var/tmp/* \
    # Remove unnecessary setuid binaries
    && find / -xdev -perm -4000 -type f -exec chmod u-s {} \; 2>/dev/null || true \
    && find / -xdev -perm -2000 -type f -exec chmod g-s {} \; 2>/dev/null || true \
    # Remove network tools that could be used for reconnaissance (but keep essential shells)
    && rm -f /usr/bin/nc /usr/bin/netcat /bin/netstat /usr/bin/ss || true

# TARGETARCH is provided automatically by BuildKit/buildx (amd64 | arm64). Used to
# select per-architecture GitHub-release binaries for multi-arch builds.
ARG TARGETARCH

# Install git-delta from GitHub releases (per-arch, sha256-pinned). The .deb suffix
# matches TARGETARCH directly (amd64 / arm64).
RUN DELTA_VERSION="0.19.2" && \
    case "$TARGETARCH" in \
      amd64) DELTA_SHA256="ea4f0222950ee750a3d38dd80d03bce4cee07a3f63928fc47548383bcaf23093";; \
      arm64) DELTA_SHA256="0edc36cf514f1bd84becac3e94ee8ae9f8818c6a1f99f7b2ee67b362afa253d3";; \
      *) echo "unsupported TARGETARCH for git-delta: $TARGETARCH" >&2; exit 1;; \
    esac && \
    curl -fsSL "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_${TARGETARCH}.deb" -o /tmp/git-delta.deb && \
    echo "${DELTA_SHA256}  /tmp/git-delta.deb" | sha256sum -c - && \
    dpkg -i /tmp/git-delta.deb && \
    rm /tmp/git-delta.deb

# Install RTK (Rust Token Killer) from GitHub releases — per-arch, sha256-pinned.
# RTK ships only two Linux targets: x86_64 (musl) and aarch64 (gnu); other Linux
# archs are not available. If you bump RTK_VERSION you MUST refresh both sha256
# values (the checksum verification fails otherwise — by design). Each archive
# contains a single binary `rtk` placed in /usr/local/bin.
RUN case "$TARGETARCH" in \
      amd64) RTK_ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"; \
             RTK_SHA256="c4c036fbf181fc55ef329786c8c17e0d427972b053b825944d968a6aafef1ba4";; \
      arm64) RTK_ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"; \
             RTK_SHA256="80a746dd305ef944ff50ef011ae4ce3878dd5ba88dfe35d859d05498191637c3";; \
      *) echo "unsupported TARGETARCH for RTK: $TARGETARCH" >&2; exit 1;; \
    esac && \
    curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${RTK_ASSET}" -o /tmp/rtk.tar.gz && \
    echo "${RTK_SHA256}  /tmp/rtk.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/rtk.tar.gz -C /tmp && \
    mv /tmp/rtk /usr/local/bin/rtk && \
    chmod +x /usr/local/bin/rtk && \
    rm -f /tmp/rtk.tar.gz && \
    rtk --version

# Install codebase-memory-mcp from GitHub releases — per-arch, sha256-pinned.
# The `-portable` Linux asset is the fully-static build; the plain `linux-*` one
# dynamically links glibc >= 2.38 (trixie has 2.41, so both would work — static is
# taken for the same reason RTK amd64 uses musl: no libc coupling). If you bump
# CBM_VERSION you MUST refresh both sha256 values (checked against the release's
# own checksums.txt AND against the downloaded bytes). The archive contains the
# binary at its root plus LICENSE/THIRD_PARTY_NOTICES/install.sh — only the binary
# is kept. NOTE: it is ~258 MB (159 vendored tree-sitter grammars + a vendored
# embedding model), which dominates this layer's size.
RUN case "$TARGETARCH" in \
      amd64) CBM_ASSET="codebase-memory-mcp-linux-amd64-portable.tar.gz"; \
             CBM_SHA256="6eef49652bc0c7820f43114125044d40bf7f4d97c11b2592f6b0f6a307702325";; \
      arm64) CBM_ASSET="codebase-memory-mcp-linux-arm64-portable.tar.gz"; \
             CBM_SHA256="5697d986d9716c913163b4bff7b3a294287f3b843e993bc1ff71e78dcdc21781";; \
      *) echo "unsupported TARGETARCH for codebase-memory-mcp: $TARGETARCH" >&2; exit 1;; \
    esac && \
    curl -fsSL "https://github.com/DeusData/codebase-memory-mcp/releases/download/${CBM_VERSION}/${CBM_ASSET}" -o /tmp/cbm.tar.gz && \
    echo "${CBM_SHA256}  /tmp/cbm.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/cbm.tar.gz -C /tmp codebase-memory-mcp && \
    mv /tmp/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp && \
    chmod +x /usr/local/bin/codebase-memory-mcp && \
    rm -f /tmp/cbm.tar.gz && \
    codebase-memory-mcp --version

# ============================================================================
# Toolchain: ALL global npm CLIs, locked + integrity-verified via `npm ci`
# ============================================================================
# Single source of truth for npm versions: tools/package.json + the committed
# tools/package-lock.json (regenerate the lock INSIDE node:22 after any change —
# host-npm lockfileVersion can differ). `npm ci` installs the exact locked
# tarballs and verifies each sha512 integrity hash → bit-for-bit reproducible npm
# bytes, with nothing resolved at build time (this replaces the old per-package
# `npm install -g @latest`, whose transitive deps floated per build).
#
# Includes: @anthropic-ai/claude-code, @fission-ai/openspec, @colbymchenry/codegraph
# (+ its per-platform optionalDependency codegraph-linux-x64, a vendored Node 24
# binary), caveman-shrink (MCP proxy), the stdio MCP servers
# (mcp-server-sequential-thinking, perplexity-mcp), and dev tools (pnpm, typescript,
# ts-node, prettier, eslint). Bins are exposed via PATH, not a global prefix —
# functionally identical for these CLIs (they read ~/.claude.json / ~/.claude
# regardless of install location).
#
# CODEGRAPH_NO_DOWNLOAD=1 forbids codegraph's shim from fetching its binary from
# GitHub Releases at runtime; in this hardened image it must come from the locked
# npm tarball only. (Residual boundary: `npm ci` pins tarball bytes but does NOT
# neutralize postinstall network fetchers in transitive deps — codegraph's, the
# known one, is disabled here; others, if any, are a separate boundary.)
ENV CODEGRAPH_NO_DOWNLOAD=1
COPY tools/package.json tools/package-lock.json /opt/toolchain/
RUN cd /opt/toolchain && \
    npm ci --no-audit --no-fund && \
    npm cache clean --force
ENV PATH="/opt/toolchain/node_modules/.bin:${PATH}"
# Verify the locked CLIs actually RUN on this base's Node (not just resolve on
# PATH) — a pinned version may declare a Node engine this base doesn't satisfy
# (e.g. pnpm 11 needs Node >=22.13; the base is node:22 which satisfies it). Running each `--version`
# (or `--help`) catches that at build time. codegraph uses `--help` (vendored Node
# 24 binary; `--version` is undocumented); caveman-shrink prints usage on no-args.
# dev tools: run `--version` (this is what catches an incompatible Node engine).
# ts-node is the exception: `--version` only prints a constant and never touches
# the TypeScript compiler API, so it stays green even when ts-node is completely
# broken against the pinned `typescript` (observed with typescript 7.x, whose
# native rewrite drops the JS API ts-node needs: `ts.sys` is undefined). It is
# therefore gated by actually transpiling+running a typed snippet. `--compiler-options
# module=commonjs` is required: with no tsconfig in scope the `-e` REPL emits an ESM
# `export {}` that its own `vm.Script` (CJS) cannot parse.
# MCP servers (mcp-server-sequential-thinking, perplexity-mcp) are stdio servers
# that block on stdin if launched without a client — they CANNOT be run here
# without hanging the build, so only check presence; their actual startup is
# verified at runtime via `claude mcp list`.
RUN claude --version && \
    openspec --version && \
    codegraph --help > /dev/null && \
    caveman-shrink 2>&1 | grep -q "upstream" && \
    pnpm --version > /dev/null && \
    tsc --version > /dev/null && \
    prettier --version > /dev/null && \
    eslint --version > /dev/null && \
    ts-node --version > /dev/null && \
    ts-node --compiler-options '{"module":"commonjs"}' -e 'const n: number = 1; if (n !== 1) process.exit(1)' && \
    command -v mcp-server-sequential-thinking perplexity-mcp > /dev/null

# ============================================================================
# MCP Servers Cache Layer
# ============================================================================
# Copy MCP server configuration files early for Docker layer caching
# These files change less frequently than the rest of the setup
RUN mkdir -p /app
COPY mcp-servers.json /app/
COPY mcp-servers-optional.json /app/
COPY install-mcp-servers.sh /app/
COPY diagnose-mcp.sh /app/
RUN chmod +x /app/install-mcp-servers.sh /app/diagnose-mcp.sh

################# <--- Configure MCP Providers

# Single read-write mode: the project is bind-mounted at /workspace/project at
# runtime (no separate input/output dirs). Just ensure the mount point exists and
# is world-writable (the runtime --user owns the bind-mounted project itself).
#
# Why one level down and not /workspace itself: codebase-memory-mcp refuses to
# index any first-level path as a root ("path is too broad to index as one root")
# since v0.10.0 — see src/foundation/workspace.{c,h} from upstream PR #1464, which
# rejects a candidate root less than two components below the volume. The refusal
# cannot be lifted: `allow-root /workspace` answers "refused", and
# --approve-sensitive does not apply to it. Mounting one level down keeps the
# project indexable while /workspace stays as the CBM_ALLOWED_ROOT boundary.
RUN mkdir -p /workspace/project && chmod 777 /workspace /workspace/project

# Bake the Claude config into the build user's HOME (/home/claude). At runtime the
# container is started with --user $(id -u):$(id -g) to match host file ownership
# for the rw project mount, so HOME is relocated to a writable tmpfs and the
# entrypoint copies this baked state into it (/home/claude is made world-readable
# after all agent init below). The config/state baked here: claude-config,
# settings, plus RTK hook + caveman plugin added by later layers.
COPY --chown=${USER_NAME}:${USER_NAME} claude-config.json /home/${USER_NAME}/.claude.json
# COPY --chown creates the .claude dir owned by the user (a root `mkdir` here would
# leave it root-owned and break the later openspec/rtk init under USER claude).
COPY --chown=${USER_NAME}:${USER_NAME} settings.local.json /home/${USER_NAME}/.claude/settings.local.json
# User-level settings.json: permission defaultMode "auto" + advisorModel. MUST be
# user-home (~/.claude/settings.json) — Claude Code (v2.1.142+) ignores defaultMode
# "auto" from project-scope settings, so this never goes to /workspace/.claude.
COPY --chown=${USER_NAME}:${USER_NAME} settings.json /home/${USER_NAME}/.claude/settings.json
# Statusline command for Claude Code (compact line: dir, git, model, context, rate
# limits). Installed at a fixed, HOME-independent path so settings.local.json's
# statusLine.command works regardless of the runtime HOME relocation. Deps (jq, git,
# awk, date, grep) are all present in the image.
COPY --chmod=0755 statusline-command.sh /usr/local/bin/claude-statusline.sh

# Switch to non-root user for the agent-init layers (git config, RTK, caveman).
USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# ============================================================================
# Install MCP Servers
# ============================================================================
RUN cd /app && bash /app/install-mcp-servers.sh

# Configure git to use delta for better diffs
RUN git config --global core.pager delta && \
    git config --global interactive.diffFilter "delta --color-only" && \
    git config --global delta.navigate true && \
    git config --global delta.light false && \
    git config --global delta.side-by-side true

# ============================================================================
# Initialize OpenSpec into the build HOME (NOT the project mount — that is
# overlaid at runtime). This bakes the Claude Code integration
# (~/.claude/commands/opsx + skills) which the entrypoint copies into the runtime
# HOME, so the opsx slash-commands are available. `openspec init` in an actual
# project is still run on demand by the agent inside the rw /workspace/project.
# Telemetry opt-out via OPENSPEC_TELEMETRY (no telemetry.enabled config key).
ENV OPENSPEC_TELEMETRY=0
RUN openspec init "/home/${USER_NAME}" --tools claude --force

# ============================================================================
# Agent tooling: RTK init + Caveman (runs as the claude user)
# ============================================================================
# RTK: install the Claude Code PreToolUse hook that transparently rewrites Bash
# commands through `rtk` for token savings. `-g` targets Claude Code (no
# --agent claude flag exists); `--auto-patch` skips all prompts (non-interactive).
# This writes ~/.claude/RTK.md, adds an @RTK.md ref to ~/.claude/CLAUDE.md, and
# registers the hook (matcher Bash → `rtk hook claude`) in ~/.claude/settings.json.
# Verified by build+run: `rtk 0.42.0` runs; the PreToolUse/Bash hook is present
# and is NOT clobbered by the caveman layer that writes the same settings.json.
RUN rtk init -g --auto-patch

# codebase-memory-mcp: turn OFF the built-in graph UI. Since v0.10.0 the binary
# ships an HTTP server for a 3D graph view and `ui_enabled` defaults to **true**,
# so the coordination daemon binds 127.0.0.1:9749 on the first MCP session —
# measured, and contrary to the upstream README, which documents the UI as needing
# an explicit `--ui=true --port=9749`. A hardened image should not carry an
# undocumented listening socket, the less so because POST /api/index on it drives
# indexing. The setting is stored in $CBM_CACHE_DIR/_config.db, i.e. under
# /home/claude/.cache, which the entrypoint copies into the runtime tmpfs HOME —
# so baking it here survives container start.
RUN codebase-memory-mcp config set ui_enabled false && \
    codebase-memory-mcp config list

# Caveman: output-compression skill for Claude Code. For the `claude` provider
# the installer uses the Claude Code plugin mechanism (`claude plugin marketplace
# add` + `claude plugin install caveman@caveman`) and also wires hooks.
# Pinned to tag v1.9.1 (non-interactive, claude only). NOTE: a commit-SHA ref
# (`#a025122…`) would be more immutable, but `npx github:…#<40-char-sha>` fails
# with "GitFetcher requires an Arborist constructor to pack a tarball" (npm git
# fetcher limitation) — the tag ref is what actually installs. The tag's mutability
# is moot anyway: the marketplace-HEAD clone below is the real determinism residual.
# --no-mcp-shrink: do NOT let caveman auto-register the caveman-shrink MCP server.
# Its registration wires `npx -y caveman-shrink` with NO upstream command, which
# always fails to connect (caveman-shrink is middleware, not a standalone server).
# Instead caveman-shrink is pre-installed globally above and applied as a wrapper
# around the codegraph MCP server in mcp-servers.json.
#
# DETERMINISM CAVEAT (documented residual, NOT bit-for-bit): the installer hardcodes
# `claude plugin marketplace add JuliusBrussee/caveman` (REPO in bin/install.js),
# which clones the repo's DEFAULT-BRANCH HEAD (mutable) — so the installed skill
# content is not frozen across rebuilds even though the installer ref is. Closing
# this fully would require forking/mirroring the caveman repo at a pinned commit
# (its installer cannot be pointed at a local/pinned marketplace). caveman does NOT
# fetch anything at runtime (skill + hooks are baked into the image), so this is a
# build-reproducibility gap, not a runtime supply-chain hole.
#
# Verified by build+run: both plugin steps succeed at build time — `marketplace add`
# is a public HTTPS clone and `plugin install` is a local copy (neither hits the
# auth API). The hooks come from the PLUGIN MANIFEST, not from settings.json:
# measured in the built image, `.hooks.SessionStart` and `.hooks.UserPromptSubmit`
# are empty and `.hooks.PreToolUse` holds only RTK's `rtk hook claude` — i.e. the
# caveman layer does not clobber RTK's hook, and `.statusLine` survives too. Not
# made best-effort so any future failure stays visible.
#
# HELD AT v1.9.1 — do NOT bump to v2.x without re-doing this analysis. Measured
# against v2.2.0:
#   - v2.2.0 adds a runtime dependency `@caveman-ai/cli: ^1.1.0`, which ships its
#     own `caveman` bin. That bin SHADOWS the installer's own `caveman` bin under
#     npx, so `npx -y github:JuliusBrussee/caveman#v2.2.0 --non-interactive …`
#     does not run bin/install.js at all — it runs the cloud CLI, which answers
#     `unknown command "--non-interactive"`. The installer script itself is
#     unchanged and still accepts the flags; it is simply unreachable this way.
#   - that dependency is a FLOATING range (`^1.1.0`) in a build layer, which this
#     image's exact-pin policy does not accept, and `@caveman-ai/cli` is an
#     account/cloud CLI whose compression runs in "companion Go binaries" fetched
#     by `caveman setup` — a runtime download this image forbids.
# v1.9.1 has no dependencies at all, which is why it stays.
RUN npx -y github:JuliusBrussee/caveman#v1.9.1 --non-interactive --only claude --no-mcp-shrink

# Create simple startup script for runtime.
# Permission mode: default is `auto` (set in ~/.claude/settings.json) — autonomous
#   with a background classifier, NOT the old `--dangerously-skip-permissions`
#   bypass. Auto mode engages only on the Anthropic API with a supported model; if
#   unavailable it silently falls back to `default` (prompts). See SECURITY.md.
# --dangerously-skip-permissions: OPT-IN via CLAUDE_BYPASS_PERMISSIONS=1 (off by
#   default). Re-adds the full bypass for isolated/throwaway containers where you
#   accept no in-app safety checks. The flag is added only when the env var is set,
#   so it is never a dead default.
# --remote-control: ON BY DEFAULT (every session); opt out with
#   CLAUDE_REMOTE_CONTROL=0. IMPORTANT — this flag only takes effect with a
#   full-scope login token obtained by `claude auth login` INSIDE the container.
#   The long-lived CLAUDE_CODE_OAUTH_TOKEN / `claude setup-token` this image
#   normally runs with is inference-only, and `claude doctor` states it verbatim:
#     "Remote Control requires a full-scope login token. Long-lived tokens (from
#      claude setup-token or CLAUDE_CODE_OAUTH_TOKEN) are limited to
#      inference-only for security reasons."
#   So the flag is passed but inert under that auth. To avoid a silent dead knob
#   the entrypoint says so at startup whenever CLAUDE_CODE_OAUTH_TOKEN is set.
#   There is NO settings.json key that enables RC (only `disableRemoteControl`
#   to turn it off), so the CLI flag is the only way to default it on.
# --remote-control-session-name-prefix: RC session names default to the
#   HOSTNAME, which in a container is a throwaway hex id. The prefix is taken
#   from CLAUDE_REMOTE_CONTROL_PREFIX (the launchers pass the host project
#   directory name) and falls back to `claude-box`.
RUN echo '#!/bin/bash\n\
set -e\n\
# Runtime starts with --user $(id -u):$(id -g) to match host ownership of the rw\n\
# project mount. The baked agent state lives in /home/claude (built under a\n\
# different uid, world-readable); copy it into this user'"'"'s writable HOME once.\n\
export HOME="${HOME:-/home/agent}"\n\
if [ "$HOME" != "/home/claude" ] && [ ! -e "$HOME/.claude.json" ]; then\n\
  mkdir -p "$HOME"\n\
  cp -a /home/claude/. "$HOME/" 2>/dev/null || true\n\
fi\n\
# Merge host-provided resources mounted by the launcher at /host-claude/<name>\n\
# OVER the baked state. Unconditional and AFTER the baked copy (so a resumed HOME\n\
# still receives them). Host files win on name collision; baked-only files such as\n\
# commands/opsx and the openspec skills survive because cp merges, not replaces.\n\
for d in agents commands skills; do\n\
  if [ -d "/host-claude/$d" ]; then\n\
    mkdir -p "$HOME/.claude/$d"\n\
    cp -a "/host-claude/$d/." "$HOME/.claude/$d/" 2>/dev/null || true\n\
  fi\n\
done\n\
cd /workspace/project 2>/dev/null || cd "$HOME"\n\
EXTRA_ARGS=""\n\
mode_msg="permission mode: auto (default; falls back to default mode if auto is unavailable)"\n\
if [ "${CLAUDE_BYPASS_PERMISSIONS:-0}" = "1" ]; then\n\
  EXTRA_ARGS="$EXTRA_ARGS --dangerously-skip-permissions"\n\
  mode_msg="permission mode: bypass (CLAUDE_BYPASS_PERMISSIONS=1 — no in-app safety checks)"\n\
fi\n\
if [ "${CLAUDE_REMOTE_CONTROL:-1}" != "0" ]; then\n\
  # Session names are auto-generated as <prefix>-<random-words>; the CLI default\n\
  # prefix is the hostname, useless in a container. Keep the prefix to characters\n\
  # that are safe in a session name.\n\
  rc_prefix="$(printf %s "${CLAUDE_REMOTE_CONTROL_PREFIX:-claude-box}" | tr -c "[:alnum:]._-" "-" | cut -c1-40)"\n\
  [ -z "$rc_prefix" ] && rc_prefix="claude-box"\n\
  EXTRA_ARGS="$EXTRA_ARGS --remote-control --remote-control-session-name-prefix $rc_prefix"\n\
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then\n\
    mode_msg="$mode_msg; Remote Control requested (prefix: $rc_prefix) but INACTIVE — CLAUDE_CODE_OAUTH_TOKEN is inference-only. Run '"'"'claude auth login'"'"' in this container to use it, or set CLAUDE_REMOTE_CONTROL=0 to stop asking"\n\
  else\n\
    mode_msg="$mode_msg; Remote Control on (prefix: $rc_prefix)"\n\
  fi\n\
fi\n\
echo "Starting Claude Code in $(pwd) — $mode_msg..."\n\
exec claude $EXTRA_ARGS "$@"\n\
' > /home/${USER_NAME}/start-claude.sh \
    && chmod +x /home/${USER_NAME}/start-claude.sh

# Make the baked HOME world-readable so the runtime --user (a different uid than
# the build user) can copy it into its writable HOME (see start-claude.sh).
RUN chmod -R a+rX /home/${USER_NAME}

# Security: Set secure environment variables and limits
ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    # Prevent core dumps
    RLIMIT_CORE=0 \
    # Limit file descriptors
    RLIMIT_NOFILE=1024 \
    # Prevent ptrace (debugging other processes)
    YAMA_PTRACE_SCOPE=1

# CBM_ALLOWED_ROOT confines codebase-memory-mcp's indexing to the project mount:
# an index_repository whose repo_path resolves (after symlink / `..` resolution)
# outside this root is refused, and upstream applies the same check to the graph
# UI's POST /api/index route. Every entrypoint mounts the project at
# /workspace/project (run_claude.sh, debug-shell.sh, the claude-box launcher from
# install.sh, and the Dev Container), so /workspace is the correct boundary.
# NOTE: CBM_CACHE_DIR stays unset on purpose — writing an index directory into the
# user's repo is not this container's business (see CLAUDE.md).
ENV MCP_TIMEOUT=10000 \
    ENABLE_EXPERIMENTAL_MCP_CLI=1 \
    ENABLE_LSP_TOOL=1 \
    CBM_ALLOWED_ROOT=/workspace

# Runaway-fan-out budgets for an unattended agent in a --pids-limit=100 container.
# All four are plain overrides of Claude Code defaults; pass a different value via
# `.env` (docker -e wins over image ENV) to change them per run.
#
# CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS (upstream default 20) -> 12. Measured inside
#   this image: 4 processes before `claude`, ~11 with `claude` + the four MCP servers
#   attached, peaking at 15 with three parallel Bash tool calls — i.e. roughly 1-2 PIDs
#   per in-flight tool call on top of an ~11-PID floor. At the upstream 20 a fan-out
#   where every subagent holds a shell (plus pipelines) lands close enough to the
#   100-PID cgroup limit that the container, not Claude Code, decides what fails. 12
#   keeps ~40 PIDs of headroom.
# CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION / _MAX_WEB_SEARCHES_PER_SESSION (default 200
#   each) -> 100. Session-wide runaway-loop stops; these are cost/loop guards, not PID
#   guards, so the number is a deliberately conservative choice rather than a measured
#   ceiling. NOTE: 0 does NOT disable them — observed: with either counter set to 0 the
#   action still ran, i.e. 0 behaves as if the variable were unset. Use 1 for the tightest
#   real limit.
# CLAUDE_CODE_RETRY_WATCHDOG=1 — boolean env (the parser accepts 1/true/yes/on).
#   Upstream now caps CLAUDE_CODE_MAX_RETRIES at 15 and points unattended sessions at
#   the watchdog instead; this image is exactly that unattended case.
ENV CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=12 \
    CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION=100 \
    CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION=100 \
    CLAUDE_CODE_RETRY_WATCHDOG=1

# Add security labels
LABEL security.non-root=true \
      security.hardened=true \
      security.version="1.0"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD test -f ~/.claude/settings.json || exit 1

# Security: Use dumb-init for proper signal handling and process reaping
ENTRYPOINT ["dumb-init", "--", "/home/claude/start-claude.sh"]
