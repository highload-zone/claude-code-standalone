#!/bin/bash

# MCP diagnostics inside an agent image. AGENT is baked per image; the MCP binary
# set is shared, but the rendered config location differs per agent.

AGENT="${AGENT:-claude}"

echo "========================================="
echo "MCP Server Diagnostics (agent: $AGENT)"
echo "========================================="
echo ""

echo "1. Checking pre-installed MCP server binaries (no runtime installs)..."
echo "-----------------------------------"
for bin in mcp-server-sequential-thinking perplexity-mcp codegraph caveman-shrink codebase-memory-mcp; do
    if command -v "$bin" &> /dev/null; then
        echo "✅ $bin -> $(command -v "$bin")"
    else
        echo "❌ $bin NOT found in PATH"
    fi
done

echo ""
echo "2. Checking agent CLI..."
echo "-----------------------------------"
if command -v "$AGENT" &> /dev/null; then
    echo "✅ $AGENT -> $(command -v "$AGENT") ($("$AGENT" --version 2>/dev/null | head -1))"
else
    echo "❌ $AGENT NOT found in PATH"
fi

echo ""
echo "3. Checking PATH environment..."
echo "-----------------------------------"
echo "Current PATH: $PATH"

echo ""
echo "4. Checking MCP configuration for '$AGENT'..."
echo "-----------------------------------"
case "$AGENT" in
  claude)
    cfg="$HOME/.claude.json"
    if [ -f "$cfg" ]; then
      echo "Claude config: $cfg"
      jq -r '.projects["/workspace/project"].mcpServers | keys[]' "$cfg" 2>&1 || echo "Failed to parse JSON"
    else
      echo "❌ $cfg not found"
    fi
    ;;
  codex)
    cfg="$HOME/.codex/config.toml"
    if [ -f "$cfg" ]; then
      echo "Codex config: $cfg"
      grep -E '^\[mcp_servers\.' "$cfg" || echo "(no [mcp_servers.*] sections)"
    else
      echo "❌ $cfg not found"
    fi
    ;;
  opencode)
    cfg="$HOME/.config/opencode/opencode.json"
    if [ -f "$cfg" ]; then
      echo "OpenCode config: $cfg"
      jq -r '.mcp | keys[]' "$cfg" 2>&1 || echo "Failed to parse JSON"
    else
      echo "❌ $cfg not found"
    fi
    ;;
esac

echo ""
echo "5. Checking file permissions..."
echo "-----------------------------------"
echo "Current user: $(whoami)"
echo "Home directory: $HOME"

echo ""
echo "========================================="
echo "Diagnostics Complete"
echo "========================================="