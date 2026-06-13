#!/usr/bin/env bash
#
# claude-standalone installer.
#
#   curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/install.sh | bash
#
# Installs a `claude-box` launcher into ~/.local/bin, pulls the prebuilt GHCR
# image, and stores your Claude Code OAuth token once in
# ~/.config/claude-standalone/claude.env (chmod 600). After that, run `claude-box`
# from any project directory to start the hardened agent over the current folder.
#
# Re-run any time to update (the launcher is regenerated; an existing token is
# kept). Remove with:  bash install.sh --uninstall
#
# Non-interactive: set CLAUDE_CODE_OAUTH_TOKEN in the environment before running
# and the token prompt is skipped. Override the image with CLAUDE_IMAGE.
#
# Supply-chain note: this is `curl | bash` from a branch. If you prefer to read
# before running:
#   curl -fsSL https://raw.githubusercontent.com/highload-zone/claude-code-standalone/main/install.sh -o install.sh
#   less install.sh && bash install.sh

set -euo pipefail

REPO="highload-zone/claude-code-standalone"
IMAGE="${CLAUDE_IMAGE:-ghcr.io/${REPO}:latest}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-standalone"
ENV_FILE="$CONFIG_DIR/claude.env"
BIN_DIR="$HOME/.local/bin"
LAUNCHER="$BIN_DIR/claude-box"

say()  { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Uninstall
# ----------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$LAUNCHER" && say "Removed $LAUNCHER"
  say "Config left in place: $CONFIG_DIR"
  say "Remove it too with:  rm -rf \"$CONFIG_DIR\""
  exit 0
fi

# ----------------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found in PATH — install Docker first."

# ----------------------------------------------------------------------------
# Pull the image
# ----------------------------------------------------------------------------
say "Pulling $IMAGE ..."
docker pull "$IMAGE" >&2 \
  || die "docker pull failed. If the package is private, run 'docker login ghcr.io' first."

# ----------------------------------------------------------------------------
# Token config (docker --env-file format: raw value, no quotes, no 'export')
# ----------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR"

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
    printf 'Claude Code OAuth token (run `claude setup-token` to get one): ' >&2
    read -rs token < /dev/tty
    printf '\n' >&2
  else
    die "No CLAUDE_CODE_OAUTH_TOKEN set and no /dev/tty for interactive input.
       Set CLAUDE_CODE_OAUTH_TOKEN in the environment and re-run."
  fi
fi
[ -n "$token" ] || die "empty token — aborting."

umask 077
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$token" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
say "Token saved to $ENV_FILE (chmod 600)."
say "Optional MCP keys: add 'CONTEXT7_API_KEY=...' / 'PERPLEXITY_API_KEY=...' lines to that file."

# ----------------------------------------------------------------------------
# Host resources: detect ~/.claude/{agents,commands,skills} and pass them through
# (the launcher mounts them at /host-claude/*; the container entrypoint merges
# them OVER the baked state — host wins, baked-only files like opsx survive).
# Default is to mount the live path; copy takes a snapshot; skip opts out.
# ----------------------------------------------------------------------------
RES_CONF="$CONFIG_DIR/resources.conf"
RES_SNAPSHOT="$CONFIG_DIR/resources"
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
      printf 'Pass them to the container? [M]ount live path (default) / [C]opy snapshot / [S]kip: ' >&2
      read -r ans < /dev/tty
      case "$ans" in [Cc]*) mode="copy";; [Ss]*) mode="skip";; *) mode="mount";; esac
    else
      mode="mount"   # non-interactive default
    fi
  fi
  if [ "$mode" = "skip" ]; then
    say "Skipping host resource passthrough."
  else
    rm -rf "$RES_SNAPSHOT"
    for d in $detected; do
      if [ "$mode" = "copy" ]; then
        mkdir -p "$RES_SNAPSHOT/$d"
        cp -a "$HOST_CLAUDE/$d/." "$RES_SNAPSHOT/$d/" 2>/dev/null || true
        src="$RES_SNAPSHOT/$d"
      else
        src="$HOST_CLAUDE/$d"
      fi
      printf 'CLAUDE_RES_%s="%s"\n' "$(printf '%s' "$d" | tr 'a-z' 'A-Z')" "$src" >> "$RES_CONF"
    done
    say "Host resources ($mode): $detected — will be merged into the container's ~/.claude/ on launch."
  fi
else
  say "No local ~/.claude/{agents,commands,skills} detected — skipping resource passthrough."
fi

# ----------------------------------------------------------------------------
# Install the launcher (regenerated every run = upgrade path)
# ----------------------------------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$LAUNCHER" <<'LAUNCHER_EOF'
#!/usr/bin/env bash
#
# claude-box — run the hardened claude-code-standalone container over the current
# directory (mounted read-write). Installed by claude-standalone's install.sh;
# re-run the installer to update. Extra args are passed through to `claude`.
#
# Env overrides:
#   CLAUDE_IMAGE     image to run (default: the GHCR :latest)
#   CLAUDE_ENV_FILE  env-file with CLAUDE_CODE_OAUTH_TOKEN (+ optional MCP keys)
#   DEPLOY_KEY       path to a scoped, read-only git deploy key to enable push
set -euo pipefail

IMAGE="${CLAUDE_IMAGE:-ghcr.io/highload-zone/claude-code-standalone:latest}"
ENV_FILE="${CLAUDE_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-standalone/claude.env}"
RES_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/claude-standalone/resources.conf"

# Footgun guards (not a defense against a hostile operator — see SECURITY.md).
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo "claude-box: refusing '$a' — it weakens container isolation." >&2; exit 1;;
  esac
done
[ "$(id -u)" -eq 0 ] && { echo "claude-box: refusing to run as host root." >&2; exit 1; }

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
  -v "$PWD:/workspace:rw"
  -w /workspace
)

if [ -f "$ENV_FILE" ]; then
  args+=( --env-file "$ENV_FILE" )
else
  echo "claude-box: no env-file at $ENV_FILE — set CLAUDE_CODE_OAUTH_TOKEN or re-run install.sh." >&2
fi

# Host resources (agents/commands/skills), configured by install.sh. Mounted
# read-only at /host-claude/<name>; the container entrypoint merges them over the
# baked state. Paths come from resources.conf (live path, or a copied snapshot).
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

# ----------------------------------------------------------------------------
# PATH hint
# ----------------------------------------------------------------------------
case ":$PATH:" in
  *":$BIN_DIR:"*)
    say ""
    say "Done. Run 'claude-box' from any project directory." ;;
  *)
    say ""
    say "$BIN_DIR is not in your PATH. Add it:"
    say "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc   # or ~/.zshrc"
    say "Then restart your shell and run 'claude-box'." ;;
esac
