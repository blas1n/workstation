#!/bin/bash
# Usage: review-loop.sh <compose_project> <workspace_folder>
# Runs claude -p review loop inside devcontainer until clean,
# then runs pre-push verification as final gate.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_PROJECT_NAME="$1"
WORKSPACE="$2"
MAX_ITERATIONS=5
ITERATION=0

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  ITERATION=$((ITERATION + 1))
  echo "=== Review Loop Iteration $ITERATION ==="

  OUTPUT=$(COMPOSE_PROJECT_NAME="$COMPOSE_PROJECT_NAME" devcontainer exec \
    --workspace-folder "$WORKSPACE" -- \
    npx -y @anthropic-ai/claude-code -p "코드 리뷰 및 수정을 수행해라. git diff main으로 변경사항을 확인하고:

1. 보안 이슈 (입력 검증, 인증 우회, 하드코딩된 값)
2. 코드 품질 (타입 힌트 누락, 에러 핸들링, 엣지 케이스)
3. 테스트 품질 (실제로 올바른 것을 테스트하는지, 누락된 엣지 케이스)
4. 아키텍처 규칙 (structlog, pydantic-settings, async)
5. 버그, 로직 에러, 미사용 임포트, 스타일 비일관성

이슈를 발견하면 즉시 수정하고, 아래 검증을 모두 통과시켜라:
- uv run ruff check .
- uv run ruff format --check .
- uv run pytest

이슈가 없으면 'NO_ISSUES_FOUND'를 출력해라.
수정했으면 git commit -m 'fix: address review findings (iteration $ITERATION)'
최종적으로 발견한 이슈 수를 'ISSUES_FOUND: N'으로 출력해라." \
    --allowedTools "Edit,Write,Bash,Read,Glob,Grep" 2>&1)

  echo "$OUTPUT" | tail -20

  if echo "$OUTPUT" | grep -q "NO_ISSUES_FOUND"; then
    echo "=== Clean! No issues found at iteration $ITERATION ==="
    break
  fi

  if echo "$OUTPUT" | grep -q "ISSUES_FOUND: 0"; then
    echo "=== Clean! Zero issues at iteration $ITERATION ==="
    break
  fi
done

echo "=== Review loop completed after $ITERATION iterations ==="
echo ""

# Final gate: pre-push verification
echo "=== Running pre-push verification ==="
if "$SCRIPT_DIR/pre-push-verify.sh" "$COMPOSE_PROJECT_NAME" "$WORKSPACE"; then
  echo "=== All clear. Ready to push. ==="
else
  echo "=== Pre-push verification FAILED. Review loop missed something. ==="
  exit 1
fi
