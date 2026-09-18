#!/bin/bash

# Build the agent container image(s). One Dockerfile, three targets.
#
#   ./build.sh                 # all three
#   ./build.sh codex           # just codex
#   ./build.sh claude codex    # a subset
#
# Tags: claude-code-standalone:<agent>; :latest is an alias for the claude image
# (kept so existing `:latest` users and the claude-box installer keep working).

set -e

IMAGE_BASE="${AGENT_IMAGE_BASE:-claude-code-standalone}"
ALL=(claude codex opencode)

targets=("$@")
[ "${#targets[@]}" -eq 0 ] && targets=("${ALL[@]}")

for a in "${targets[@]}"; do
  case "$a" in claude|codex|opencode) ;;
    *) echo "unknown target '$a' (expected claude|codex|opencode)" >&2; exit 2;;
  esac
done

echo "Building: ${targets[*]}"
echo "npm CLI versions are pinned in tools/package.json (+ tools/agents/<agent>) via npm ci"

for a in "${targets[@]}"; do
  echo ""
  echo "==> $IMAGE_BASE:$a"
  docker build --target "$a" -t "$IMAGE_BASE:$a" .
  if [ "$a" = "claude" ]; then
    docker tag "$IMAGE_BASE:claude" "$IMAGE_BASE:latest"
  fi
done

echo ""
echo "Built:"
for a in "${targets[@]}"; do echo "  $IMAGE_BASE:$a"; done
echo ""
echo "Run:"
echo "  ./run_agent.sh claude          # or codex / opencode"
echo "  docker run --rm <image> mcp list   # forwards to '<agent> mcp list'"