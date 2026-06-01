# Security Policy

## Reporting a vulnerability

If you discover a security issue in this project, please report it **privately**.

**Do not open a public GitHub issue for security problems.**

Use GitHub's private vulnerability reporting (**Security → Report a vulnerability** in this
repository), or contact the maintainers directly.

Please include:

- A description of the issue and its impact
- Steps to reproduce
- Affected version / commit
- Any suggested mitigation

We aim to acknowledge reports within a few business days.

## Scope

This repository ships a Docker image that runs Claude Code under a hardened container profile.
Security boundaries (enforced by the wrapper scripts at `docker run` time):

- Non-root execution (UID 1001), all capabilities dropped, no privilege escalation
- Read-only source mounts, non-executable temp filesystems, PID limits
- Bridge-only networking (no host-network access)

**In scope:** the container hardening, build supply-chain pinning, and secret handling of this
repository.

**Out of scope:**

- The security of Claude Code itself (report upstream to Anthropic)
- Vulnerabilities in third-party MCP servers, RTK, CodeGraph, caveman, or npm dependencies
  (report upstream to their maintainers)

## Threat model (host assumptions)

This image is expected to run on a host where the **Docker daemon runs as root** and the operator
may be root. Consequently:

- **On a root-Docker host, `docker run` is equivalent to host root.** The wrapper scripts
  (`run_claude.sh`, `run_claude_dev.sh`, `debug-shell.sh`) are **NOT a security boundary against a
  hostile operator** — anyone who can run Docker can ignore them and mount `/`, add capabilities,
  or pass `--privileged`. The scripts' guard checks (refusing `--privileged`, `--pid=host`,
  `docker.sock`, uid 0, etc.) only catch **accidental misconfiguration**, not a deliberate operator.
- **Required invariants for the hardening to hold** (operator's responsibility): never mount
  `/var/run/docker.sock`, never use `--privileged` / `--cap-add` / `--pid=host` / `--network=host`,
  never `--user root`, never mount sensitive host paths. The provided scripts already satisfy these.
- **Residual escape vectors not addressed by the image:** kernel LPE from an unprivileged container
  (mitigate by patching the host kernel) and operator bypass (out of the image's control).

## Known limitations (by design)

- **The image ENTRYPOINT is permissive** (`--dangerously-skip-permissions --remote-control`). The
  container boundary is the perimeter; in-app permission prompts are disabled. A bare `docker run`
  without a wrapper still has no host-level hardening. Always use the wrapper scripts.
- **Remote Control opens an outbound control channel.** The entrypoint enables `--remote-control` by
  default; this is an outbound connection to the Remote Control service. Disable it (override the
  entrypoint / command) if your environment forbids that channel.
- **Outbound network is allowed.** Bridge networking blocks the host network but not the internet.
  `context7` and `perplexity` MCP servers transmit data (including code context) to third parties.
  On a root host this is an exfiltration channel under prompt injection — restrict egress at the
  Docker-network/daemon level (cap-drop=ALL prevents in-container iptables) or remove those MCP
  servers from `mcp-servers.json`.
- **Prompt injection.** With `--dangerously-skip-permissions`, any analyzed file is executable
  instructions for the autonomous agent. In read-only mode the blast radius is bounded by the ro
  mount + cap-drop, but egress can still exfiltrate read code. **In dev mode it is not bounded** —
  see below.
- **Third-party trust.** RTK's `PreToolUse` hook rewrites every Bash command (compromise = injection
  into every shell call); CodeGraph ships an opaque vendored binary. Both are version/checksum
  pinned, but auditing them is the operator's responsibility.

## Dev mode (`run_claude_dev.sh`) — elevated risk

The read-write dev mode mounts the project `rw`, runs the agent autonomously, and (optionally) gives
it a scoped git push credential. **Residual risk is Medium** with a scoped deploy key (the default
recommendation), and **High** if you substitute ssh-agent forwarding (a forwarded agent can
authenticate to *any* SSH host, not just `git push` — enabling pivot beyond the repo). Guardrails
built into dev mode:

- **Scoped deploy key** (read-only mounted, `IdentitiesOnly=yes`) instead of agent forwarding — the
  agent can push only to that one repo and cannot ssh elsewhere. Set via `DEPLOY_KEY=/path/to/key`.
- **Project git hooks are disabled** in the container (`core.hooksPath=/dev/null`) so an injected
  `.git/hooks` script does not execute on git operations.
- **Footgun guards** (refuse `--privileged`/`docker.sock`/uid 0) as above.

Use dev mode only on **trusted projects**. Even with the deploy key, a prompt-injected agent can
modify project files / CI configs (rw) and push to the scoped repo — review what it commits.

## Secrets

API tokens are consumed via a runtime `.env` file (`CLAUDE_CODE_OAUTH_TOKEN`, `CONTEXT7_API_KEY`,
`PERPLEXITY_API_KEY`). They are **never** committed (`.env` is gitignored) and **never** baked into
the image — they are passed at `docker run` time only. `.env.example` ships placeholders only.

If you ever find a leaked secret in this repository's history, treat the corresponding token as
compromised and rotate it immediately.

## Supply chain

- All npm CLIs are installed via `npm ci` from a committed `tools/package-lock.json` with sha512
  integrity hashes; versions are exact (no floating ranges).
- GitHub-release binaries (`rtk`, `git-delta`) are sha256-verified during build.
- Residual gaps (documented, not yet closed): the caveman installer clones its marketplace repo at
  default-branch HEAD (build-reproducibility gap, not a runtime hole), and `npm ci` does not
  neutralize postinstall network fetchers in transitive dependencies.
