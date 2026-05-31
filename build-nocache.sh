#!/bin/bash

# Claude Security Container - Build and Run Script

set -e

echo "🔨 Building Claude Code Container (no cache)..."
echo "📦 npm CLI versions are pinned in tools/package.json + tools/package-lock.json (npm ci)"

# Build the container. npm tool versions come from the lockfile, not a build arg.
docker build --no-cache -t claude-code-container .

echo "✅ Container built successfully!"

echo "📋 Usage examples:"
echo ""
echo "1. Interactive shell:"
echo "   ./run_claude.sh"
echo ""
echo "Container is ready! Use the scripts above to get started."
