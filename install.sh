#!/usr/bin/env bash
#
# agent-standalone installer.
#
#   curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/install.sh | bash
#
# Pulls the prebuilt GHCR images (claude / codex / opencode), stores the Claude
# Code OAuth token once in ~/.config/agent-standalone/agent.env (chmod 600), and
# installs launchers into ~/.local/bin:
#
#   claude-box            hardened Claude Code over the current directory
#   codex-box             hardened Codex
#   opencode-box          hardened OpenCode
#   agent-box <agent>     the generic launcher (same flags as run_agent.sh)
#
# Each launcher mounts a persistent login directory for its agent's credentials
# (~/.config/agent-standalone/login/<agent>), so codex/login/auth survive restarts.
#
# Re-run any time to update (the launchers are regenerated; existing config is
# kept). Remove with:  bash install.sh --uninstall
#
# Non-interactive: set CLAUDE_CODE_OAUTH_TOKEN in the environment to skip the
# token prompt; set AGENT_IMAGES="claude codex opencode" (space-separated) to
# choose which images to pull. Override the registry base with AGENT_IMAGE_BASE.

set -euo pipefail

REPO="highload-zone/claude-code-standalone"
IMAGE_BASE="${AGENT_IMAGE_BASE:-ghcr.io/${REPO}}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone"
ENV_FILE="$CONFIG_DIR/agent.env"
RES_CONF="$CONFIG_DIR/resources.conf"
LOGIN_ROOT="$CONFIG_DIR/login"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/agent-box"
ALL_AGENTS=(claude codex opencode)

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  for f in agent-box claude-box codex-box opencode-box; do
    rm -f "$BIN_DIR/$f" && say "Removed $BIN_DIR/$f"
  done
  say "Config left in place: $CONFIG_DIR"
  say "Remove it too with:  rm -rf \"$CONFIG_DIR\""
  exit 0
fi

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found in PATH — install Docker first."

agents="${AGENT_IMAGES:-${ALL_AGENTS[*]}}"

# ----------------------------------------------------------------------------
# Pull the images
# ----------------------------------------------------------------------------
for a in $agents; do
  case "$a" in claude|codex|opencode) ;; *) die "unknown agent image '$a'";; esac
  say "Pulling $IMAGE_BASE:$a ..."
  docker pull "$IMAGE_BASE:$a" >&2 \
    || die "docker pull failed for $a. If the package is private, run 'docker login ghcr.io' first."
done

# ----------------------------------------------------------------------------
# Token config (docker --env-file format: raw value, no quotes, no 'export')
# ----------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" "$LOGIN_ROOT" && chmod 700 "$CONFIG_DIR"

token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
existing=""
if [ -f "$ENV_FILE" ]; then
  existing="$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$ENV_FILE" | head -n1 || true)"
fi

if [ -z "$token" ] && [ -n "$existing" ]; then
  say "Existing token found in $ENV_FILE — keeping it."
  token="$existing"
elif [ -z "$token" ]; then
  if [ -r /dev/tty ]; then
    printf 'Claude Code OAuth token (run `claude setup-token` to get one; blank to skip): ' >&2
    read -rs token < /dev/tty || true
    printf '\n' >&2
  fi
fi

umask 077
: > "$ENV_FILE"
if [ -n "$token" ]; then
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$ENV_FILE"
  say "Token saved to $ENV_FILE (chmod 600)."
else
  say "No Claude token stored; set CLAUDE_CODE_OAUTH_TOKEN or run 'claude auth login' in the container."
fi
chmod 600 "$ENV_FILE"
say "Optional keys: add 'CODEX_API_KEY=…', 'OPENAI_API_KEY=…', 'ANTHROPIC_API_KEY=…',"
say "'CONTEXT7_API_KEY=…', 'PERPLEXITY_API_KEY=…' lines to that file."

# ----------------------------------------------------------------------------
# Host resources for Claude: detect ~/.claude/{agents,commands,skills} and pass
# them through (mount live path by default; copy takes a snapshot; skip opts out).
# ----------------------------------------------------------------------------
HOST_CLAUDE="${CLAUDE_HOME:-$HOME/.claude}"
: > "$RES_CONF"

detected=""
for d in agents commands skills; do
  if [ -d "$HOST_CLAUDE/$d" ] && [ -n "$(ls -A "$HOST_CLAUDE/$d" 2>/dev/null)" ]; then
    detected="$detected $d"
  fi
done
detected="${detected# }"

if [ -n "$detected" ]; then
  say ""
  say "Found local Claude resources in $HOST_CLAUDE: $detected"
  mode="${CLAUDE_RESOURCES_MODE:-}"
  if [ -z "$mode" ]; then
    if [ -r /dev/tty ]; then
      printf 'Pass them to the claude image? [M]ount live path (default) / [C]opy snapshot / [S]kip: ' >&2
      read -r ans < /dev/tty
      case "$ans" in [Cc]*) mode="copy";; [Ss]*) mode="skip";; *) mode="mount";; esac
    else
      mode="mount"
    fi
  fi
  if [ "$mode" = "skip" ]; then
    say "Skipping host resource passthrough."
  else
    snapshot="$CONFIG_DIR/resources"
    rm -rf "$snapshot"
    for d in $detected; do
      if [ "$mode" = "copy" ]; then
        mkdir -p "$snapshot/$d"
        cp -a "$HOST_CLAUDE/$d/." "$snapshot/$d/" 2>/dev/null || true
        src="$snapshot/$d"
      else
        src="$HOST_CLAUDE/$d"
      fi
      printf 'CLAUDE_RES_%s="%s"\n' "$(printf '%s' "$d" | tr 'a-z' 'A-Z')" "$src" >> "$RES_CONF"
    done
    say "Host resources ($mode): $detected — merged into the claude container on launch."
  fi
else
  say "No local ~/.claude/{agents,commands,skills} detected — skipping resource passthrough."
fi

# ----------------------------------------------------------------------------
# Install the generic launcher (regenerated every run = upgrade path)
# ----------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
#
# agent-box — run a hardened agent container over the current directory (mounted
# read-write). Installed by agent-standalone's install.sh; re-run it to update.
#
#   agent-box claude [args...]        # extra args pass through to the agent
#   agent-box codex mcp list
#   agent-box opencode mcp list
#
# Env overrides:
#   AGENT_IMAGE_BASE  registry/image base (default: the GHCR image)
#   AGENT_ENV_FILE    env-file with tokens/keys (default: the installer's)
#   DEPLOY_KEY        path to a scoped, read-only git deploy key to enable push
#   AGENT_LOGIN_MOUNT set to 0 to disable the persistent login directory
set -euo pipefail

AGENT="${1:-}"
[ -n "$AGENT" ] && shift || true
case "$AGENT" in
  claude|codex|opencode) ;;
  *) echo "usage: agent-box <claude|codex|opencode> [args...]" >&2; exit 2;;
esac

IMAGE_BASE="${AGENT_IMAGE_BASE:-ghcr.io/highload-zone/claude-code-standalone}"
IMAGE="$IMAGE_BASE:$AGENT"
ENV_FILE="${AGENT_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone/agent.env}"
RES_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone/resources.conf"
LOGIN_ROOT="${AGENT_LOGIN_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/agent-standalone/login}"

# Footgun guards (not a defense against a hostile operator — see SECURITY.md).
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo "agent-box: refusing '$a' — it weakens container isolation." >&2; exit 1;;
  esac
done
[ "$(id -u)" -eq 0 ] && { echo "agent-box: refusing to run as host root." >&2; exit 1; }

args=(
  run -it --rm
  --cap-drop=ALL
  --security-opt=no-new-privileges:true
  --pids-limit=100
  --network=bridge
  --user "$(id -u):$(id -g)"
  --tmpfs "/home/agent:exec,mode=1777,size=512m"
  -e HOME=/home/agent
  --tmpfs "/tmp:noexec,nosuid,size=100m"
  -v "$PWD:/workspace/project:rw"
  -w /workspace/project
)

# Persistent login directory per agent (host dir; entrypoint seeds baked config
# without clobbering the host's credentials).
if [ "${AGENT_LOGIN_MOUNT:-1}" != "0" ]; then
  case "$AGENT" in
    claude)   login_host="$LOGIN_ROOT/claude";   login_ctr="/home/agent/.claude";;
    codex)    login_host="$LOGIN_ROOT/codex";    login_ctr="/home/agent/.codex";;
    opencode) login_host="$LOGIN_ROOT/opencode"; login_ctr="/home/agent/.local/share/opencode";;
  esac
  mkdir -p "$login_host"
  args+=( -v "$login_host:$login_ctr" )
fi

if [ -f "$ENV_FILE" ]; then
  args+=( --env-file "$ENV_FILE" )
else
  echo "agent-box: no env-file at $ENV_FILE — set tokens or re-run install.sh." >&2
fi

case "$AGENT" in
  claude)
    args+=( -e "CLAUDE_REMOTE_CONTROL_PREFIX=${CLAUDE_REMOTE_CONTROL_PREFIX:-$(basename "$PWD")}" )
    # Host Claude resources (agents/commands/skills), configured by install.sh.
    if [ -f "$RES_CONF" ]; then
      . "$RES_CONF"
      for d in agents commands skills; do
        var="CLAUDE_RES_$(printf '%s' "$d" | tr 'a-z' 'A-Z')"
        eval "p=\${$var:-}"
        if [ -n "$p" ] && [ -d "$p" ]; then
          args+=( -v "$p:/host-claude/$d:ro" )
        fi
      done
    fi
    ;;
esac

# git commit identity from the host (so commits are attributed to you).
gn="$(git config --get user.name 2>/dev/null || true)"
ge="$(git config --get user.email 2>/dev/null || true)"
[ -n "$gn" ] && args+=( -e "GIT_AUTHOR_NAME=$gn" -e "GIT_COMMITTER_NAME=$gn" )
[ -n "$ge" ] && args+=( -e "GIT_AUTHOR_EMAIL=$ge" -e "GIT_COMMITTER_EMAIL=$ge" )

# Scoped deploy key for `git push` (read-only, IdentitiesOnly — no ssh pivot).
if [ -n "${DEPLOY_KEY:-}" ] && [ -f "${DEPLOY_KEY}" ]; then
  args+=(
    -v "${DEPLOY_KEY}:/home/agent/deploy_key:ro"
    -e "GIT_SSH_COMMAND=ssh -i /home/agent/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  )
fi

exec docker "${args[@]}" "$IMAGE" "$@"
LAUNCHER_EOF
chmod +x "$LAUNCHER"
say "Launcher installed: $LAUNCHER"

# Thin per-agent wrappers so `claude-box` etc. stay muscle memory.
for a in "${ALL_AGENTS[@]}"; do
  wrapper="$BIN_DIR/${a}-box"
  cat > "$wrapper" <<EOF
#!/usr/bin/env bash
# ${a}-box — wrapper around agent-box installed by agent-standalone's install.sh.
exec "$LAUNCHER" ${a} "\$@"
EOF
  chmod +x "$wrapper"
  say "Launcher installed: $wrapper"
done

# ----------------------------------------------------------------------------
# PATH hint
# ----------------------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*)
    say ""
    say "Done. Run 'claude-box', 'codex-box' or 'opencode-box' from any project directory." ;;
  *)
    say ""
    say "$BIN_DIR is not in your PATH. Add it:"
    say "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc   # or ~/.zshrc"
    say "Then restart your shell and run 'claude-box'." ;;
esac