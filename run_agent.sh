#!/bin/bash

# Run one agent container over the current directory (single read-write mode).
#
#   ./run_agent.sh claude              # autonomous Claude Code TUI
#   ./run_agent.sh codex               # Codex TUI
#   ./run_agent.sh opencode            # OpenCode TUI
#   ./run_agent.sh codex mcp list      # forwarded verbatim -> `codex mcp list`
#   ./run_agent.sh claude --model opus # extra args pass through to the agent
#
# The current directory is mounted READ-WRITE at /workspace/project and the agent
# runs in auto/autonomous mode. The container runs with --user $(id -u):$(id -g)
# so it owns the bind-mounted project; HOME is a writable tmpfs that the
# entrypoint seeds from the baked state (/home/claude).
#
# Login persistence: each agent's credential directory is mounted from the host
# (see AGENT_LOGIN_DIR), so `codex login` / `opencode auth login` / `claude auth
# login` survive a container restart. Disable with AGENT_LOGIN_MOUNT=0.
#
# Threat model (SECURITY.md): on a root-Docker host `docker run` == host root, so
# this wrapper is NOT a boundary vs a hostile operator — the guards below only
# catch accidental misconfig. Use on TRUSTED projects only.

set -euo pipefail

AGENT="${1:-}"
[ -n "$AGENT" ] && shift || true
case "$AGENT" in
  claude|codex|opencode) ;;
  *) echo "usage: $0 <claude|codex|opencode> [agent args...]" >&2; exit 2;;
esac

PROJECT_DIR="$(pwd)"
IMAGE_BASE="${AGENT_IMAGE_BASE:-claude-code-standalone}"
IMAGE="${AGENT_IMAGE:-$IMAGE_BASE:$AGENT}"
AGENT_ARGS=("$@")

# --- Footgun guards (not a defense against a hostile operator — see SECURITY.md) ---
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo " Refusing: argument '$a' weakens isolation." >&2; exit 1;;
  esac
done
[ "$(id -u)" -eq 0 ] && { echo "❌ Refusing to run as root on the host." >&2; exit 1; }

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo " Image '$IMAGE' not found. Build it: ./build.sh $AGENT" >&2
  exit 1
fi

# --- Load .env ---
if [ -f .env ]; then set -a; . ./.env; set +a; fi

case "$AGENT" in
  claude)
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && echo "⚠️  CLAUDE_CODE_OAUTH_TOKEN not set — Claude Code may not work.";;
  codex)
    [ -z "${CODEX_API_KEY:-}" ] && echo "ℹ️  CODEX_API_KEY not set — use 'docker run … /bin/bash' + 'codex login', or set it in .env.";;
  opencode)
    echo "ℹ️  OpenCode reads provider keys from .env (e.g. OPENAI_API_KEY, ANTHROPIC_API_KEY) or 'opencode auth login'.";;
esac

DOCKER_ARGS=(
  run -it --rm
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=100
  --network=bridge
  # Match host ownership so the rw project mount is writable by the agent.
  --user "$(id -u):$(id -g)"
  # Writable HOME on tmpfs; the entrypoint seeds the baked agent state into it.
  --tmpfs "/home/agent:exec,mode=1777,size=512m"
  -e HOME=/home/agent
  # Non-executable scratch space.
  --tmpfs "/tmp:noexec,nosuid,size=100m"
  # Project mounted READ-WRITE — the agent edits/commits/pushes here.
  -v "$PROJECT_DIR:/workspace/project:rw"
  -w /workspace/project
)

# --- Persistent login directory per agent ---
# Mounted as a directory (not a file) so docker never creates a stray dir for a
# missing file, and the entrypoint's no-clobber seed fills in baked config
# without overwriting the host's credentials.
if [ "${AGENT_LOGIN_MOUNT:-1}" != "0" ]; then
  LOGIN_ROOT="${AGENT_LOGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone/login}"
  case "$AGENT" in
    claude)   login_host="$LOGIN_ROOT/claude";   login_ctr="/home/agent/.claude";;
    codex)    login_host="$LOGIN_ROOT/codex";    login_ctr="/home/agent/.codex";;
    opencode) login_host="$LOGIN_ROOT/opencode"; login_ctr="/home/agent/.local/share/opencode";;
  esac
  mkdir -p "$login_host"
  DOCKER_ARGS+=( -v "$login_host:$login_ctr" )
  echo " Login state: $login_host -> $login_ctr"
fi

case "$AGENT" in
  claude)
    DOCKER_ARGS+=(
      -e "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
      # Remote Control is on by default in the entrypoint; name its sessions
      # after the host project instead of the container's throwaway hostname.
      -e "CLAUDE_REMOTE_CONTROL_PREFIX=${CLAUDE_REMOTE_CONTROL_PREFIX:-$(basename "$PROJECT_DIR")}"
    )
    # --- Host ~/.claude resources (agents/commands/skills) for Claude ---
    for d in agents commands skills; do
      host="$HOME/.claude/$d"
      [ -d "$host" ] && DOCKER_ARGS+=( -v "$host:/host-claude/$d:ro" )
    done
    ;;
  codex)
    DOCKER_ARGS+=( -e "CODEX_API_KEY=${CODEX_API_KEY:-}" )
    ;;
esac

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
  echo " Scoped deploy key mounted (push limited to that key's repo, no ssh pivot)."
else
  echo "ℹ️  No DEPLOY_KEY — edit + local commit work; 'git push' needs: export DEPLOY_KEY=/path/to/key"
fi

# --- Pass remaining .env vars (MCP API keys, provider keys) ---
if [ -f .env ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue;; esac
    n="${line%%=*}"; [ -z "$n" ] && continue
    v="${!n:-}"; [ -n "$v" ] && DOCKER_ARGS+=( -e "$n=$v" )
  done < .env
fi

echo "🚀 $AGENT agent (read-write) on: $PROJECT_DIR"
docker "${DOCKER_ARGS[@]}" "$IMAGE" "${AGENT_ARGS[@]}"