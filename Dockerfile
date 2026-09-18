# ============================================================================
# One repository, three agent images.
#
#   docker build --target claude   -t claude-code-standalone:claude   .
#   docker build --target codex    -t claude-code-standalone:codex    .
#   docker build --target opencode -t claude-code-standalone:opencode .
#
# The `base` stage carries the whole shared toolchain (system deps, delta, RTK,
# codebase-memory-mcp, openspec, codegraph, the MCP server bins, dev tools) and
# NO agent CLI. Each agent stage adds only its own CLI and its own baked config,
# so the three images share one toolchain source of truth without shipping three
# agent binaries each.
# ============================================================================

FROM node:24-trixie-slim AS base

# Build arguments
ARG USER_ID=1001
ARG USER_NAME=claude
# npm CLI versions (openspec, codegraph, caveman-shrink, MCP servers, dev tools)
# are NOT build args — they are pinned in tools/package.json and locked in
# tools/package-lock.json (installed via `npm ci`). The agent CLIs live in
# tools/agents/<agent>/ and are installed by the matching stage below.
# RTK is a GitHub-release binary (not npm), so it keeps a version + sha256 arg.
ARG RTK_VERSION=v0.45.0
# codebase-memory-mcp is likewise installed from its GitHub release, NOT from its
# npm package: that package is a 12 kB shim whose postinstall downloads the real
# binary from GitHub Releases (outside npm's sha512 integrity), treats a missing
# checksums.txt as non-fatal, and whose bin.js re-downloads on first run if the
# binary is absent — i.e. an unverified runtime fetch. Pinned tag + sha256 here.
ARG CBM_VERSION=v0.10.8

# Create non-root user with specific UID/GID.
# Free the requested UID/GID if the base image already uses it (node:24 ships a
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
# Shared toolchain: all global npm CLIs EXCEPT the agent CLIs, via `npm ci`
# ============================================================================
# Single source of truth for npm versions: tools/package.json + the committed
# tools/package-lock.json (regenerate the lock INSIDE node:24 after any change —
# host-npm lockfileVersion can differ). `npm ci` installs the exact locked
# tarballs and verifies each sha512 integrity hash → bit-for-bit reproducible npm
# bytes, with nothing resolved at build time.
#
# Includes: @fission-ai/openspec, @colbymchenry/codegraph (+ its per-platform
# optionalDependency codegraph-linux-x64, a vendored Node 24 binary),
# caveman-shrink (MCP proxy), the stdio MCP servers
# (mcp-server-sequential-thinking, perplexity-mcp), and dev tools (pnpm,
# typescript, ts-node, prettier, eslint). Bins are exposed via PATH, not a global
# prefix — functionally identical for these CLIs (they read ~/.claude.json /
# ~/.claude / ~/.codex / ~/.config/opencode regardless of install location).
#
# CODEGRAPH_NO_DOWNLOAD=1 forbids codegraph's shim from fetching its binary from
# GitHub Releases at runtime; in this hardened image it must come from the locked
# npm tarball only.
ENV CODEGRAPH_NO_DOWNLOAD=1
COPY tools/package.json tools/package-lock.json /opt/toolchain/
RUN cd /opt/toolchain && \
    npm ci --no-audit --no-fund && \
    npm cache clean --force
ENV PATH="/opt/toolchain/node_modules/.bin:${PATH}"
# Verify the locked CLIs actually RUN on this base's Node (not just resolve on
# PATH) — a pinned version may declare a Node engine this base doesn't satisfy.
# codegraph uses `--help` (vendored Node 24 binary; `--version` is undocumented);
# caveman-shrink prints usage on no-args. ts-node is gated by transpling+running a
# typed snippet because `--version` never touches the TypeScript compiler API.
# MCP servers block on stdin without a client, so only their presence is checked;
# their startup is verified at runtime via `<agent> mcp list`.
RUN openspec --version && \
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
# MCP configuration (shared source, rendered per agent)
# ============================================================================
RUN mkdir -p /app
COPY mcp-servers.json mcp-servers-optional.json /app/
COPY render-mcp-configs.sh /app/
RUN chmod +x /app/render-mcp-configs.sh

# The single entrypoint script is agent-agnostic; each stage sets ENV AGENT.
COPY --chmod=0755 start-agent.sh /usr/local/bin/start-agent.sh

# Single read-write mode: the project is bind-mounted at /workspace/project at
# runtime (no separate input/output dirs). Just ensure the mount point exists and
# is world-writable (the runtime --user owns the bind-mounted project itself).
#
# Why one level down and not /workspace itself: codebase-memory-mcp refuses to
# index any first-level path as a root ("path is too broad to index as one root")
# since v0.10.0 — see src/foundation/workspace.{c,h} from upstream PR #1464, which
# rejects a candidate root less than two components below the volume. The refusal
# cannot be lifted: `allow-root /workspace` answers "refused", and
# --approve-sensitive does not apply. Mounting one level down keeps the project
# indexable while /workspace stays as the CBM_ALLOWED_ROOT boundary.
RUN mkdir -p /workspace/project && chmod 777 /workspace /workspace/project

# ============================================================================
# Bake shared state into the build HOME (/home/claude)
# ============================================================================
# At runtime the container starts with --user $(id -u):$(id -g) to match host
# ownership of the rw project mount, so HOME is relocated to a writable tmpfs
# (or a mounted login dir) and the entrypoint seeds this baked state into it.
# Done as the claude user so every baked file is owned by claude and the runtime
# user can copy/read it regardless of uid.
RUN mkdir -p /home/${USER_NAME}/.cache && chown -R ${USER_NAME}:${USER_NAME} /home/${USER_NAME}
USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# git-delta for better diffs (agent-agnostic).
RUN git config --global core.pager delta && \
    git config --global interactive.diffFilter "delta --color-only" && \
    git config --global delta.navigate true && \
    git config --global delta.light false && \
    git config --global delta.side-by-side true

# codebase-memory-mcp: turn OFF the built-in graph UI. Since v0.10.0 the binary
# ships an HTTP server for a 3D graph view and `ui_enabled` defaults to **true**,
# so the coordination daemon binds 127.0.0.1:9749 on the first MCP session —
# measured, contrary to the upstream README. A hardened image should not carry an
# undocumented listening socket (POST /api/index on it drives indexing). The
# setting is stored in $CBM_CACHE_DIR/_config.db under /home/claude/.cache, which
# the entrypoint seeds into the runtime HOME — so baking it here survives start.
RUN codebase-memory-mcp config set ui_enabled false && \
    codebase-memory-mcp config list

# Security: Set secure environment variables and limits
ENV DEBIAN_FRONTEND=noninteractive \
    NODE_ENV=production \
    NPM_CONFIG_AUDIT=false \
    NPM_CONFIG_FUND=false \
    RLIMIT_CORE=0 \
    RLIMIT_NOFILE=1024 \
    YAMA_PTRACE_SCOPE=1

# CBM_ALLOWED_ROOT confines codebase-memory-mcp's indexing to the project mount:
# an index_repository whose repo_path resolves outside this root is refused, and
# upstream applies the same check to the graph UI's POST /api/index route. Every
# entrypoint mounts the project at /workspace/project, so /workspace is correct.
# NOTE: CBM_CACHE_DIR stays unset on purpose — writing an index directory into the
# user's repo is not this container's business (see CLAUDE.md).
# OPENSPEC_TELEMETRY=0 disables OpenSpec telemetry at build and runtime.
ENV MCP_TIMEOUT=10000 \
    ENABLE_EXPERIMENTAL_MCP_CLI=1 \
    ENABLE_LSP_TOOL=1 \
    CBM_ALLOWED_ROOT=/workspace \
    OPENSPEC_TELEMETRY=0

# Add security labels (inherited by all three agent images)
LABEL security.non-root=true \
      security.hardened=true \
      security.version="1.0"

# ============================================================================
# claude — Claude Code only
# ============================================================================
FROM base AS claude
ARG USER_NAME=claude
USER root

# Claude Code CLI only, from its own locked package (see tools/agents/claude).
COPY tools/agents/claude/package.json tools/agents/claude/package-lock.json /opt/agent/
RUN cd /opt/agent && \
    npm ci --no-audit --no-fund && \
    npm cache clean --force
ENV PATH="/opt/agent/node_modules/.bin:${PATH}"
RUN claude --version

# Bake the Claude config into the build HOME. At runtime the entrypoint seeds it.
# COPY --chown creates the .claude dir owned by the user (a root `mkdir` here
# would leave it root-owned and break the later openspec/rtk init under USER claude).
COPY --chown=${USER_NAME}:${USER_NAME} claude-config.json /home/${USER_NAME}/.claude.json
COPY --chown=${USER_NAME}:${USER_NAME} settings.local.json /home/${USER_NAME}/.claude/settings.local.json
# User-level settings.json: permission defaultMode "auto" + advisorModel. MUST be
# user-home (~/.claude/settings.json) — Claude Code (v2.1.142+) ignores defaultMode
# "auto" from project-scope settings.
COPY --chown=${USER_NAME}:${USER_NAME} settings.json /home/${USER_NAME}/.claude/settings.json
# Statusline command (HOME-independent fixed path so settings statusLine works
# regardless of the runtime HOME relocation).
COPY --chmod=0755 statusline-command.sh /usr/local/bin/claude-statusline.sh

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# MCP servers, from the shared source into Claude's native format.
RUN cd /app && bash /app/render-mcp-configs.sh claude

# RTK: PreToolUse hook that transparently rewrites Bash commands through `rtk`.
# `-g` targets Claude Code; `--auto-patch` skips all prompts. Writes ~/.claude/RTK.md,
# adds an @RTK.md ref to ~/.claude/CLAUDE.md, registers the hook in settings.json,
# and patches ~/.bashrc.
RUN rtk init -g --auto-patch

# Caveman: output-compression skill for Claude Code, via the Claude Code plugin
# mechanism. Pinned to v1.9.1 (see CLAUDE.md for why v2.x is excluded).
# --no-mcp-shrink: do NOT let caveman auto-register the caveman-shrink MCP server
# (it is middleware, not a server; it is wrapped around codegraph in mcp-servers.json).
RUN npx -y github:JuliusBrussee/caveman#v1.9.1 --non-interactive --only claude --no-mcp-shrink

# OpenSpec: bake the Claude Code integration (opsx commands + skills) into HOME.
# The project mount is NOT initialized at build — it is overlaid at runtime.
RUN openspec init "/home/${USER_NAME}" --tools claude --force

# Make the baked HOME world-readable so the runtime --user (a different uid than
# the build user) can seed it into its writable/mounted HOME.
RUN chmod -R a+rX /home/${USER_NAME}

# Runaway-fan-out budgets for an unattended agent in a --pids-limit=100 container.
# Plain overrides of Claude Code defaults; pass a different value via `.env`
# (docker -e wins over image ENV). NOTE: 0 does NOT disable the per-session
# counters — use 1 for the tightest real limit.
ENV CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=12 \
    CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION=100 \
    CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION=100 \
    CLAUDE_CODE_RETRY_WATCHDOG=1 \
    AGENT=claude

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD test -f ~/.claude/settings.json || exit 1

ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/start-agent.sh"]

# ============================================================================
# codex — OpenAI Codex CLI only
# ============================================================================
FROM base AS codex
ARG USER_NAME=claude
USER root

# Codex CLI only, from its own locked package (see tools/agents/codex). The npm
# package is a thin launcher whose per-platform optionalDependency carries the
# binary; it declares no install scripts.
COPY tools/agents/codex/package.json tools/agents/codex/package-lock.json /opt/agent/
RUN cd /opt/agent && \
    npm ci --no-audit --no-fund && \
    npm cache clean --force
ENV PATH="/opt/agent/node_modules/.bin:${PATH}"
RUN codex --version

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# MCP servers, from the shared source into Codex's [mcp_servers.<id>] format.
# Also pins check_for_update_on_startup = false (supply chain: no runtime update).
RUN cd /app && bash /app/render-mcp-configs.sh codex

# RTK for Codex (v0.45.0 integration): writes $CODEX_HOME/AGENTS.md and RTK.md, so
# Codex prefixes commands with `rtk` itself. Non-interactive by construction and
# mutually exclusive with --auto-patch in this RTK version.
RUN rtk init -g --codex

# OpenSpec: bake the Codex integration. Codex is skills-only; OpenSpec writes
# ~/.agents/skills, one of the locations Codex scans at user scope.
RUN openspec init "/home/${USER_NAME}" --tools codex --force

RUN chmod -R a+rX /home/${USER_NAME}

ENV AGENT=codex

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD test -f ~/.codex/config.toml || exit 1

ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/start-agent.sh"]

# ============================================================================
# opencode — OpenCode CLI only
# ============================================================================
FROM base AS opencode
ARG USER_NAME=claude
USER root

# OpenCode CLI only, from its own locked package (see tools/agents/opencode).
# The postinstall links the platform binary from the optionalDependency; the
# package's runtime npm-install fallback never triggers because `npm ci` installs
# the optionalDependency from the lockfile.
COPY tools/agents/opencode/package.json tools/agents/opencode/package-lock.json /opt/agent/
RUN cd /opt/agent && \
    npm ci --no-audit --no-fund && \
    npm cache clean --force
ENV PATH="/opt/agent/node_modules/.bin:${PATH}"
RUN opencode --version

USER ${USER_NAME}
WORKDIR /home/${USER_NAME}

# MCP servers, from the shared source into OpenCode's { "mcp": { ... } } format.
# Also pins autoupdate: false (supply chain: no runtime update).
RUN cd /app && bash /app/render-mcp-configs.sh opencode

# RTK for OpenCode: installs the TypeScript plugin at ~/.config/opencode/plugins/rtk.ts
# (tool.execute.before hook) and requires no extra deps. Global-only.
RUN rtk init -g --opencode

# OpenSpec: OpenSpec's opencode adapter writes .opencode/{skills,commands} relative
# to the init dir, but OpenCode only reads skills/commands from ~/.config/opencode
# (and ~/.agents, ~/.claude) at user scope. Relocate them to the location OpenCode
# actually scans, then drop the unreachable .opencode copy.
RUN openspec init "/home/${USER_NAME}" --tools opencode --force && \
    mkdir -p "/home/${USER_NAME}/.config/opencode" && \
    if [ -d "/home/${USER_NAME}/.opencode/skills" ]; then cp -a "/home/${USER_NAME}/.opencode/skills" "/home/${USER_NAME}/.config/opencode/skills"; fi && \
    if [ -d "/home/${USER_NAME}/.opencode/commands" ]; then cp -a "/home/${USER_NAME}/.opencode/commands" "/home/${USER_NAME}/.config/opencode/commands"; fi && \
    rm -rf "/home/${USER_NAME}/.opencode"

RUN chmod -R a+rX /home/${USER_NAME}

# Supply chain: OpenCode can self-update and download LSP servers at runtime.
# Both are forbidden in this image; keep its world local and pinned.
ENV OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
    AGENT=opencode

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD test -f ~/.config/opencode/opencode.json || exit 1

ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/start-agent.sh"]