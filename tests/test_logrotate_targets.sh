#!/usr/bin/env bash
# test_logrotate_targets.sh — 로테이터의 대상은 **plist 가 정한다**.
#
# 2026-09-23 실측. 기존 로테이터는 `~/Library/Logs` 의 `bsvibe-worker*.log` 하나만
# 덮었다. 그 사이 `_infra/logs/autodeploy.log` 가 **225MB**, `ollama.log` 가 102MB 로
# 자랐다 — 전체 345.5MB 중 상한을 넘은 둘이 전부 목록 밖이었다.
#
# 목록을 하나 더 늘리는 건 같은 함정을 다시 파는 것이다(그때도 "지금 있는 것"만
# 적었다). launchd 가 쓰는 로그는 **plist 에 적혀 있다** — 거기서 유도하면 새 데몬이
# 생겨도 자동으로 들어온다.
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/logrotate_targets.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/agents" "$tmp/logs"

mk() { # mk <label> <out> <err>
  cat > "$tmp/agents/$1.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>StandardOutPath</key><string>$2</string>
  <key>StandardErrorPath</key><string>$3</string>
</dict></plist>
PL
}

echo "== 1. plist 에서 로그 경로를 뽑는다 =="
mk a "$tmp/logs/a.out" "$tmp/logs/a.err"
mk b "$tmp/logs/b.log" "$tmp/logs/b.log"     # out == err (중복)
got=$(launchd_log_targets "$tmp/agents" | sort | tr '\n' ' ')
want="$tmp/logs/a.err $tmp/logs/a.out $tmp/logs/b.log "
[ "$got" = "$want" ] && ok "세 경로, 중복 제거" || bad "경로 추출" "got=[$got]"

echo "== 2. ⭐ 집합이 비면 실패한다 (비면 로테이터가 아무것도 안 한다) =="
n=$(launchd_log_targets "$tmp/agents" | grep -c .)
[ "$n" = 3 ] && ok "대상 3개" || bad "대상 수" "n=$n"
n2=$(launchd_log_targets "$tmp/없는디렉터리" | grep -c .)
[ "$n2" = 0 ] && ok "없는 디렉터리 = 0개" || bad "없는 디렉터리" "n2=$n2"

echo "== 3. 경계: 상한과 같으면 돌리지 않는다 =="
f="$tmp/logs/sz"; : > "$f"
v=$(rotate_verdict "$f" 100); [ "$v" = skip ] && ok "0바이트 = skip" || bad "0바이트" "v=$v"
printf '%0.s.' $(seq 1 100) > "$f"
v=$(rotate_verdict "$f" 100); [ "$v" = skip ] && ok "정확히 상한 = skip" || bad "정확히 상한" "v=$v"
printf '.' >> "$f"
v=$(rotate_verdict "$f" 100); [ "$v" = rotate ] && ok "상한+1 = rotate" || bad "상한+1" "v=$v"

echo "== 4. 없는 파일은 에러가 아니라 missing =="
v=$(rotate_verdict "$tmp/logs/없다" 100)
[ "$v" = missing ] && ok "없는 파일 = missing" || bad "없는 파일" "v=$v"

echo "== 5. ⭐ 음성 대조군 — 전부 rotate 를 뱉는 구현은 통과 못 한다 =="
seen=$(for c in "$f" "$tmp/logs/없다" "$tmp/logs/a.out"; do rotate_verdict "$c" 999999; done | sort -u | tr '\n' ' ')
case "$seen" in *rotate*) bad "대조군" "seen=$seen" ;; *) ok "상한이 크면 아무것도 안 돌린다 ($seen)" ;; esac

echo "== 6. ⭐ 이 머신의 진짜 plist 에서도 집합이 비지 않는다 =="
# 픽스처만 보면 파서가 실제 plist 형식(바이너리 포함)을 못 읽어도 초록이다.
real=$(launchd_log_targets "$HOME/Library/LaunchAgents" | grep -c .)
[ "${real:-0}" -gt 5 ] && ok "실제 plist 에서 ${real}개" || bad "실제 plist" "real=$real"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
