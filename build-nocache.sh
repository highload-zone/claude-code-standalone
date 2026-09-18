#!/bin/bash

# No-cache build of the agent container image(s). Same interface as build.sh:
#   ./build-nocache.sh [claude|codex|opencode ...]

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

echo "Building (no cache): ${targets[*]}"
echo "npm CLI versions are pinned in tools/package.json (+ tools/agents/<agent>) via npm ci"

for a in "${targets[@]}"; do
  echo ""
  echo "==> $IMAGE_BASE:$a"
  docker build --no-cache --target "$a" -t "$IMAGE_BASE:$a" .
  if [ "$a" = "claude" ]; then
    docker tag "$IMAGE_BASE:claude" "$IMAGE_BASE:latest"
  fi
done

echo ""
echo "Built:"
for a in "${targets[@]}"; do echo "  $IMAGE_BASE:$a"; done