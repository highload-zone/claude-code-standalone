#!/bin/bash

# Interactive Claude Code Shell
set -e

# Footgun guards — catch ACCIDENTAL misconfig only. On a root-Docker host this is
# NOT a boundary against a hostile operator (docker run == host root); see SECURITY.md.
for a in "$@"; do
  case "$a" in
    --privileged|--pid=host|--network=host|--cap-add*|*docker.sock*)
      echo "❌ Refusing: '$a' weakens isolation and is not accepted by this script." >&2
      exit 1;;
  esac
done
[ "$(id -u)" -eq 0 ] && { echo "❌ Refusing to run as root on the host — use your normal user." >&2; exit 1; }

# Collect all arguments to pass to Claude
CLAUDE_ARGS=("$@")

# Fixed paths - no argument parsing needed
INPUT_DIR="$(pwd)"
DATA_DIR="workspace/data"

# Load environment variables from .env for use in this script
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    echo "⚠️  Warning: CLAUDE_CODE_OAUTH_TOKEN not set. Claude Code may not work properly."
    echo "   Set it with: export CLAUDE_CODE_OAUTH_TOKEN='your-oauth-token'"
    echo ""
fi

# Create reports directory
mkdir -p reports

# Build Docker run command with enhanced security
DOCKER_ARGS=(
    "run" "-it" "--rm"
    # Security: Drop all capabilities
    "--cap-drop=ALL"
    # Security: Prevent privilege escalation
    "--security-opt=no-new-privileges:true"
    # Security: Non-executable temp filesystem
    "--tmpfs" "/tmp:noexec,nosuid,size=100m"
    "--tmpfs" "/workspace/temp:noexec,nosuid,size=2g"
    # Security: Limit PIDs to prevent fork bombs
    "--pids-limit=100"
    # Security: Restrict network to external only (no host network access)
    "--network=bridge"
    "--add-host=host.docker.internal:127.0.0.1"
    # Volume mounts
    "-v" "$INPUT_DIR:/workspace/input:ro"
    "-v" "$(pwd)/reports:/workspace/output:rw"
    # Environment variables
    "-e" "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-}"
)

# Load and pass all environment variables from .env file if it exists
if [ -f .env ]; then
    echo "📝 Loading environment variables from .env"

    # Read .env file and pass all non-empty, non-comment lines to Docker
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Extract variable name (before =)
        var_name=$(echo "$line" | cut -d= -f1)

        # Skip if variable name is empty
        [[ -z "$var_name" ]] && continue

        # Get the actual value from current environment (already sourced or exported)
        var_value="${!var_name:-}"

        # Pass to Docker if value is set
        if [ -n "$var_value" ]; then
            DOCKER_ARGS+=("-e" "$var_name=$var_value")
            echo "  → Passing $var_name"
        fi
    done < .env
fi

# Add data directory if it exists
if [ -d "$DATA_DIR" ]; then
    DOCKER_ARGS+=("-v" "$DATA_DIR:/workspace/data:ro")
    echo "📚 Using reference data from: $DATA_DIR"
fi

echo "🚀 Starting Claude Code in interactive mode..."
echo "📁 Input: $INPUT_DIR"
echo "📊 Output: $(pwd)/reports"
if [[ ${#CLAUDE_ARGS[@]} -gt 0 ]]; then
    echo "🔧 Claude options: ${CLAUDE_ARGS[*]}"
fi
echo ""

# Run the container with Claude Code in interactive mode, passing through any additional arguments
docker "${DOCKER_ARGS[@]}" claude-code-container "${CLAUDE_ARGS[@]}"
