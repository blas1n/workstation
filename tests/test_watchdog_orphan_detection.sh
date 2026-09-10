#!/usr/bin/env bash
# test_watchdog_orphan_detection.sh — 고아 폭주 탐지는 순간 CPU 로 판정해야 한다.
#
# 회귀 (2026-09-10 실측): watchdog 이 `ps ... %cpu`(수명 누적 평균)로 판정해서,
# 수명이 긴 macOS 시스템 데몬(mediaanalysisd=806, SafeBrowsing=7758)이 과거 한 번
# 스파이크하자 평균이 172%로 며칠간 임계 위에 붙어 **CPU 0% 인 지금도 계속** 텔레그램
# 알림을 쐈다. 누적 평균은 "지금 폭주 중"이 아니라 "살면서 평균 얼마"를 잰다.
#
# 진짜 폭주(detached busy loop)는 순간에도 hot 이므로, 순간 CPU 게이트를 추가하면
# 오탐(지금 유휴)은 떨어지고 진짜는 잡힌다. 경로 allowlist 는 쓰지 않는다 —
# watchdog.sh 주석이 직접 금한다("공격자도 /usr/bin/python3 를 쓴다").

set -uo pipefail
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/watchdog_orphans.sh"
if [ ! -f "$LIB" ]; then echo "FAIL: $LIB 없음 (아직 미구현)"; exit 1; fi
# shellcheck source=/dev/null
source "$LIB"

fails=0
check() { # $1=설명 $2=기대(pids, 공백구분 정렬) $3=실제
  local got; got=$(printf '%s' "$3" | tr ' ' '\n' | grep -oE '^[0-9]+' | sort -n | tr '\n' ' ' | sed 's/ $//')
  local want; want=$(printf '%s' "$2" | tr ' ' '\n' | sort -n | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then echo "  ok: $1"; else echo "  FAIL: $1 — 기대[$want] 실제[$got]"; fails=$((fails+1)); fi
}

# ps 스냅샷 픽스처: pid ppid user etime %cpu comm
# 806/7758 = 수명 평균은 높지만 지금 유휴인 시스템 데몬(오탐 대상)
# 999      = 진짜 폭주 busy loop (수명 평균도 순간도 hot)
# 1000     = 부모 있음(PPID!=1) → 제외
# 1001     = 다른 유저 → 제외
# 1002     = 너무 어림(age<1800s) → 제외
# 1003     = Docker VM (상시 hot, allowlist) → 제외
PS_SNAP='PID PPID USER ELAPSED %CPU COMM
806 1 blasin 22:47:07 172.0 /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd
7758 1 blasin 22:27:02 88.3 /System/Library/PrivateFrameworks/SafariSafeBrowsing.framework/com.apple.Safari.SafeBrowsing.Service
999 1 blasin 02:10:00 190.0 /bin/zsh
1000 500 blasin 05:00:00 99.0 /usr/bin/python3
1001 1 root 10:00:00 80.0 /usr/sbin/spindump
1002 1 blasin 10:00 95.0 /usr/bin/python3
1003 1 blasin 30:00:00 300.0 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/x'

# 순간 CPU 샘플러 픽스처: pid → 지금 CPU. 806/7758 은 지금 유휴(0), 999 는 지금도 hot.
sampler() { case "$1" in 999) echo 92.0;; 806|7758) echo 0.0;; *) echo 0.0;; esac; }

out=$(printf '%s\n' "$PS_SNAP" | detect_runaway_orphans sampler blasin 50 1800)
check "지금 유휴인 시스템 데몬(806,7758)은 오탐 안 함 + 진짜 폭주(999)만 잡음" "999" "$out"

# 진짜 폭주가 여러 개면 다 잡아야 한다
PS2='PID PPID USER ELAPSED %CPU COMM
2001 1 blasin 03:00:00 150.0 /usr/bin/python3
2002 1 blasin 04:00:00 160.0 /bin/bash'
sampler2() { case "$1" in 2001) echo 99;; 2002) echo 80;; *) echo 0;; esac; }
out2=$(printf '%s\n' "$PS2" | detect_runaway_orphans sampler2 blasin 50 1800)
check "순간에도 hot 인 폭주 2개 다 잡음" "2001 2002" "$out2"

# 수명 평균은 hot 인데 지금 전부 유휴 → 아무것도 안 잡음(빈 출력)
sampler_idle() { echo 0; }
out3=$(printf '%s\n' "$PS2" | detect_runaway_orphans sampler_idle blasin 50 1800)
check "전부 지금 유휴면 아무 알림 없음" "" "$out3"

echo
if [ "$fails" -eq 0 ]; then echo "PASS (전부 통과)"; exit 0; else echo "FAIL: $fails 건"; exit 1; fi
