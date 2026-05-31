#!/usr/bin/env bash
set -euo pipefail

# ABOUTME: Installs MCP servers into claude-config.json with environment variable substitution

echo "Installing MCP servers..."

CLAUDE_CONFIG="$HOME/.claude.json"
MCP_SERVERS_FILE="/app/mcp-servers.json"
MCP_OPTIONAL_FILE="/app/mcp-servers-optional.json"

if [ ! -f "$CLAUDE_CONFIG" ]; then
    echo "❌ Error: Claude config not found at $CLAUDE_CONFIG"
    exit 1
fi

if [ ! -f "$MCP_SERVERS_FILE" ]; then
    echo "❌ Error: MCP servers file not found at $MCP_SERVERS_FILE"
    exit 1
fi

# Function to substitute environment variables in JSON
substitute_env_vars() {
    local json_content="$1"
    local result="$json_content"

    # Find all ${VAR} patterns and substitute them
    while [[ "$result" =~ \$\{([^}]+)\} ]]; do
        var_name="${BASH_REMATCH[1]}"
        var_value="${!var_name:-}"

        if [ -z "$var_value" ]; then
            echo "⚠️  Warning: Environment variable $var_name not set, skipping servers that require it"
            return 1
        fi

        result="${result//\$\{$var_name\}/$var_value}"
    done

    echo "$result"
}

# Read base MCP servers (always installed)
echo "📦 Installing base MCP servers..."
BASE_SERVERS=$(cat "$MCP_SERVERS_FILE")

# Start with base servers
MERGED_SERVERS="$BASE_SERVERS"

# Process optional servers if file exists
if [ -f "$MCP_OPTIONAL_FILE" ]; then
    echo "📦 Processing optional MCP servers..."

    # Read optional servers file
    OPTIONAL_CONTENT=$(cat "$MCP_OPTIONAL_FILE")

    # Parse each server from optional file
    SERVER_NAMES=$(echo "$OPTIONAL_CONTENT" | jq -r 'keys[]')

    for server_name in $SERVER_NAMES; do
        SERVER_CONFIG=$(echo "$OPTIONAL_CONTENT" | jq -c ".[\"$server_name\"]")

        # Try to substitute environment variables
        if SUBSTITUTED=$(substitute_env_vars "$SERVER_CONFIG" 2>/dev/null); then
            echo "  ✓ Adding $server_name"
            # Merge this server into the base servers
            MERGED_SERVERS=$(echo "$MERGED_SERVERS" | jq --arg name "$server_name" --argjson config "$SUBSTITUTED" '. + {($name): $config}')
        else
            echo "  ⊘ Skipping $server_name (missing environment variables)"
        fi
    done
fi

# Update claude-config.json with merged MCP servers
echo "📝 Updating Claude configuration..."

# Use jq to update the mcpServers field in the /workspace project
jq --argjson servers "$MERGED_SERVERS" \
   '.projects["/workspace"].mcpServers = $servers' \
   "$CLAUDE_CONFIG" > "${CLAUDE_CONFIG}.tmp"

mv "${CLAUDE_CONFIG}.tmp" "$CLAUDE_CONFIG"

echo "✅ MCP server installation complete"
echo ""
echo "Installed servers:"
jq -r '.projects["/workspace"].mcpServers | keys[]' "$CLAUDE_CONFIG" | sed 's/^/  - /'
