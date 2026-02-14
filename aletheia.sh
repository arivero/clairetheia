#!/usr/bin/env bash
# Launch an interactive Aletheia session via a supported CLI client.
# Usage:  ./aletheia.sh                    # opens session, paste problem
#         ./aletheia.sh problem.md         # pre-loads problem
#         ./aletheia.sh problem.md claude  # use Claude Code instead
# Env:    ALETHEIA_PROMPT_MODE=full|append (default: full)
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
CLI="${2:-codex}"
ORCHESTRATOR="$DIR/orchestrator.md"
PROMPT_MODE="${ALETHEIA_PROMPT_MODE:-full}"
PROMPT_TEXT="$(cat "$ORCHESTRATOR")"

build_cmd() {
  case "$CLI" in
    codex)
      if [[ "$PROMPT_MODE" == "append" ]]; then
        CMD=(codex -c "developer_instructions=$PROMPT_TEXT")
      else
        CMD=(codex -c "model_instructions_file=$ORCHESTRATOR")
      fi
      ;;
    claude)
      if [[ "$PROMPT_MODE" == "append" ]]; then
        CMD=(claude --append-system-prompt "$PROMPT_TEXT")
      else
        CMD=(claude --system-prompt "$PROMPT_TEXT")
      fi
      ;;
    *)
      echo "Warning: unknown client '$CLI'; launching without prompt injection."
      CMD=("$CLI")
      ;;
  esac
}

build_cmd

if [[ -n "${1:-}" && -f "${1:-}" ]]; then
  echo "Launching Aletheia with problem: $1"
  "${CMD[@]}" "$(cat "$1")"
else
  echo "Launching Aletheia interactively with '$CLI' ($PROMPT_MODE prompt mode)."
  "${CMD[@]}"
fi
