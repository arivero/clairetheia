#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# Aletheia-style GVR loop for CLI agents
# Usage:   ./run.sh <problem_file> [max_rounds] [client] [mode]
# Example: ./run.sh problem.md 5 codex
# Clients:
#   codex  -> runs `codex exec -`
#   claude -> runs `claude -p`
#   other  -> runs client string as provided (split on spaces)
# Modes:
#   sequential (default) -> run problem loops one after another
#   parallel             -> run problem loops concurrently
#
# Multi-problem input:
#   Use a separator line containing only `===` between problems.
# ────────────────────────────────────────────────────────────────
set -euo pipefail

PROBLEM_FILE="${1:?Usage: $0 <problem_file> [max_rounds] [client] [mode]}"
MAX_ROUNDS="${2:-3}"
CLIENT="${3:-codex}"
MODE="${4:-sequential}"
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
PROBLEMS_DIR="$WORK/problems"
PROBLEM_FILES=()

trap 'echo "[aletheia] work dir preserved at $WORK"' EXIT

if [[ ! -f "$PROBLEM_FILE" ]]; then
  echo "[aletheia] Problem file not found: $PROBLEM_FILE"
  exit 1
fi

case "$MODE" in
  sequential|parallel) ;;
  *)
    echo "[aletheia] Invalid mode '$MODE' (use: sequential|parallel)"
    exit 1
    ;;
esac

# ── helpers ─────────────────────────────────────────────────────
build_client_cmd() {
  local spec="$1"
  case "$spec" in
    codex)
      CLIENT_CMD=(codex exec -)
      ;;
    claude)
      CLIENT_CMD=(claude -p)
      ;;
    *)
      read -r -a CLIENT_CMD <<< "$spec"
      ;;
  esac

  if [[ "${#CLIENT_CMD[@]}" -eq 0 ]]; then
    echo "[aletheia] Invalid client command: '$spec'"
    exit 1
  fi
}

call_client() {
  # $1 = full payload to send to client
  printf '%s' "$1" | "${CLIENT_CMD[@]}"
}

call_model() {
  # $1 = system prompt file, $2 = user content (stdin-safe)
  printf '%s\n\n---\n\n%s' "$(cat "$1")" "$2" | "${CLIENT_CMD[@]}"
}

build_verifier_input() {
  # $1 = problem text, $2 = candidate solution
  local problem="$1"
  local solution="$2"
  local template
  template="$(cat "$DIR/prompts/verifier.md")"
  template="${template//\{PROBLEM\}/$problem}"
  printf '%s\n%s' "$template" "$solution"
}

build_reviser_input() {
  # $1 = problem text, $2 = previous solution, $3 = verifier feedback
  local problem="$1"
  local solution="$2"
  local feedback="$3"
  local template
  template="$(cat "$DIR/prompts/reviser.md")"
  template="${template//\{PROBLEM\}/$problem}"
  template="${template//\{SOLUTION\}/$solution}"
  printf '%s\n%s' "$template" "$feedback"
}

extract_verdict() {
  # $1 = verifier output
  printf '%s\n' "$1" \
    | grep -oE 'VERDICT:[[:space:]]*[A-Z_]+' \
    | tail -1 \
    | sed -E 's/VERDICT:[[:space:]]*//'
}

split_problems() {
  mkdir -p "$PROBLEMS_DIR"
  awk -v out_dir="$PROBLEMS_DIR" '
    function flush_segment() {
      if (segment ~ /[^[:space:]]/) {
        file = sprintf("%s/problem_%03d.md", out_dir, count++)
        printf "%s", segment > file
        close(file)
      }
      segment = ""
    }
    /^[[:space:]]*={3,}[[:space:]]*$/ {
      flush_segment()
      next
    }
    {
      segment = segment $0 ORS
    }
    END {
      flush_segment()
    }
  ' "$PROBLEM_FILE"

  while IFS= read -r path; do
    PROBLEM_FILES+=("$path")
  done < <(find "$PROBLEMS_DIR" -type f -name 'problem_*.md' | sort)

  if [[ "${#PROBLEM_FILES[@]}" -eq 0 ]]; then
    echo "[aletheia] No problems found in input file."
    exit 1
  fi
}

run_single_problem() {
  # $1 = problem index, $2 = path to problem text
  local problem_index="$1"
  local problem_path="$2"
  local tag="[aletheia:p${problem_index}]"
  local problem_work="$WORK/problem_${problem_index}"
  local problem solution feedback verdict verifier_input reviser_input round

  mkdir -p "$problem_work"
  problem="$(cat "$problem_path")"

  echo ""
  echo "═══ ${tag} Round 0 — GENERATE ═══"
  solution="$(call_model "$DIR/prompts/generator.md" "$problem")"
  echo "$solution" | tee "$problem_work/solution_0.md"

  if echo "$solution" | grep -q "STATUS: STUCK"; then
    echo "${tag} Generator is stuck. Aborting this problem."
    return 1
  fi

  for ((round=1; round<=MAX_ROUNDS; round++)); do
    echo ""
    echo "═══ ${tag} Round $round/$MAX_ROUNDS — VERIFY ═══"

    verifier_input="$(build_verifier_input "$problem" "$solution")"
    feedback="$(call_client "$verifier_input")"
    echo "$feedback" | tee "$problem_work/feedback_$round.md"

    verdict="$(extract_verdict "$feedback" || true)"
    echo "${tag} Verdict: ${verdict:-UNKNOWN}"

    case "${verdict:-UNKNOWN}" in
      PASS|MINOR_ISSUES)
        echo "${tag} ✓ Accepted after $round verification round(s)."
        echo "$solution" > "$problem_work/final_solution.md"
        echo ""
        echo "═══ FINAL SOLUTION (problem $problem_index) ═══"
        cat "$problem_work/final_solution.md"
        return 0
        ;;
      FAIL)
        echo "${tag} ✗ Fundamentally flawed. Starting fresh generation."
        if ((round >= MAX_ROUNDS)); then
          echo "${tag} Max rounds reached. No accepted solution."
          return 1
        fi
        solution="$(call_model "$DIR/prompts/generator.md" "$problem")"
        echo "$solution" | tee "$problem_work/solution_regen_$round.md"
        if echo "$solution" | grep -q "STATUS: STUCK"; then
          echo "${tag} Fresh generator pass is stuck. Aborting this problem."
          return 1
        fi
        continue
        ;;
      REVISE|*)
        echo "${tag} → Revising..."
        ;;
    esac

    echo ""
    echo "═══ ${tag} Round $round/$MAX_ROUNDS — REVISE ═══"

    reviser_input="$(build_reviser_input "$problem" "$solution" "$feedback")"
    solution="$(call_client "$reviser_input")"
    echo "$solution" | tee "$problem_work/solution_$round.md"

    if echo "$solution" | grep -q "STATUS: STUCK"; then
      echo "${tag} Reviser is stuck. Aborting this problem."
      return 1
    fi
  done

  echo "${tag} Max rounds ($MAX_ROUNDS) exhausted without PASS verdict."
  echo "${tag} Best attempt saved at: $problem_work"
  return 1
}

run_all_problems() {
  local failures=0
  local index=1
  local problem_path

  if [[ "$MODE" == "parallel" && "${#PROBLEM_FILES[@]}" -gt 1 ]]; then
    local pids=()
    echo "[aletheia] Running ${#PROBLEM_FILES[@]} problems in parallel."
    for problem_path in "${PROBLEM_FILES[@]}"; do
      run_single_problem "$index" "$problem_path" &
      pids+=("$!")
      index=$((index + 1))
    done
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failures=$((failures + 1))
      fi
    done
  else
    echo "[aletheia] Running ${#PROBLEM_FILES[@]} problems sequentially."
    for problem_path in "${PROBLEM_FILES[@]}"; do
      if ! run_single_problem "$index" "$problem_path"; then
        failures=$((failures + 1))
      fi
      index=$((index + 1))
    done
  fi

  if ((failures > 0)); then
    echo "[aletheia] Completed with $failures failed problem loop(s)."
    return 1
  fi

  echo "[aletheia] Completed all problem loops successfully."
  return 0
}

build_client_cmd "$CLIENT"
echo "[aletheia] client command: ${CLIENT_CMD[*]}"
split_problems
run_all_problems
