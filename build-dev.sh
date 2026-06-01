#!/bin/bash

# Build the READ-WRITE DEV image.
#
# Unlike build.sh (which uses the default UID 1001 for the read-only audit mode),
# this builds the image under the HOST's uid/gid so Claude Code can write to a
# read-write-mounted project and use the forwarded ssh-agent socket without a uid
# clash. The Dockerfile frees the requested uid/gid if the base image already
# uses it (node:22 ships a `node` user at 1000).
#
# Use with run_claude_dev.sh.

set -e

HOST_UID="$(id -u)"
echo "🔨 Building DEV image claude-code-standalone:dev (USER_ID=${HOST_UID})..."
echo "⚠️  DEV mode mounts your project READ-WRITE and forwards your ssh-agent —"
echo "    Claude Code can edit, commit AND push. Use only on trusted projects."

docker build --build-arg USER_ID="${HOST_UID}" -t claude-code-standalone:dev .

echo "✅ Dev image built: claude-code-standalone:dev"
echo "   Run it from your project directory: /path/to/repo \$ ./run_claude_dev.sh"
