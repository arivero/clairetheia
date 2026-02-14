#!/usr/bin/env bash
# Launch an interactive Aletheia session via Codex CLI.
# Usage:  ./aletheia.sh                    # opens session, paste problem
#         ./aletheia.sh problem.md         # pre-loads problem
#         ./aletheia.sh problem.md claude  # use Claude Code instead
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${2:-codex}"
ORCHESTRATOR="$DIR/orchestrator.md"

if [[ -n "${1:-}" && -f "${1:-}" ]]; then
  echo "Launching Aletheia with problem: $1"
  $CLI --system-prompt "$ORCHESTRATOR" < "$1"
else
  echo "Launching Aletheia interactively. Paste your problem once the session opens."
  $CLI --system-prompt "$ORCHESTRATOR"
fi
