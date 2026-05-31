#!/bin/bash

# MCP Diagnostics Runner
# Runs diagnostics inside the container

set -e

echo "🔍 Running MCP Server Diagnostics..."
echo ""

# Check if container image exists
if ! docker images claude-code-container | grep -q claude-code-container; then
    echo "❌ Container image 'claude-code-container' not found!"
    echo "Please build the container first: ./build.sh"
    exit 1
fi

# Load environment variables from .env if available
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# Build Docker run command
DOCKER_ARGS=(
    "run" "--rm" "-it"
    "--entrypoint" "bash"
    "-e" "CLAUDE_API_KEY=${CLAUDE_API_KEY:-}"
)

# Load additional environment variables from .env
if [ -f .env ]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] || [[ "$line" =~ ^[[:space:]]*# ]] && continue
        var_name=$(echo "$line" | cut -d= -f1)
        [[ -z "$var_name" ]] && continue
        var_value="${!var_name:-}"
        if [ -n "$var_value" ]; then
            DOCKER_ARGS+=("-e" "$var_name=$var_value")
        fi
    done < .env
fi

# Run diagnostics inside container
docker "${DOCKER_ARGS[@]}" claude-code-container -c "/app/diagnose-mcp.sh"

echo ""
echo "📋 Next steps based on results:"
echo "  • If a pre-installed MCP binary is missing: Rebuild container with ./build.sh"
echo "  • If MCP servers fail to start: Check error messages above"
echo "  • If config issues: Review ~/.claude.json in container"
echo "  • For more help: Run ./debug-shell.sh and investigate manually"
