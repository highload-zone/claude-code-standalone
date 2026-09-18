#!/bin/bash

# MCP diagnostics runner. Runs diagnose-mcp.sh inside an agent image.
#
#   ./run-diagnostics.sh            # claude image
#   ./run-diagnostics.sh codex
#   ./run-diagnostics.sh opencode

set -e

AGENT="${1:-claude}"
case "$AGENT" in claude|codex|opencode) ;; *) echo "usage: $0 [claude|codex|opencode]" >&2; exit 2;; esac

IMAGE_BASE="${AGENT_IMAGE_BASE:-claude-code-standalone}"
IMAGE="${AGENT_IMAGE:-$IMAGE_BASE:$AGENT}"

echo "🔍 Running MCP Server Diagnostics for '$AGENT'..."
echo ""

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "❌ Container image '$IMAGE' not found!"
    echo "Please build the container first: ./build.sh $AGENT"
    exit 1
fi

# Load environment variables from .env if available
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

DOCKER_ARGS=(
    "run" "--rm" "-it"
    "--entrypoint" "bash"
    "-e" "AGENT=$AGENT"
)

# Pass the runtime env vars the agents need.
for n in CLAUDE_CODE_OAUTH_TOKEN CODEX_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY CONTEXT7_API_KEY PERPLEXITY_API_KEY; do
    v="${!n:-}"
    [ -n "$v" ] && DOCKER_ARGS+=("-e" "$n=$v")
done

docker "${DOCKER_ARGS[@]}" "$IMAGE" -c "/app/diagnose-mcp.sh"

echo ""
echo " Next steps based on results:"
echo "  • If a pre-installed MCP binary is missing: Rebuild container with ./build.sh $AGENT"
echo "  • If MCP servers fail to start: Check error messages above"
echo "  • If config issues: inspect the per-agent config shown above"
echo "  • For more help: Run ./debug-shell.sh $AGENT and investigate manually"