#!/usr/bin/env bash
#
# bstalk3r-r5-eval.sh — one-shot evaluation of the BStalk3r R5 tie-break
# prospective test, sent to Telegram.
#
# WHY
#   2026-09-29: BStalk3r adopted R5 (ties at RSI-2 = 0 broken by 20-day average
#   dollar volume) and pre-registered a prospective test
#   (BStalk3r docs/preregistration/2026-09-tiebreak-r5.md): window 2026-09-30 ..
#   2026-12-31, PASS iff the paper return AND the R5 sim are both ≥ p75 of 300
#   random-tie-break sims. This runs that evaluation so nobody has to remember.
#
# WHAT IS APPROXIMATE
#   The live return comes from the trade logs' `equity $…` (04:30 KST run =
#   15:30 ET, intraday), not Alpaca closing history. The message says so; the
#   final verdict should re-run tiebreak.py with the Alpaca-based return.
#
# Schedule: launchd com.blas1n.bstalk3r-r5-eval (Jan 5, 10:13 local). launchd has
# no year field, so a marker makes it a true one-shot.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$INFRA/scripts/lib/r5_eval.sh"

REPO=/Users/blasin/Works/BStalk3r/main
MARKER="$INFRA/logs/.bstalk3r-r5-eval.done"
START=2026-09-30 END=2026-12-31
LOG_START=20260930 LOG_END=20270101   # the 2027-01-01 04:30 KST run is 12-31 ET

r5_should_run "$(date +%Y%m%d)" "$MARKER" || { echo "$(date '+%F %T') skip"; exit 0; }

set -a; . "$REPO/.env"; set +a
send() {
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null
}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fail() {
  send "⚠️ BStalk3r R5 전향 검증 자동 평가 실패: $1
로그: $INFRA/logs/bstalk3r-r5-eval.log"
  exit 1
}

live=$(r5_live_return "$REPO/logs" "$LOG_START" "$LOG_END") \
  || fail "창 안의 매매 로그에서 equity 를 두 개 이상 찾지 못함"

cp "$REPO/data/grouped_cache.db" "$WORK/grouped_cache.db" || fail "grouped cache 복사 실패"
cd "$REPO/research/tiebreak" || fail "research/tiebreak 없음"
uv run --no-project --with numpy python panel.py \
  --grouped-db "$WORK/grouped_cache.db" --out "$WORK/panel.npz" || fail "panel 재생성 실패"
out=$(uv run --no-project --with numpy python tiebreak.py --panel "$WORK/panel.npz" \
  --window "$START" "$END" --seeds 300 --cost 0.001 --live-return "$live" 2>&1) \
  || fail "tiebreak.py 실패: $(echo "$out" | tail -3)"

echo "$out"
send "📋 BStalk3r R5 전향 검증 결과 ($START ~ $END)

$(echo "$out" | tail -c 3000)

※ 실계좌 수익률 ${live} 는 매매 로그 equity(15:30 ET 장중) 근사치입니다. 사전등록 판정은 Alpaca 종가 이력 기준으로 tiebreak.py 를 다시 돌려 확정하세요."
touch "$MARKER"
echo "$(date '+%F %T') done live=$live"
