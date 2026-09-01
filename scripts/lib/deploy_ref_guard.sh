#!/usr/bin/env bash
# deploy_ref_guard.sh — autodeploy 는 origin/main 만 배포한다.
#
# 명제 하나: **빌드될 워킹트리의 HEAD 가 origin/main 과 같은 커밋인가.**
#
# 왜 이게 필요한가 (실측 2026-09-01) — 배포 대상 디렉터리는 사람이 매일 쓰는
# 작업 디렉터리와 **같은 경로**다(``WORK=~/Works/<name>/main``). 거기서 브랜치를
# 만들어 커밋하면 폴러가 그 브랜치를 빌드해 prod 에 올린다:
#
#   * ``LOCAL=$(git rev-parse HEAD)`` 는 브랜치 커밋을 읽는다
#   * ``LOCAL != REMOTE`` 라 needs_merge=true
#   * ``git merge origin/main --ff-only`` 는 **성공한다** — 브랜치가 main 보다
#     앞서 있으니 "Already up to date" 다. 즉 이 병합은 가드가 아니라 no-op 이다
#   * 그 워킹트리가 빌드되고 ``GIT_SHA`` 에 브랜치 커밋이 박힌다
#
# 실제로 PR 이 열려 있고 CI 가 한 번 실패한 코드가 11분간 2분마다 prod 에
# 재배포됐고, 로그는 내내 ``Deploying 40d811a...`` 라고 **다른 커밋**을 적었다.
#
# ⚠️ 추적되지 않는 파일로는 막지 않는다. ``$WORK`` 에는 ``.vercel/`` · 백업 ``.env``
# 같은 잔여물이 상시 있고, 예전에 미커밋 파일이 autodeploy 를 **영구 차단**한
# 함정이 있었다. 벽돌이 되는 가드는 가드가 아니다.

# deploy_ref_guard_reason <workdir> <expected_sha>
#   안전하면 아무것도 출력하지 않는다(빈 문자열).
#   불안전하면 사람이 바로 행동할 수 있는 사유 한 줄을 출력한다.
deploy_ref_guard_reason() {
  local workdir="$1" expected="$2" head ref

  if [ -z "$expected" ]; then
    echo "expected origin/main sha is empty — refusing to deploy an unknown ref"
    return 0
  fi

  head=$(git -C "$workdir" rev-parse HEAD 2>/dev/null)
  if [ -z "$head" ]; then
    echo "cannot read HEAD in ${workdir} — refusing to deploy"
    return 0
  fi

  [ "$head" = "$expected" ] && return 0   # 안전 — 출력 없음

  # 사유는 **행동 가능**해야 한다: 무엇이 체크아웃돼 있고 무엇을 기대했는지.
  ref=$(git -C "$workdir" symbolic-ref --short -q HEAD 2>/dev/null) || ref=""
  if [ -n "$ref" ]; then
    echo "${workdir} is on branch '${ref}' at ${head:0:7}, not origin/main ${expected:0:7}"
  else
    echo "${workdir} is on a detached HEAD at ${head:0:7}, not origin/main ${expected:0:7}"
  fi
}

# deploy_ref_guard_dirty_tracked <workdir>
#   추적 중인 파일에 수정이 있으면 그 개수를 출력한다(없으면 빈 문자열).
#   ⚠️ 배포를 **막지 않는다** — 로그에 남겨 보이게만 한다.
deploy_ref_guard_dirty_tracked() {
  local n
  n=$(git -C "$1" diff --name-only 2>/dev/null | wc -l | tr -d '[:space:]')
  [ "${n:-0}" -gt 0 ] && echo "$n"
}
