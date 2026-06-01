FROM node:22-trixie-slim

# Build arguments
ARG USER_ID=1001
ARG USER_NAME=claude
# npm CLI versions (claude-code, openspec, codegraph, caveman-shrink, MCP servers,
# dev tools) are NOT build args — they are pinned in tools/package.json and locked
# in tools/package-lock.json (installed via `npm ci`). Change versions there.
# RTK is a GitHub-release binary (not npm), so it keeps a version + sha256 arg.
ARG RTK_VERSION=v0.42.0

# Create non-root user with specific UID/GID
# Free the requested UID/GID if the base image already uses it (node:22 ships a
# `node` user at uid/gid 1000) so the image can be built with --build-arg
# USER_ID=$(id -u) for the read-write dev mode without a uid clash.
RUN if getent passwd ${USER_ID} >/dev/null 2>&1; then userdel -r "$(getent passwd ${USER_ID} | cut -d: -f1)" 2>/dev/null || true; fi && \
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
             RTK_SHA256="cdd4f87ac97ce958f71b53a991880d6adcc41cc5bca1044175a64630980152be";; \
      arm64) RTK_ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"; \
             RTK_SHA256="62bb749df1ed64f09149998c31de864932f047a1be4e0f882a8ceada849e0871";; \
      *) echo "unsupported TARGETARCH for RTK: $TARGETARCH" >&2; exit 1;; \
    esac && \
    curl -fsSL "https://github.com/rtk-ai/rtk/releases/download/${RTK_VERSION}/${RTK_ASSET}" -o /tmp/rtk.tar.gz && \
    echo "${RTK_SHA256}  /tmp/rtk.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/rtk.tar.gz -C /tmp && \
    mv /tmp/rtk /usr/local/bin/rtk && \
    chmod +x /usr/local/bin/rtk && \
    rm -f /tmp/rtk.tar.gz && \
    rtk --version

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

# Setup secure workspace with proper permissions
RUN mkdir -p /workspace/input \
    && mkdir -p /workspace/output \
    && mkdir -p /workspace/data \
    && mkdir -p /workspace/temp \
    && chown -R ${USER_NAME}:${USER_NAME} /workspace \
    && chmod 755 /workspace \
    && chmod 750 /workspace/input \
    && chmod 750 /workspace/data \
    && chmod 755 /workspace/output \
    && chmod 755 /workspace/temp


# Copy the working Claude config
COPY --chown=${USER_NAME}:${USER_NAME} claude-config.json /tmp/claude-config.json
COPY --chown=${USER_NAME}:${USER_NAME} settings.local.json /tmp/settings.local.json

# Setup Claude configuration (as root, will switch to claude user)
RUN echo '#!/bin/bash\n\
set -e\n\
echo "Setting up Claude configuration..."\n\
\n\
# Switch to claude user for configuration\n\
su - claude << "EOF_CLAUDE_USER"\n\
set -e\n\
cd /workspace\n\
\n\
# Copy the pre-configured Claude config\n\
cp /tmp/claude-config.json ~/.claude.json\n\
\n\
# Create .claude directory and copy settings.local.json\n\
mkdir -p ~/.claude\n\
cp /tmp/settings.local.json ~/.claude/settings.local.json\n\
mkdir -p /workspace/.claude\n\
cp /tmp/settings.local.json /workspace/.claude/settings.local.json\n\
\n\
echo "Claude configuration complete"\n\
ls -la ~/.claude.json\n\
ls -la ~/.claude/settings.local.json\n\
ls -la /workspace/.claude/settings.local.json\n\
\n\
EOF_CLAUDE_USER\n\
\n\
' > /usr/local/bin/configure-claude.sh \
    && chmod +x /usr/local/bin/configure-claude.sh \
    && /usr/local/bin/configure-claude.sh

# Switch to non-root user for security
USER ${USER_NAME}
WORKDIR /workspace

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
# Initialize OpenSpec in the workspace (runs as the claude user, in /workspace)
# ============================================================================
# Telemetry is opt-out only via the OPENSPEC_TELEMETRY env var (there is no
# `telemetry.enabled` config key). Setting it here disables telemetry for both
# this build-time init and runtime (security-hardened, isolated image).
# `init --tools claude --force` runs non-interactively (verified: no prompts with
# stdin closed) and scaffolds /workspace/openspec/ (specs, changes, config.yaml)
# plus /workspace/.claude/{commands/opsx,skills}/. It does NOT overwrite an
# existing settings.local.json or CLAUDE.md (verified).
ENV OPENSPEC_TELEMETRY=0
RUN openspec init /workspace --tools claude --force

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

# Caveman: output-compression skill for Claude Code. For the `claude` provider
# the installer uses the Claude Code plugin mechanism (`claude plugin marketplace
# add` + `claude plugin install caveman@caveman`) and also wires hooks.
# Pinned to tag v1.8.2 (non-interactive, claude only). NOTE: a commit-SHA ref
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
# Verified by build: both plugin steps succeed at build time — `marketplace add`
# is a public HTTPS clone and `plugin install` is a local copy (neither hits the
# auth API); caveman's SessionStart/UserPromptSubmit hooks merge into the same
# settings.json alongside RTK's PreToolUse hook. Not made best-effort so any
# future failure stays visible.
RUN npx -y github:JuliusBrussee/caveman#v1.8.2 --non-interactive --only claude --no-mcp-shrink

# Create simple startup script for runtime.
# --remote-control: start with Remote Control enabled by default (per project
#   requirement) so the in-container agent can be driven remotely.
# --dangerously-skip-permissions: the container boundary is the perimeter (see
#   SECURITY.md). NOTE: Remote Control opens an outbound control channel — covered
#   in the threat model.
RUN echo '#!/bin/bash\n\
set -e\n\
echo "Starting Claude Code (Remote Control enabled)..."\n\
exec claude --dangerously-skip-permissions --remote-control "$@"\n\
' > /home/${USER_NAME}/start-claude.sh \
    && chmod +x /home/${USER_NAME}/start-claude.sh

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

ENV MCP_TIMEOUT=10000 \
    ENABLE_EXPERIMENTAL_MCP_CLI=1 \
    ENABLE_LSP_TOOL=1

# Add security labels
LABEL security.non-root=true \
      security.hardened=true \
      security.version="1.0"

# Health check
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD test -f ~/.claude/settings.json || exit 1

# Security: Use dumb-init for proper signal handling and process reaping
ENTRYPOINT ["dumb-init", "--", "/home/claude/start-claude.sh"]
