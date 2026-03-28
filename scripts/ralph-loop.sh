#!/bin/bash
# Ralph Loop — iterative task execution engine for claude -p
#
# Usage: ralph-loop.sh <compose_project> <workspace_folder>
#
# Reads .agent/tasks.json, runs fresh claude -p per task until all pass.
# Review tasks can dynamically add new tasks — loop continues until zero remain.

set -uo pipefail

COMPOSE_PROJECT_NAME="$1"
WORKSPACE="$2"
AGENT_DIR="$WORKSPACE/.agent"
TASKS_FILE="$AGENT_DIR/tasks.json"
PROGRESS_FILE="$AGENT_DIR/progress.txt"
PROMPT_FILE="$AGENT_DIR/PROMPT.md"
ITERATION=0
CONSECUTIVE_FAILURES=0
LAST_FAILED_TASK=""

if [ ! -f "$TASKS_FILE" ]; then
  echo "ERROR: $TASKS_FILE not found"
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: $PROMPT_FILE not found"
  exit 1
fi

# Initialize progress file if missing
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
fi

# Check if any tasks remain incomplete
has_pending_tasks() {
  python3 -c "
import json, sys
with open('$TASKS_FILE') as f:
    data = json.load(f)
pending = [t for t in data['tasks'] if not t.get('passes', False)]
sys.exit(0 if pending else 1)
" 2>/dev/null
}

# Get next task ID for logging
get_next_task() {
  python3 -c "
import json
with open('$TASKS_FILE') as f:
    data = json.load(f)
pending = [t for t in data['tasks'] if not t.get('passes', False)]
pending.sort(key=lambda t: t.get('priority', 999))
if pending:
    print(f\"{pending[0]['id']}: {pending[0]['title']}\")
else:
    print('NONE')
" 2>/dev/null
}

echo "╭──────────────────────────────────────────╮"
echo "│  Ralph Loop Started                      │"
echo "╰──────────────────────────────────────────╯"
echo "  Compose: $COMPOSE_PROJECT_NAME"
echo "  Workspace: $WORKSPACE"
echo ""

while has_pending_tasks; do
  ITERATION=$((ITERATION + 1))
  NEXT_TASK=$(get_next_task)
  START_TIME=$(date +%s)

  echo "=== Iteration $ITERATION | $NEXT_TASK ==="

  # Run fresh claude -p in devcontainer (reads PROMPT.md via cat inside container)
  OUTPUT=$(COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" devcontainer exec \
    --workspace-folder "$WORKSPACE" -- \
    bash -c 'cd /workspace && claude -p "$(cat .agent/PROMPT.md)" --allowedTools "Edit,Write,Bash,Read,Glob,Grep"' 2>&1)

  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))

  # Log output summary
  echo "$OUTPUT" | grep -v "claude.json\|backup\|restore\|manually" | tail -10
  echo "  Duration: ${DURATION}s"
  echo ""

  # Check if the task we expected is now complete
  CURRENT_TASK=$(get_next_task)
  if [ "$CURRENT_TASK" = "$NEXT_TASK" ]; then
    # Same task still pending — iteration didn't complete it
    CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
    echo "  WARNING: Task not completed ($CONSECUTIVE_FAILURES consecutive failures)"

    if [ "$LAST_FAILED_TASK" = "$NEXT_TASK" ] && [ $CONSECUTIVE_FAILURES -ge 3 ]; then
      echo "  ABORT: Same task failed 3 consecutive times: $NEXT_TASK"
      echo "## ABORT: $NEXT_TASK failed 3x at iteration $ITERATION" >> "$PROGRESS_FILE"
      exit 1
    fi
    LAST_FAILED_TASK="$NEXT_TASK"
  else
    # Task progressed
    CONSECUTIVE_FAILURES=0
    LAST_FAILED_TASK=""
    echo "  Completed: $NEXT_TASK"
  fi
done

echo ""
echo "╭──────────────────────────────────────────╮"
echo "│  Ralph Loop Complete                     │"
echo "╰──────────────────────────────────────────╯"
echo "  Total iterations: $ITERATION"
echo "  All tasks passed."
echo ""
echo "## Completed at $(date -u +%Y-%m-%dT%H:%M:%SZ) after $ITERATION iterations" >> "$PROGRESS_FILE"
