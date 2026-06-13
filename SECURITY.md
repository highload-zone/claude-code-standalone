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
  (`run_claude.sh`, `debug-shell.sh`) are **NOT a security boundary against a hostile operator** —
  anyone who can run Docker can ignore them and mount `/`, add capabilities, or pass `--privileged`.
  The scripts' guard checks (refusing `--privileged`, `--pid=host`, `docker.sock`, uid 0, etc.) only
  catch **accidental misconfiguration**, not a deliberate operator.
- **Required invariants for the hardening to hold** (operator's responsibility): never mount
  `/var/run/docker.sock`, never use `--privileged` / `--cap-add` / `--pid=host` / `--network=host`,
  never `--user root`, never mount sensitive host paths. The provided scripts already satisfy these.
- **Residual escape vectors not addressed by the image:** kernel LPE from an unprivileged container
  (mitigate by patching the host kernel) and operator bypass (out of the image's control).

## Known limitations (by design)

- **The image ENTRYPOINT runs in auto mode by default, not full bypass.** `permissions.defaultMode`
  is `"auto"` (`~/.claude/settings.json`): the agent runs autonomously, but a background classifier
  vets actions and blocks dangerous ones. Full bypass (`--dangerously-skip-permissions`) is now
  **opt-in** via `CLAUDE_BYPASS_PERMISSIONS=1`, for isolated/throwaway containers that accept no
  in-app checks. The OS-level container boundary is still the perimeter; a bare `docker run` without
  a wrapper has no host-level hardening — always use the wrapper scripts. Two by-design auto-mode
  behaviors: (a) on entering auto, blanket `Bash(*)` / `Agent` allow rules are dropped (the
  classifier takes over; narrow rules carry over); (b) in non-interactive `-p` runs, repeated
  classifier blocks abort the session (no user to prompt).
- **Auto mode can silently fall back to `default`.** If the account/model doesn't support auto
  (e.g. Team/Enterprise without admin-enabled auto, or a non-API provider), Claude Code starts in
  `default` mode with no error — meaning it prompts on most actions. Verify the status bar shows
  `auto` on first run; set `CLAUDE_BYPASS_PERMISSIONS=1` if you need unattended operation regardless.
- **Remote Control is opt-in and off by default.** Set `CLAUDE_REMOTE_CONTROL=1` to add
  `--remote-control`, which opens an outbound connection to the Remote Control service. It also
  requires a **full-scope login token** (`claude auth login`): the long-lived `CLAUDE_CODE_OAUTH_TOKEN`
  / `claude setup-token` this image normally uses is inference-only, so Remote Control stays disabled
  with it even if the flag is set. Leave the env var unset if your environment forbids that channel.
- **Outbound network is allowed.** Bridge networking blocks the host network but not the internet.
  `context7` and `perplexity` MCP servers transmit data (including code context) to third parties.
  On a root host this is an exfiltration channel under prompt injection — restrict egress at the
  Docker-network/daemon level (cap-drop=ALL prevents in-container iptables) or remove those MCP
  servers from `mcp-servers.json`.
- **Prompt injection (the main runtime risk).** Any file in the project is potential instructions for
  the autonomous agent. In the default **auto mode** the classifier blocks the worst injected actions
  (exfiltration to external endpoints, `curl | bash`, force-push, prod deploys) — but it is a research
  preview, not a guarantee, and boundaries you state in chat can be lost to context compaction. With
  `CLAUDE_BYPASS_PERMISSIONS=1` there are **no** in-app checks at all. The project is mounted
  **read-write**, so an injected agent can modify project files, push (if a deploy key is set), and
  exfiltrate code via egress. Residual risk is **Medium** with a scoped deploy key (below). **Use on
  trusted projects only** and review what the agent commits.
- **Third-party trust.** RTK's `PreToolUse` hook rewrites every Bash command (compromise = injection
  into every shell call); CodeGraph ships an opaque vendored binary. Both are version/checksum
  pinned, but auditing them is the operator's responsibility.

## Read-write agent mode (single mode)

The container runs as a single autonomous read-write agent: the project is bind-mounted `rw` at
`/workspace`, and the container runs with `--user $(id -u):$(id -g)` so it owns the mount. Guardrails:

- **Scoped deploy key for push** (read-only mounted, `IdentitiesOnly=yes`), set via
  `DEPLOY_KEY=/path/to/key` — the agent can push only to that one repo and **cannot ssh elsewhere**
  (deliberately not ssh-agent forwarding, which would authenticate to any SSH host). Without it,
  edit + local commit work; push does not.
- **Project git hooks are disabled** in the container (`core.hooksPath=/dev/null`) so an injected
  `.git/hooks` script does not execute on git operations.
- **Footgun guards** (refuse `--privileged`/`docker.sock`/`--pid=host`/`--network=host`/`--cap-add`/
  uid 0) as above.
- Writable HOME is a tmpfs; the baked agent state is copied into it at start. The image's baked
  `/home/claude` is world-readable (no secrets — `claude-config.json` is sanitized).

## IDE modes (ACP adapter and Dev Container)

Two additional entrypoints exist for IDE use; both change the posture relative to the autonomous
`run_claude.sh` entrypoint and are documented here.

- **ACP adapter (`run_acp.sh` → `claude-agent-acp`).** The editor (e.g. Zed) launches the container
  over stdio and drives it via the Agent Client Protocol. Crucially, this path does **not** pass
  `--dangerously-skip-permissions`; tool calls (edits, shell commands) are sent back to the editor as
  **permission requests a human approves**. So the ACP path is *less* permissive than the autonomous
  agent entrypoint — a human gates each action, versus auto mode's background classifier (or full
  bypass under `CLAUDE_BYPASS_PERMISSIONS=1`). It keeps the same hardening (`cap-drop=ALL`, `no-new-privileges`, bridge
  network, non-root `--user`, tmpfs HOME) with a raised `--pids-limit` (interactive tooling forks
  more). The project is bind-mounted **read-write at its host-absolute path** (path coherence for the
  editor); the same `DEPLOY_KEY` model gates `git push`. Outbound network and prompt-injection risks
  are unchanged from the main agent mode.
- **Dev Container (`.devcontainer/devcontainer.json`).** You work interactively in the container; the
  auto-launch ENTRYPOINT is suppressed (`overrideCommand: true`). It keeps the hardened profile but
  adds back a **minimal capability set** (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`) that
  the one-time uid-remap (`updateRemoteUserUID`) needs at container start to chown the home dir; the
  dangerous capabilities (`SYS_ADMIN`, `NET_ADMIN`, `NET_RAW`, `SYS_PTRACE`, `SYS_MODULE`, …) remain
  dropped, and the interactive non-root `claude` user holds none in its effective set. `--pids-limit`
  is raised to 512 for test runners / language servers / builds.

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
- The ACP adapter pulls in `@anthropic-ai/claude-agent-sdk`, which ships its own Claude Code binary
  as a per-platform optionalDependency. To avoid executing a second, separately-sourced Claude
  binary, `CLAUDE_CODE_EXECUTABLE` pins the ACP path to the already-audited `claude` from the
  toolchain; the SDK's bundled binary is installed (it is an npm-locked, integrity-verified tarball)
  but **not executed** at runtime. This is image-size overhead, not a runtime exposure.
