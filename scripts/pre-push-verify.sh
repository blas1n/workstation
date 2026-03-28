#!/bin/bash
# Usage: pre-push-verify.sh <compose_project> <workspace_folder>
# Runs lint + format + tests inside devcontainer before push.
# Exit code 0 = safe to push, non-zero = fix issues first.

set -uo pipefail

COMPOSE_PROJECT_NAME="$1"
WORKSPACE="$2"
PROJECT_NAME=$(basename "$(dirname "$(dirname "$WORKSPACE")")")

echo "🔍 Pre-push verification: $PROJECT_NAME"
echo "   Compose: $COMPOSE_PROJECT_NAME"
echo "   Workspace: $WORKSPACE"
echo ""

run_in_dc() {
  COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" devcontainer exec \
    --workspace-folder "$WORKSPACE" -- bash -c "$1" 2>&1
}

FAILED=0

# 1. Ruff lint
echo "=== [1/4] Ruff lint ==="
if OUTPUT=$(run_in_dc 'cd /workspace && uv run ruff check .'); then
  echo "✅ Passed"
else
  echo "❌ Failed"
  echo "$OUTPUT" | tail -10
  FAILED=1
fi
echo ""

# 2. Ruff format
echo "=== [2/4] Ruff format ==="
if OUTPUT=$(run_in_dc 'cd /workspace && uv run ruff format --check .'); then
  echo "✅ Passed"
else
  echo "❌ Failed — run 'uv run ruff format .' to fix"
  echo "$OUTPUT" | tail -10
  FAILED=1
fi
echo ""

# 3. Tests
echo "=== [3/4] Tests ==="
if OUTPUT=$(run_in_dc 'cd /workspace && uv run pytest --tb=line -q 2>&1'); then
  echo "✅ Passed"
  echo "$OUTPUT" | tail -3
else
  echo "❌ Failed"
  echo "$OUTPUT" | tail -15
  FAILED=1
fi
echo ""

# 4. Commit author check
echo "=== [4/4] Commit author ==="
EXPECTED_EMAIL="qazasa123@gmail.com"
BAD_AUTHORS=$(cd "$WORKSPACE" && git log main..HEAD --format="%ae" 2>/dev/null | grep -v "$EXPECTED_EMAIL" | sort -u)
if [ -z "$BAD_AUTHORS" ]; then
  echo "✅ All commits by $EXPECTED_EMAIL"
else
  echo "❌ Wrong author found: $BAD_AUTHORS"
  FAILED=1
fi
echo ""

# Result
if [ $FAILED -eq 0 ]; then
  echo "✅ All checks passed. Safe to push."
  exit 0
else
  echo "❌ Some checks failed. Fix before pushing."
  exit 1
fi
