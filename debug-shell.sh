#!/bin/bash

# Debug shell inside an agent container — same single read-write mode as
# run_agent.sh, but drops you into bash instead of launching the agent.
#
#   ./debug-shell.sh            # claude image
#   ./debug-shell.sh codex      # codex image
#   ./debug-shell.sh opencode   # opencode image
#
# NOTE: with --entrypoint bash the normal HOME seeding (done by start-agent.sh)
# does NOT run. To get the baked agent state in your HOME:
#     cp -a /home/claude/. "$HOME/"
# then e.g.: claude --version  /  codex mcp list  /  opencode mcp list

set -euo pipefail

AGENT="${1:-claude}"
[ -n "${1:-}" ] && shift || true
case "$AGENT" in
  claude|codex|opencode) ;;
  *) echo "usage: $0 [claude|codex|opencode]" >&2; exit 2;;
esac

PROJECT_DIR="$(pwd)"
IMAGE_BASE="${AGENT_IMAGE_BASE:-claude-code-standalone}"
IMAGE="${AGENT_IMAGE:-$IMAGE_BASE:$AGENT}"

[ "$(id -u)" -eq 0 ] && { echo "❌ Refusing to run as root on the host." >&2; exit 1; }
if [ -f .env ]; then set -a; . ./.env; set +a; fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "❌ Image '$IMAGE' not found. Build: ./build.sh $AGENT" >&2; exit 1; }

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
  -v "$PROJECT_DIR:/workspace/project:rw"
  -w /workspace/project
)

# Mount the same login directory run_agent.sh uses, so a debug shell sees the
# credentials and can run the agent's own login flow persistently.
if [ "${AGENT_LOGIN_MOUNT:-1}" != "0" ]; then
  LOGIN_ROOT="${AGENT_LOGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone/login}"
  case "$AGENT" in
    claude)   login_host="$LOGIN_ROOT/claude";   login_ctr="/home/agent/.claude";;
    codex)    login_host="$LOGIN_ROOT/codex";    login_ctr="/home/agent/.codex";;
    opencode) login_host="$LOGIN_ROOT/opencode"; login_ctr="/home/agent/.local/share/opencode";;
  esac
  mkdir -p "$login_host"
  DOCKER_ARGS+=( -v "$login_host:$login_ctr" )
fi

if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    n="${line%%=*}"; [ -z "$n" ] && continue
    v="${!n:-}"; [ -n "$v" ] && DOCKER_ARGS+=( -e "$n=$v" )
  done < .env
fi

echo " Debug shell for '$AGENT' (read-write /workspace/project) on: $PROJECT_DIR"
echo "   Tip: run 'cp -a /home/claude/. \"\$HOME/\"' to load the baked agent state."
docker "${DOCKER_ARGS[@]}" "$IMAGE"