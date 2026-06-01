#!/bin/bash

# ============================================================================
# DEV MODE — read-write project + scoped git push. USE WITH CARE.
# ============================================================================
# This runs Claude Code as a FULLY AUTONOMOUS agent over your project:
#   - project mounted READ-WRITE (Claude can edit and commit)
#   - a SCOPED, read-only-mounted deploy key for ONE repo (Claude can push only
#     to that repo — NOT ssh-agent forwarding, which would let it ssh anywhere)
#   - bypassPermissions (no in-app prompts)
#
# Threat model (see SECURITY.md): on a root-Docker host, `docker run` == host
# root, so this wrapper is NOT a boundary against a hostile operator — the guard
# checks below only catch ACCIDENTAL misconfig. Residual risk of dev mode is
# Medium (with the deploy key) and concentrates on prompt-injection from the
# project code. Use only on TRUSTED projects.
#
# Requires the dev image: ./build-dev.sh   (built under your uid)
# Optional deploy key:    export DEPLOY_KEY=/path/to/repo_deploy_key
#                         (no key -> edit+local commit work, push won't)

set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="claude-code-standalone:dev"
CLAUDE_ARGS=("$@")

# --- Footgun guards (NOT a defense against a hostile operator — see SECURITY.md) ---
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo "❌ Refusing: argument '$a' weakens isolation. Not allowed via this script." >&2
      exit 1;;
  esac
done
if [ "$(id -u)" -eq 0 ]; then
  echo "❌ Refusing to run as root on the host (build/run under your normal user)." >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "❌ Dev image '$IMAGE' not found. Build it first: ./build-dev.sh" >&2
  exit 1
fi

# --- Load .env (token + keys) ---
if [ -f .env ]; then set -a; . ./.env; set +a; fi
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "⚠️  CLAUDE_CODE_OAUTH_TOKEN not set — Claude Code may not work."

mkdir -p reports

DOCKER_ARGS=(
  run -it --rm
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --tmpfs /tmp:noexec,nosuid,size=100m
  --tmpfs /workspace/temp:noexec,nosuid,size=2g
  --pids-limit=100
  --network=bridge
  # Project READ-WRITE — full dev access (edit + commit + scoped push)
  -v "$PROJECT_DIR:/workspace/project:rw"
  -w /workspace/project
  -v "$PROJECT_DIR/reports:/workspace/output:rw"
  -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
  # P0 (audit F3): do NOT execute the project's git hooks inside the container —
  # an injected hook would otherwise run on git ops. Disable via env-level config.
  -e "GIT_CONFIG_COUNT=1" -e "GIT_CONFIG_KEY_0=core.hooksPath" -e "GIT_CONFIG_VALUE_0=/dev/null"
)

# --- git identity (read-only) ---
[ -f "$HOME/.gitconfig" ] && DOCKER_ARGS+=( -v "$HOME/.gitconfig:/home/claude/.gitconfig:ro" )

# --- Scoped deploy key (preferred over ssh-agent forwarding) ---
if [ -n "${DEPLOY_KEY:-}" ] && [ -f "${DEPLOY_KEY}" ]; then
  DOCKER_ARGS+=(
    -v "${DEPLOY_KEY}:/home/claude/.ssh/deploy_key:ro"
    # IdentitiesOnly: use ONLY this key (no agent, no other keys -> no ssh pivot)
    -e "GIT_SSH_COMMAND=ssh -i /home/claude/.ssh/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  )
  echo "🔑 Scoped deploy key mounted (push limited to that key's repo)."
else
  echo "ℹ️  No DEPLOY_KEY set — edit + local commit will work; 'git push' will not."
  echo "    To enable push: export DEPLOY_KEY=/path/to/repo_deploy_key"
fi

# --- Pass remaining .env vars (API keys for MCP) ---
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    var_name="${line%%=*}"; [ -z "$var_name" ] && continue
    var_value="${!var_name:-}"
    [ -n "$var_value" ] && DOCKER_ARGS+=( -e "$var_name=$var_value" )
  done < .env
fi

echo "🚀 DEV mode (read-write project, scoped push, autonomous agent)"
echo "📁 Project (rw): $PROJECT_DIR"
echo "⚠️  Claude can edit/commit/push this project. Trusted projects only."
docker "${DOCKER_ARGS[@]}" "$IMAGE" "${CLAUDE_ARGS[@]}"
