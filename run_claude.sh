#!/bin/bash

# Claude Code — single read-write agent mode.
#
# The current directory is mounted READ-WRITE at /workspace and Claude Code runs
# as a fully autonomous agent (edit / commit / push). The container runs with
# --user $(id -u):$(id -g) so it owns the bind-mounted project (one image, works
# for any host uid); the baked agent state (config, RTK hook, caveman plugin,
# opsx commands) is copied into a writable tmpfs HOME by the entrypoint.
#
# Threat model (SECURITY.md): on a root-Docker host `docker run` == host root,
# so this wrapper is NOT a boundary vs a hostile operator — the guards below only
# catch accidental misconfig. Use on TRUSTED projects only.

set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="${CLAUDE_IMAGE:-claude-code-standalone:latest}"
CLAUDE_ARGS=("$@")

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
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "⚠️  CLAUDE_CODE_OAUTH_TOKEN not set — Claude Code may not work."

DOCKER_ARGS=(
  run -it --rm
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=100
  --network=bridge
  # Match host ownership so the rw project mount is writable by the agent.
  --user "$(id -u):$(id -g)"
  # Writable HOME on tmpfs; the entrypoint copies the baked agent state into it.
  --tmpfs "/home/agent:exec,mode=1777,size=512m"
  -e HOME=/home/agent
  # Non-executable scratch space.
  --tmpfs "/tmp:noexec,nosuid,size=100m"
  # Project mounted READ-WRITE — the agent edits/commits/pushes here.
  -v "$PROJECT_DIR:/workspace:rw"
  -w /workspace
  -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
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
  echo "🔑 Scoped deploy key mounted (push limited to that key's repo, no ssh pivot)."
else
  echo "ℹ️  No DEPLOY_KEY — edit + local commit work; 'git push' needs: export DEPLOY_KEY=/path/to/key"
fi

# --- Pass remaining .env vars (MCP API keys) ---
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    n="${line%%=*}"; [ -z "$n" ] && continue
    v="${!n:-}"; [ -n "$v" ] && DOCKER_ARGS+=( -e "$n=$v" )
  done < .env
fi

echo "🚀 Claude Code agent (read-write) on: $PROJECT_DIR"
docker "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_ARGS[@]}"
