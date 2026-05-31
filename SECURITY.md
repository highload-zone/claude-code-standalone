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

## Known limitations (by design)

- **The image ENTRYPOINT is permissive.** Hardening lives in the wrapper scripts. Running the image
  with a bare `docker run` (no wrapper) bypasses all container-level protections. Always use
  `run_claude.sh` / `debug-shell.sh`.
- **Outbound network is allowed.** Bridge networking blocks the host network but not the internet.
  The `context7` and `perplexity` MCP servers transmit data (including code context) to third
  parties. Remove them from `mcp-servers.json` if your threat model forbids this egress.
- **Third-party trust.** RTK's `PreToolUse` hook can see and rewrite every Bash command;
  CodeGraph ships an opaque vendored binary. Both are version- and checksum-pinned, but auditing
  them is left to the operator.

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
