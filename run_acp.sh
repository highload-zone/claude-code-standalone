#!/bin/bash

# Claude Code over ACP (Agent Client Protocol) — for IDE use (Zed and other
# ACP-compatible editors).
#
# Unlike run_claude.sh (an interactive TUI), this exposes the container as an ACP
# agent the EDITOR launches and drives over stdio. Zed runs this script as a
# subprocess and exchanges JSON-RPC on stdin/stdout. See README "Use from an IDE
# (Zed / ACP)" for the settings.json block.
#
# Two invariants make ACP work and are easy to get wrong:
#   1. stdout is the JSON-RPC channel. It must carry ONLY protocol bytes — every
#      message this script prints goes to stderr (>&2). `docker run -i` (NOT -it):
#      a TTY would corrupt the stream.
#   2. Path coherence. Zed sends the agent HOST-absolute paths (cwd, @-mentions,
#      diffs). The project is therefore mounted at the IDENTICAL absolute path
#      ("$PWD:$PWD", -w "$PWD"), NOT at /workspace, so paths from the editor and
#      paths inside the container are the same string.
#
# Permission posture: in ACP mode tool-call permissions are gated by the editor
# UI (a human approves edits / commands), so this path is LESS permissive than
# run_claude.sh's --dangerously-skip-permissions entrypoint. See SECURITY.md.
#
# Threat model (SECURITY.md): on a root-Docker host `docker run` == host root, so
# this wrapper is NOT a boundary vs a hostile operator. Use on TRUSTED projects.

set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="${CLAUDE_IMAGE:-claude-code-standalone:latest}"
ACP_ARGS=("$@")
# Interactive IDE work (test runners, language servers, builds) forks far more
# processes than a one-shot agent run; raise the pids cap above run_claude.sh's
# 100. Override with ACP_PIDS_LIMIT if needed.
PIDS_LIMIT="${ACP_PIDS_LIMIT:-512}"

# --- Footgun guards (not a defense against a hostile operator — see SECURITY.md) ---
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo "❌ Refusing: argument '$a' weakens isolation." >&2; exit 1;;
  esac
done
[ "$(id -u)" -eq 0 ] && { echo "❌ Refusing to run as root on the host." >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "❌ Image '$IMAGE' not found. Build it: ./build.sh (or set CLAUDE_IMAGE / pull from GHCR)" >&2
  exit 1
fi

# --- Load .env ---
if [ -f .env ]; then set -a; . ./.env; set +a; fi
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "⚠️  CLAUDE_CODE_OAUTH_TOKEN not set — the ACP agent may not authenticate." >&2

DOCKER_ARGS=(
  run --rm -i
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit="$PIDS_LIMIT"
  --network=bridge
  # Match host ownership so the rw project mount is writable by the agent.
  --user "$(id -u):$(id -g)"
  # Writable HOME on tmpfs; start-acp.sh copies the baked agent state into it.
  --tmpfs "/home/agent:exec,mode=1777,size=512m"
  -e HOME=/home/agent
  # Non-executable scratch space.
  --tmpfs "/tmp:noexec,nosuid,size=100m"
  # Project mounted READ-WRITE at the SAME absolute path the editor uses (path
  # coherence for @-mentions / diffs / cwd — do not change to /workspace).
  -v "$PROJECT_DIR:$PROJECT_DIR:rw"
  -w "$PROJECT_DIR"
  -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
  # ACP entrypoint (stdio JSON-RPC). dumb-init is PID 1 for signal/zombie reaping
  # and proxies stdio transparently.
  --entrypoint dumb-init
)

# --- git commit identity from host (via env, not a gitconfig mount) ---
gn="$(git config --get user.name 2>/dev/null || true)"
ge="$(git config --get user.email 2>/dev/null || true)"
[ -n "$gn" ] && DOCKER_ARGS+=( -e "GIT_AUTHOR_NAME=$gn" -e "GIT_COMMITTER_NAME=$gn" )
[ -n "$ge" ] && DOCKER_ARGS+=( -e "GIT_AUTHOR_EMAIL=$ge" -e "GIT_COMMITTER_EMAIL=$ge" )

# --- Scoped deploy key for git push (preferred over ssh-agent forwarding) ---
if [ -n "${DEPLOY_KEY:-}" ] && [ -f "${DEPLOY_KEY}" ]; then
  DOCKER_ARGS+=(
    -v "${DEPLOY_KEY}:/home/agent/deploy_key:ro"
    -e "GIT_SSH_COMMAND=ssh -i /home/agent/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  )
  echo "🔑 Scoped deploy key mounted (push limited to that key's repo, no ssh pivot)." >&2
else
  echo "ℹ️  No DEPLOY_KEY — edit + local commit work; 'git push' needs: export DEPLOY_KEY=/path/to/key" >&2
fi

# --- Pass remaining .env vars (MCP API keys) ---
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    n="${line%%=*}"; [ -z "$n" ] && continue
    v="${!n:-}"; [ -n "$v" ] && DOCKER_ARGS+=( -e "$n=$v" )
  done < .env
fi

echo "🚀 claude-agent-acp (ACP stdio, read-write) on: $PROJECT_DIR" >&2
# After the image name come dumb-init's args: run the baked ACP entrypoint.
exec docker "${DOCKER_ARGS[@]}" "$IMAGE" -- /home/claude/start-acp.sh "${ACP_ARGS[@]}"
