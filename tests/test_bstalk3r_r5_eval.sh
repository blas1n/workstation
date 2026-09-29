#!/usr/bin/env bash
# test_bstalk3r_r5_eval.sh — R5 전향 검증 자동 평가의 순수 부분.
#
# 2026-09-29 BStalk3r 에 R5 tie-break 를 배포하고 사전등록했다
# (BStalk3r docs/preregistration/2026-09-tiebreak-r5.md). 창은 첫 라이브 실행
# (2026-09-30 KST) ~ 2026-12-31. launchd 가 2027-01-05 에 한 번 평가를 돌린다.
# 실계좌 수익은 매매 로그의 `equity $…` 로 근사한다 — 최종 판정은 Alpaca 이력.
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/r5_eval.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
logs="$tmp/logs"; mkdir -p "$logs"

line() { # line <file> <equity-with-commas>
  printf '=== BStalk3r mr-trade ===\nmr-trade 2026-09-25: universe 3484 liquid | held 15 | LIVE PAPER ORDERS | equity $%s cash $298,337\n' "$2" > "$logs/$1"
}

echo "== 1. equity 한 줄에서 숫자를 뽑는다 =="
line trade-20260930.log "1,138,293"
got=$(r5_log_equity "$logs/trade-20260930.log")
[ "$got" = "1138293" ] && ok "콤마 제거" || bad "equity 추출" "got=[$got]"

echo "== 2. 창 안의 첫·마지막 로그 (창 밖·equity 없는 로그는 무시) =="
line trade-20260929.log "1,100,000"          # 창 이전 — 제외
line trade-20261015.log "1,150,000"
line trade-20270101.log "1,200,000"          # 12-31 ET 장중 실행 = 창의 마지막
line trade-20270102.log "9,999,999"          # 창 이후 — 제외
printf 'crashed before summary\n' > "$logs/trade-20261231.log"   # equity 없음
got=$(r5_window_logs "$logs" 20260930 20270101 | xargs -n1 basename | tr '\n' ' ')
[ "$got" = "trade-20260930.log trade-20270101.log " ] && ok "첫=0930, 끝=0101" || bad "창 로그" "got=[$got]"

echo "== 3. 수익률 = 끝/처음 - 1 =="
got=$(r5_live_return "$logs" 20260930 20270101)
[ "$got" = "0.054210" ] && ok "1,200,000 / 1,138,293 - 1" || bad "수익률" "got=[$got]"

echo "== 4. 창 안에 로그가 없으면 실패한다 (0 으로 지어내지 않는다) =="
if r5_live_return "$tmp/empty" 20260930 20270101 >/dev/null 2>&1; then
  bad "빈 창" "성공으로 반환"
else
  ok "빈 창은 실패"
fi

echo "== 5. 날짜 가드: 평가일 이전·완료 마커가 있으면 돌지 않는다 =="
marker="$tmp/done"
r5_should_run 20270104 "$marker" && bad "평가일 전" "돌았다" || ok "01-04 는 안 돈다"
r5_should_run 20270105 "$marker" && ok "01-05 는 돈다" || bad "평가일" "안 돌았다"
touch "$marker"
r5_should_run 20280105 "$marker" && bad "마커" "해마다 다시 돈다" || ok "마커 있으면 안 돈다"

echo
[ "$fails" -eq 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
