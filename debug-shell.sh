#!/bin/bash

# Debug shell inside the container — same single read-write mode as run_claude.sh,
# but drops you into bash instead of launching Claude Code.
#
# NOTE: with --entrypoint bash the normal HOME-copy (done by start-claude.sh) does
# NOT run. To get the baked agent state (config, hooks, opsx) in your HOME:
#     cp -a /home/claude/. "$HOME/"
# then: claude --version  /  claude mcp list

set -euo pipefail

PROJECT_DIR="$(pwd)"
IMAGE="${CLAUDE_IMAGE:-claude-code-standalone:latest}"

[ "$(id -u)" -eq 0 ] && { echo "❌ Refusing to run as root on the host." >&2; exit 1; }
if [ -f .env ]; then set -a; . ./.env; set +a; fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "❌ Image '$IMAGE' not found. Build: ./build.sh" >&2; exit 1; }

DOCKER_ARGS=(
  run -it --rm
  --entrypoint bash
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=100
  --network=bridge
  --user "$(id -u):$(id -g)"
  --tmpfs "/home/agent:exec,mode=1777,size=512m"
  -e HOME=/home/agent
  --tmpfs "/tmp:noexec,nosuid,size=100m"
  -v "$PROJECT_DIR:/workspace:rw"
  -w /workspace
  -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
)

if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    n="${line%%=*}"; [ -z "$n" ] && continue
    v="${!n:-}"; [ -n "$v" ] && DOCKER_ARGS+=( -e "$n=$v" )
  done < .env
fi

echo "🐚 Debug shell (read-write /workspace) on: $PROJECT_DIR"
echo "   Tip: run 'cp -a /home/claude/. \"\$HOME/\"' to load the baked agent state."
docker "${DOCKER_ARGS[@]}" "$IMAGE"
