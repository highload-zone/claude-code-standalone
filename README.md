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

## Build

```bash
./build.sh           # build image (npm versions come from the lockfile)
./build-nocache.sh   # clean build
```

To change a pinned tool version, edit `tools/package.json`, then regenerate the lockfile inside
Node 22:

```bash
docker run --rm -v "$PWD/tools:/w" -w /w node:22-trixie-slim npm install --package-lock-only
```

## Run

```bash
./run_claude.sh                 # interactive Claude Code in the container
./run_claude.sh --model opus    # pass-through Claude Code args
./debug-shell.sh                # bash shell inside the container
./run-diagnostics.sh            # MCP server diagnostics
```

`run_claude.sh` mounts the current directory read-only at `/workspace/input` and `./reports`
read-write at `/workspace/output`.

## Security disclosures

See [SECURITY.md](./SECURITY.md).

## License

[MIT](./LICENSE)
