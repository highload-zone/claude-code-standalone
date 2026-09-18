#!/bin/bash
set -e

# Shared entrypoint for the claude / codex / opencode images. The image bakes
# AGENT=<name>; everything else is common:
#   1. seed the baked agent state from /home/claude into the runtime HOME,
#   2. merge host-provided Claude resources,
#   3. exec the agent, forwarding arguments verbatim.
#
# Argument forwarding is deliberate: with any argument the agent is run directly
# (`docker run <image> mcp list` -> `codex mcp list`), so introspection commands
# are exact. Interactive-only flags are applied only for a bare TUI launch.

export HOME="${HOME:-/home/agent}"
AGENT="${AGENT:-claude}"

# Runtime starts with --user $(id -u):$(id -g) to match host ownership of the rw
# project mount. -n (no-clobber) is load-bearing: when a login directory is
# mounted (e.g. a host ~/.codex carrying auth.json), baked defaults fill only the
# gaps and never overwrite the host's credentials or config.
if [ "$HOME" != "/home/claude" ] && [ ! -e "$HOME/.agent-seeded" ]; then
  mkdir -p "$HOME"
  cp -an /home/claude/. "$HOME/" 2>/dev/null || true
  : > "$HOME/.agent-seeded" 2>/dev/null || true
fi

# Host-provided Claude resources mounted by the launcher at /host-claude/<name>.
# Unconditional and after the baked copy so a resumed HOME still receives them;
# host files win on collision while baked-only files survive (cp merges).
for d in agents commands skills; do
  if [ -d "/host-claude/$d" ]; then
    mkdir -p "$HOME/.claude/$d"
    cp -a "/host-claude/$d/." "$HOME/.claude/$d/" 2>/dev/null || true
  fi
done

cd /workspace/project 2>/dev/null || cd "$HOME"

# Any argument => deterministic, no interactive flags.
if [ "$#" -gt 0 ]; then
  exec "$AGENT" "$@"
fi

case "$AGENT" in
  claude)
    EXTRA_ARGS=""
    mode_msg="permission mode: auto (default; falls back to default mode if auto is unavailable)"
    if [ "${CLAUDE_BYPASS_PERMISSIONS:-0}" = "1" ]; then
      EXTRA_ARGS="$EXTRA_ARGS --dangerously-skip-permissions"
      mode_msg="permission mode: bypass (CLAUDE_BYPASS_PERMISSIONS=1 — no in-app safety checks)"
    fi
    if [ "${CLAUDE_REMOTE_CONTROL:-1}" != "0" ]; then
      # Session names are auto-generated as <prefix>-<random-words>; the CLI
      # default prefix is the container hostname, useless in a container.
      rc_prefix="$(printf %s "${CLAUDE_REMOTE_CONTROL_PREFIX:-claude-box}" | tr -c "[:alnum:]._-" "-" | cut -c1-40)"
      [ -z "$rc_prefix" ] && rc_prefix="claude-box"
      EXTRA_ARGS="$EXTRA_ARGS --remote-control --remote-control-session-name-prefix $rc_prefix"
      if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        mode_msg="$mode_msg; Remote Control requested (prefix: $rc_prefix) but INACTIVE — CLAUDE_CODE_OAUTH_TOKEN is inference-only. Run 'claude auth login' in this container to use it, or set CLAUDE_REMOTE_CONTROL=0 to stop asking"
      else
        mode_msg="$mode_msg; Remote Control on (prefix: $rc_prefix)"
      fi
    fi
    echo "Starting Claude Code in $(pwd) — $mode_msg..."
    exec claude $EXTRA_ARGS
    ;;
  codex)
    echo "Starting Codex in $(pwd)..."
    if [ -n "${CODEX_ARGS:-}" ]; then
      exec codex $CODEX_ARGS
    fi
    exec codex
    ;;
  opencode)
    echo "Starting OpenCode in $(pwd)..."
    if [ -n "${OPENCODE_ARGS:-}" ]; then
      exec opencode $OPENCODE_ARGS
    fi
    exec opencode
    ;;
  *)
    echo "unknown AGENT='$AGENT' (expected claude|codex|opencode)" >&2
    exit 1
    ;;
esac