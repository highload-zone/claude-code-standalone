#!/bin/bash

# Back-compat wrapper. The agent-generic launcher is run_agent.sh:
#   ./run_claude.sh [args...]  ==  ./run_agent.sh claude [args...]

exec "$(dirname "$0")/run_agent.sh" claude "$@"