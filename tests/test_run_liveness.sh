#!/usr/bin/env bash
# test_run_liveness.sh — the autodeploy self-disruption guard must protect a run
# whose agent loop is ALIVE, using the app's OWN liveness contract.
#
# Ground truth (bsvibe-app):
#   agent_worker._stale_claim_lease_s = 2 x settings.executor_task_timeout_s
#     (default 3600s -> 7200s lease)
#   _drive_loop refreshes ExecutionRun.claimed_at at each TURN BOUNDARY only —
#     "a single long turn running a full test suite goes the WHOLE turn without
#      refreshing its claim."
#
# Regression: 2026-08-18 run abe9e2b9. The guard logged "1 executor run in
# flight — deferring" at 14:48:57 KST and then force-recreated backend+worker at
# 14:51:01 under that same live run, which lost its tools and wedged. Cause: the
# guard judged liveness by `updated_at` within 3 MINUTES, while that run's own
# verification step (`uv run pytest -ra`, 353s) left the DB untouched for 8m39s.

set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/run_liveness.sh"
# shellcheck source=/dev/null
source "$LIB"

PGC="bsvibe-liveness-test-$$"
cleanup() { docker rm -f "$PGC" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== 임시 Postgres 기동 =="
docker run --rm -d --name "$PGC" -e POSTGRES_PASSWORD=t -e POSTGRES_USER=t -e POSTGRES_DB=t \
  postgres:16-alpine >/dev/null
# ⚠️ 2026-09-04. 원래는 `pg_isready && break` 만 돌고 **루프가 다 소진돼도 그대로
# 진행**했다. 그래서 준비 실패가 성공과 구분되지 않았고, 실제 증상은 본문 케이스가
# 전부 빨개지면서 `database "t" does not exist` · `No such file or directory` 를
# 뱉는 것이었다 — **원인을 엉뚱한 곳(내 변경)으로 가리킨다.**
#
# ⭐ 그리고 `pg_isready` 는 이 이미지에서 **너무 일찍 성공한다**: postgres 공식
#    이미지는 initdb 동안 **임시 서버**를 띄웠다가 껐다 다시 켠다. 그 사이 창에서
#    pg_isready 가 초록을 준다. 그래서 준비 판정을 **실제 쿼리**로 바꾼다 —
#    우리가 정말 필요한 능력이 그것이다.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$PGC" psql -U t -d t -tAc 'select 1' >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: 임시 Postgres 가 60초 안에 쿼리를 받지 못했다 — 아래 케이스는 돌리지 않는다"
  echo "      (여기서 멈추지 않으면 준비 실패가 '테스트 실패'로 위장한다)"
  docker logs "$PGC" 2>&1 | tail -15
  docker rm -f "$PGC" >/dev/null 2>&1
  exit 1
fi

q() { docker exec "$PGC" psql -U t -d t -tAc "$1" 2>&1 | tr -d '[:space:]'; }

q "create table execution_runs (
     id serial primary key,
     status text not null,
     updated_at timestamptz not null,
     claimed_at timestamptz
   );" >/dev/null

fail=0
# case: label | status | updated_at | claimed_at | expected count
run_case() {
  local label="$1" status="$2" upd="$3" claim="$4" want="$5" loop_started="${6:-}"
  q "truncate execution_runs;" >/dev/null
  local claim_sql="null"
  [ "$claim" != "null" ] && claim_sql="now() - interval '$claim'"
  q "insert into execution_runs(status, updated_at, claimed_at)
     values ('$status', now() - interval '$upd', $claim_sql);" >/dev/null
  local got started_iso=""
  if [ -n "$loop_started" ]; then
    started_iso=$(q "select to_char(now() - interval '$loop_started', 'YYYY-MM-DD\"T\"HH24:MI:SS+00');")
  fi
  got=$(q "$(run_liveness_sql 7200 "$started_iso")")
  if [ "$got" = "$want" ]; then
    echo "  ok   — $label (기대 $want, 실제 $got)"
  else
    echo "  FAIL — $label (기대 $want, 실제 $got)"
    fail=1
  fi
}

echo "== 케이스 =="
# THE regression: mid-turn, DB silent 5 min, claim held → must be PROTECTED.
run_case "턴 중간 5분 침묵, claim 유지 → 보호" \
         running "5 minutes" "5 minutes" 1
# A full-suite turn: the app allows up to a 1h turn cap without a refresh.
run_case "50분짜리 긴 턴, lease 이내 → 보호" \
         running "50 minutes" "50 minutes" 1
# Past the lease: the app's own reaper owns this row → NOT protected.
run_case "claim 이 lease(2h) 초과 → 보호 안 함 (리퍼 담당)" \
         running "3 hours" "3 hours" 0
# Parked on a founder Decision: claimed_at cleared on the pause exit.
run_case "형님 결정 대기(claimed_at NULL) → 보호 안 함" \
         running "10 minutes" null 0
# Queued but nobody driving it: nothing to disrupt.
run_case "OPEN(미클레임) → 보호 안 함" \
         open "1 minute" null 0
# Freshly claimed, obviously alive.
run_case "방금 클레임 → 보호" \
         running "10 seconds" "10 seconds" 1

# The loop lives IN the worker container. If that container started AFTER the
# claim was stamped, no in-process loop can still be holding it — the claim is
# ORPHANED (exactly run abe9e2b9 after the 14:51 recreate). Detecting this is
# what keeps a crashed run from blocking deploys for the whole 2h lease.
run_case "워커가 claim 이후에 기동 → 고아 claim, 보호 안 함" \
         running "5 minutes" "5 minutes" 0 "1 minute"
run_case "워커가 claim 이전부터 떠 있음 → 살아있음, 보호" \
         running "5 minutes" "5 minutes" 1 "30 minutes"

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
