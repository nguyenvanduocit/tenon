#!/bin/bash
# Orca automation precheck: pick ONE task from Todo (then Backlog), move its
# board line into ## Doing tagged "auto-dispatched UNCLAIMED", so the agent the
# automation spawns knows exactly which task is its own and a later run never
# picks the same task twice.
# Exit 0 = dispatched (the automation run proceeds), exit 1 = nothing to do (skip).
#
# Test hooks: KANBAN_BOARD=/path/to/copy overrides the board file,
# DRY_RUN=1 prints the pick without editing anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOARD="${KANBAN_BOARD:-$ROOT/.kanban/board.md}"

section_tasks() {
  awk -v sec="## $1" '
    $0 == sec {f=1; next}
    /^## /    {f=0}
    f && /^- \[T-[0-9]+\]/ {print}
  ' "$BOARD"
}

# Board rule: WIP limit = 2 in Doing.
doing="$(section_tasks Doing)"
doing_count=0
[ -n "$doing" ] && doing_count="$(printf '%s\n' "$doing" | wc -l | tr -d ' ')"
if [ "$doing_count" -ge 2 ]; then
  echo "skip: Doing already has $doing_count tasks (WIP limit 2)"
  exit 1
fi

# A dispatch nobody claimed yet blocks new ones: either its agent is still
# starting (racing us) or a run died — piling more unclaimed work on top of
# either is wrong.
if [ -n "$doing" ] && printf '%s\n' "$doing" | grep -q 'auto-dispatched UNCLAIMED'; then
  echo "skip: an auto-dispatched task in Doing is still UNCLAIMED"
  exit 1
fi

# Highest priority first within a section; board order breaks ties.
pick_from() {
  section_tasks "$1" | while IFS= read -r line; do
    case "$line" in
      *"— critical/"*) rank=0 ;;
      *"— high/"*)     rank=1 ;;
      *"— medium/"*)   rank=2 ;;
      *"— low/"*)      rank=3 ;;
      *)               rank=4 ;;
    esac
    printf '%d\t%s\n' "$rank" "$line"
  done | sort -s -k1,1n | head -n 1 | cut -f2-
}

chosen="$(pick_from Todo)"
[ -n "$chosen" ] || chosen="$(pick_from Backlog)"
if [ -z "$chosen" ]; then
  echo "skip: no task in Todo or Backlog"
  exit 1
fi

stamp="$(date '+%Y-%m-%d %H:%M')"
tagged="$chosen · 🤖 auto-dispatched UNCLAIMED $stamp"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo "would dispatch: $chosen"
  exit 0
fi

# ENVIRON instead of awk -v: board lines must arrive byte-for-byte, with no
# backslash-escape processing.
CHOSEN="$chosen" TAGGED="$tagged" awk '
  BEGIN { chosen = ENVIRON["CHOSEN"]; tagged = ENVIRON["TAGGED"] }
  $0 == chosen && !removed { removed = 1; next }
  { print }
  $0 == "## Doing" { print tagged }
' "$BOARD" > "$BOARD.tmp"
mv "$BOARD.tmp" "$BOARD"

echo "dispatched: $(printf '%s' "$chosen" | grep -o 'T-[0-9]*' | head -1)"
