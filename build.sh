#!/bin/bash

# Claude Security Container - Build and Run Script

set -e

echo "🔨 Building Claude Code Container..."
echo "📦 npm CLI versions are pinned in tools/package.json + tools/package-lock.json (npm ci)"

# Build the container. npm tool versions come from the lockfile, not a build arg.
docker build -t claude-code-container .

echo "✅ Container built successfully!"

# Create output directory if it doesn't exist

echo "📋 Usage examples:"
echo ""
echo "1. Interactive shell:"
echo "   ./run_claude.sh"
echo ""
echo "2. Change a pinned npm CLI version:"
echo "   edit tools/package.json, then regenerate the lockfile inside node:22:"
echo "   docker run --rm -v \"\$PWD/tools:/w\" -w /w node:22-trixie-slim npm install --package-lock-only"
echo ""
echo "Container is ready! Use the scripts above to get started."
