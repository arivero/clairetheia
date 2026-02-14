#!/usr/bin/env bash
# ────────────────────────────────────────────────────────────────
# Aletheia-style GVR loop for Codex CLI
# Usage:  ./run.sh <problem_file> [max_rounds] [cli_command]
# Example: ./run.sh problem.md 5 codex
# ────────────────────────────────────────────────────────────────
set -euo pipefail

PROBLEM_FILE="${1:?Usage: $0 <problem_file> [max_rounds] [cli_cmd]}"
MAX_ROUNDS="${2:-3}"
CLI="${3:-codex}"                 # swap for: claude, gemini, etc.
DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"

trap 'echo "[aletheia] work dir preserved at $WORK"' EXIT

PROBLEM="$(cat "$PROBLEM_FILE")"

# ── helpers ─────────────────────────────────────────────────────
call_model() {
  # $1 = system prompt file, $2 = user content (stdin-safe)
  printf '%s\n\n---\n\n%s' "$(cat "$1")" "$2" | $CLI
}

# ── ROUND 0: Generate ──────────────────────────────────────────
echo "═══ [aletheia] Round 0 — GENERATE ═══"
SOLUTION="$(call_model "$DIR/prompts/generator.md" "$PROBLEM")"
echo "$SOLUTION" | tee "$WORK/solution_0.md"

if echo "$SOLUTION" | grep -q "STATUS: STUCK"; then
  echo "[aletheia] Generator is stuck. Aborting."
  exit 1
fi

# ── LOOP: Verify → Revise ──────────────────────────────────────
for ((round=1; round<=MAX_ROUNDS; round++)); do

  # ── Verify ────────────────────────────────────────────────────
  echo ""
  echo "═══ [aletheia] Round $round/$MAX_ROUNDS — VERIFY ═══"

  # Build verifier input: problem + solution (NO generator chain-of-thought)
  VERIFIER_INPUT="$(sed "s|{PROBLEM}|$PROBLEM|" "$DIR/prompts/verifier.md")
$SOLUTION"

  FEEDBACK="$(printf '%s' "$VERIFIER_INPUT" | $CLI)"
  echo "$FEEDBACK" | tee "$WORK/feedback_$round.md"

  # ── Check verdict ─────────────────────────────────────────────
  VERDICT="$(echo "$FEEDBACK" | grep -oP 'VERDICT:\s*\K\S+' | tail -1 || true)"
  echo "[aletheia] Verdict: ${VERDICT:-UNKNOWN}"

  case "$VERDICT" in
    PASS|MINOR_ISSUES)
      echo "[aletheia] ✓ Solution accepted after $round verification round(s)."
      cp "$WORK/solution_$((round-1)).md" "$WORK/final_solution.md"
      echo ""
      echo "═══ FINAL SOLUTION ═══"
      cat "$WORK/final_solution.md"
      exit 0
      ;;
    FAIL)
      echo "[aletheia] ✗ Verifier says approach is fundamentally flawed."
      if ((round >= MAX_ROUNDS)); then
        echo "[aletheia] Max rounds reached. No accepted solution."
        exit 1
      fi
      echo "[aletheia] Attempting fresh generation via Reviser (FAIL path)..."
      ;;
    REVISE|*)
      echo "[aletheia] → Revising..."
      ;;
  esac

  # ── Revise ────────────────────────────────────────────────────
  echo ""
  echo "═══ [aletheia] Round $round/$MAX_ROUNDS — REVISE ═══"

  REVISER_INPUT="$(sed -e "s|{PROBLEM}|$PROBLEM|" \
                        -e "s|{SOLUTION}|$SOLUTION|" \
                        "$DIR/prompts/reviser.md")
$FEEDBACK"

  SOLUTION="$(printf '%s' "$REVISER_INPUT" | $CLI)"
  echo "$SOLUTION" | tee "$WORK/solution_$round.md"

  if echo "$SOLUTION" | grep -q "STATUS: STUCK"; then
    echo "[aletheia] Reviser is stuck. Aborting."
    exit 1
  fi
done

echo "[aletheia] Max rounds ($MAX_ROUNDS) exhausted without PASS verdict."
echo "[aletheia] Best attempt saved at: $WORK/solution_$MAX_ROUNDS.md"
exit 1
