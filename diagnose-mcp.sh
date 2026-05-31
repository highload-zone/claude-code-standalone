#!/bin/bash

echo "========================================="
echo "MCP Server Diagnostics"
echo "========================================="
echo ""

echo "1. Checking pre-installed MCP server binaries (no runtime installs)..."
echo "-----------------------------------"
for bin in mcp-server-sequential-thinking perplexity-mcp codegraph caveman-shrink; do
    if command -v "$bin" &> /dev/null; then
        echo "✅ $bin -> $(command -v "$bin")"
    else
        echo "❌ $bin NOT found in PATH"
    fi
done

echo ""
echo "2. Checking PATH environment..."
echo "-----------------------------------"
echo "Current PATH: $PATH"

echo ""
echo "3. Checking Claude Code MCP configuration..."
echo "-----------------------------------"
if [ -f "$HOME/.claude.json" ]; then
    echo "Claude config exists at $HOME/.claude.json"
    echo ""
    echo "MCP Servers configured:"
    cat "$HOME/.claude.json" | jq -r '.projects["/workspace"].mcpServers | keys[]' 2>&1 || echo "Failed to parse JSON"
    echo ""
    echo "Full MCP server configuration:"
    cat "$HOME/.claude.json" | jq '.projects["/workspace"].mcpServers' 2>&1 || echo "Failed to get MCP config"
else
    echo "❌ $HOME/.claude.json not found"
fi

echo ""
echo "4. Checking file permissions..."
echo "-----------------------------------"
echo "Current user: $(whoami)"
echo "Home directory: $HOME"

echo ""
echo "========================================="
echo "Diagnostics Complete"
echo "========================================="
