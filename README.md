# claude-code-standalone

Security-hardened Docker container for running [Claude Code](https://docs.anthropic.com/claude-code)
in an isolated, least-privilege environment. Built on Node.js 22 LTS (Debian Trixie slim) with a
pinned, lockfile-controlled CLI toolchain and a curated set of MCP servers.

## Why

Running an autonomous coding agent with broad permissions directly on your host is risky.
This image confines Claude Code to a hardened container so that the **OS-level container boundary**
— not Claude's in-app permission prompts — is the security perimeter.

## Security model

The hardening is applied by the wrapper scripts (`run_claude.sh`, `debug-shell.sh`) at
`docker run` time:

- Runs as a non-root user (UID 1001); all Linux capabilities dropped (`--cap-drop=ALL`)
- No privilege escalation (`--security-opt=no-new-privileges:true`)
- Read-only source mount (`/workspace/input`); writable output only (`/workspace/output`)
- `--tmpfs` for `/tmp` and `/workspace/temp` with `noexec,nosuid`
- `--pids-limit=100` (anti fork-bomb)
- Bridge network only (no access to the host network)

Inside the sandbox, Claude Code runs with `--dangerously-skip-permissions` **by design** — the
container boundary is the perimeter. Consequently:

> ⚠️ **Run only via the provided wrapper scripts.** The image's own `ENTRYPOINT` is permissive;
> a bare `docker run claude-code-container` launches Claude Code **without** any of the hardening
> flags above. Do not run this image with relaxed Docker flags or sensitive read-write host mounts.

### Honest scope of "isolation"

- **Network:** bridge mode blocks access to the *host* network but allows **outbound internet**.
  The `context7` and `perplexity` MCP servers send data (including code context) to third-party
  services. There is no egress allowlist. Disable those MCP servers if this is unacceptable.
- **Resource limits:** core/file-descriptor limits are applied as `docker run --ulimit` flags in the
  wrapper scripts where present; verify they meet your needs. `ptrace` scoping (YAMA) depends on the
  host kernel and is not enforced by the image.
- **Third-party tools:** RTK installs a `PreToolUse` hook that rewrites every Bash command; CodeGraph
  ships a vendored prebuilt binary; caveman is installed as a Claude Code plugin. All are pinned, but
  represent third-party trust. Review them if your threat model requires it.

## What's inside

Toolchain pinned in `tools/package.json` and locked in `tools/package-lock.json` (installed via
`npm ci`, sha512-integrity verified):

- `@anthropic-ai/claude-code`, `@fission-ai/openspec`
- `@colbymchenry/codegraph` (code knowledge graph, MCP) wrapped by `caveman-shrink`
- MCP servers: `sequential-thinking`, `context7` (HTTP), `perplexity`
- Dev tools: `pnpm`, `typescript`, `ts-node`, `prettier`, `eslint`

GitHub-release binaries (sha256-pinned): `rtk` (Rust Token Killer), `git-delta`.
CLI utilities: `jq`, `ripgrep`, `fd`, `tree`, `fzf`, `mc`, `gnupg`.

See [CLAUDE.md](./CLAUDE.md) for the full architecture and per-component details.

## Requirements

- Docker
- A Claude Code OAuth token (`claude setup-token`)
- (optional) Context7 / Perplexity API keys for the corresponding MCP servers

## Setup

```bash
cp .env.example .env
# Fill in CLAUDE_CODE_OAUTH_TOKEN (required) and any optional keys.
# .env is gitignored and must never be committed.
```

## Container image (GHCR)

CI publishes a multi-arch image (linux/amd64 + linux/arm64) to GitHub Container Registry:

```bash
docker pull ghcr.io/highload-zone/claude-code-standalone:latest
```

- **Versioning is pinned by releases.** Pushing a git tag `vX.Y.Z` (i.e. a Release) publishes
  `:X.Y.Z`, `:X.Y`, `:X` tags. `main` publishes `:latest`; every build also gets `:sha-<short>`.
- Built with the built-in `GITHUB_TOKEN` (`packages: write`) — no extra secrets. Pull requests only
  build for verification and do **not** push.
- The GHCR package may be created **private** on first publish — make it public in the repo's
  *Packages* settings if you want anonymous `docker pull`.

## Build (locally)

```bash
./build.sh           # build image (npm versions come from the lockfile)
./build-nocache.sh   # clean build
```

To change a pinned tool version, edit `tools/package.json`, then regenerate the lockfile inside
Node 22:

```bash
docker run --rm -v "$PWD/tools:/w" -w /w node:22-trixie-slim npm install --package-lock-only
```

## Run — two modes

The container ships two complementary modes:

### Read-only mode (analysis / audit) — `run_claude.sh`

```bash
./run_claude.sh                 # interactive Claude Code in the container
./run_claude.sh --model opus    # pass-through Claude Code args
./debug-shell.sh                # bash shell inside the container
./run-diagnostics.sh            # MCP server diagnostics
```

Mounts the current directory **read-only** at `/workspace/input` and `./reports` read-write at
`/workspace/output`. Claude can read your code and write reports/patches to `./reports`, but cannot
modify the project or run git. Ideal for security review, code review, doc generation, and analyzing
**untrusted** code. The agent starts with Remote Control enabled (see SECURITY.md).

### Read-write dev mode (autonomous agent) — `run_claude_dev.sh`

```bash
./build-dev.sh                            # build the dev image under your uid (once)
export DEPLOY_KEY=/path/to/repo_deploy_key  # optional: scoped key to enable git push
cd /path/to/your/repo && /path/to/run_claude_dev.sh
```

Mounts the project **read-write** so Claude can edit, commit, and (with a scoped deploy key) push.
This is a **fully autonomous agent with elevated risk** — use only on **trusted projects**. Push
uses a scoped read-only-mounted deploy key (not ssh-agent forwarding), so the agent can push only to
that repo and cannot ssh elsewhere. Project git hooks are disabled inside the container. See the
"Dev mode" section in [SECURITY.md](./SECURITY.md) for the full threat model.

## Security disclosures

See [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)
