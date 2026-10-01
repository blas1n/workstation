#!/usr/bin/env bash
# test_colima_ensure_recovers_stale_disk_lock.sh — 재시도가 복구를 막으면 안 된다.
#
# 사고 (2026-10-01 실측, prod 45분 다운): 맥미니가 11:23 KST 재부팅됐고 colima 가
# 못 올라왔다. 11:22 의 비정상 종료가 500GiB 데이터 디스크에 "사용 중" 표시를 남겨
# 인스턴스는 Stopped 인데 lima 가 디스크를 못 붙였다:
#
#   fatal  failed to run attach disk "colima", in use by instance "colima"
#
# 이 실패는 **재시도로 절대 낫지 않는다**. 그런데 colima-ensure 는 StartInterval 60
# 으로 60초마다 다시 시도했고, `colima start` 는 1~3분이 걸려서 **앞 시도가 끝나기
# 전에 다음 시도가 겹쳤다**. 겹친 시도마다 `limactl usernet` 고아가 남아 40개까지
# 쌓이고 load average 8.43 이 됐다 — 자동복구가 상태를 더 나쁘게만 만들었다.
#
# 그래서 두 축을 고정한다:
#   1) 단일 실행(single-flight) — 겹치면 고아가 쌓인다
#   2) 유령 잠금은 **증명된 안전 조건에서만** 해제 — 인스턴스가 정말 Stopped 이고
#      VM 프로세스가 0 일 때만. 디스크에 prod postgres 데이터가 있어서, 살아 있는
#      VM 의 디스크를 떼면 손상이다. 이 게이트가 테스트의 핵심이다.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/colima_recover.sh"
SCRIPT="$ROOT/scripts/colima-ensure.sh"

if [ ! -f "$LIB" ]; then echo "FAIL: $LIB 없음 (아직 미구현)"; exit 1; fi
# shellcheck source=/dev/null
source "$LIB"

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }
eq()  { # $1=설명 $2=기대 $3=실제
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "기대[$2] 실제[$3]"; fi
}

# 사고 당시 ha.stderr.log 의 문장 그대로.
STALE='{"level":"fatal","msg":"failed to run attach disk \"colima\", in use by instance \"colima\"","time":"2026-10-01T12:06:54+09:00"}'
# 과거에 실제로 본 다른 실패(스크립트 주석이 인용하는 2026-06-22 · 08-11).
TRANSIENT='time="..." level=fatal msg="error starting vm: error at '"'"'starting'"'"': exit status 1"'

echo "== 실패를 분류한다 =="
eq "유령 디스크 잠금을 알아본다"        "stale_disk_lock" "$(colima_failure_kind "$STALE")"
eq "일시적 VZ 실패는 잠금이 아니다"     "unknown"         "$(colima_failure_kind "$TRANSIENT")"
eq "빈 출력은 잠금이 아니다"            "unknown"         "$(colima_failure_kind "")"
eq "잠긴 디스크 이름을 뽑는다"          "colima"          "$(stale_lock_disk_name "$STALE")"

# ⚠️ 이 디스크에 prod postgres 데이터가 산다. 아래 세 칸이 이 테스트의 이유다.
echo "== 해제는 증명된 안전 조건에서만 =="
STOPPED='NAME               STATUS     SSH            CPUS    MEMORY    DISK     DIR
colima             Stopped    127.0.0.1:0    8       8GiB      20GiB    ~/.colima/_lima/colima'
RUNNING='NAME               STATUS     SSH            CPUS    MEMORY    DISK     DIR
colima             Running    127.0.0.1:50       8       8GiB      20GiB    ~/.colima/_lima/colima'

if stale_lock_is_clearable "$STOPPED" 0 colima; then
  ok "Stopped + VM 프로세스 0 → 해제 가능 (사고 당시 상태)"
else
  bad "Stopped + VM 프로세스 0 → 해제 가능" "사고를 못 고친다"
fi
if stale_lock_is_clearable "$RUNNING" 0 colima; then
  bad "Running 이면 거부" "살아 있는 VM 의 디스크를 떼면 postgres 손상이다"
else
  ok "Running 이면 거부"
fi
if stale_lock_is_clearable "$STOPPED" 1 colima; then
  bad "VM 프로세스가 있으면 거부(목록이 Stopped 라 해도)" \
      "목록과 실제가 어긋날 수 있다 — 더 보수적인 쪽을 믿어야 한다"
else
  ok "VM 프로세스가 있으면 거부(목록이 Stopped 라 해도)"
fi
if stale_lock_is_clearable "$STOPPED" 0 colima-palworld; then
  bad "목록에 없는 인스턴스는 거부" "엉뚱한 인스턴스를 근거로 해제하면 안 된다"
else
  ok "목록에 없는 인스턴스는 거부"
fi

echo "== 고아 usernet 프로세스를 집어낸다 =="
# pid comm args — 사고 때 40개가 쌓였던 그 모양.
PS_SNAP='  PID COMMAND
  101 /opt/homebrew/bin/limactl usernet -p 1234
  102 /opt/homebrew/bin/limactl usernet -p 1235
  103 /opt/homebrew/bin/limactl start colima
  104 /usr/bin/python3 something-else'
eq "usernet 고아만, 다른 limactl 은 건드리지 않는다" "101 102" \
   "$(printf '%s\n' "$PS_SNAP" | orphan_usernet_pids | tr '\n' ' ' | sed 's/ $//')"

# ⚠️ usernet 은 lima 의 사용자 모드 네트워킹이다. 이 머신엔 인스턴스가 둘
# (colima=prod · colima-palworld=게임서버) 있고, **살아 있는 인스턴스의 usernet 을
# 죽이면 그쪽 네트워킹이 끊긴다**. 그래서 "전부 Stopped" 일 때만 정리한다.
echo "== 고아 정리도 증명된 안전 조건에서만 =="
BOTH_STOPPED='NAME               STATUS     SSH            CPUS
colima             Stopped    127.0.0.1:0    8
colima-palworld    Stopped    127.0.0.1:0    6'
PALWORLD_UP='NAME               STATUS     SSH             CPUS
colima             Stopped    127.0.0.1:0     8
colima-palworld    Running    127.0.0.1:60    6'
if orphan_reap_is_safe "$BOTH_STOPPED"; then
  ok "모든 인스턴스가 Stopped → 정리 가능"
else
  bad "모든 인스턴스가 Stopped → 정리 가능" "사고 당시 상태를 못 고친다"
fi
if orphan_reap_is_safe "$PALWORLD_UP"; then
  bad "다른 인스턴스가 Running 이면 정리 거부" \
      "palworld 의 usernet 을 죽이면 그 서버 네트워킹이 끊긴다"
else
  ok "다른 인스턴스가 Running 이면 정리 거부"
fi

echo "== 단일 실행: 겹치면 고아가 쌓인다 =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
LOCK="$TMP/lock"
if singleflight_acquire "$LOCK"; then ok "첫 시도는 획득한다"; else bad "첫 시도는 획득한다" "획득 실패"; fi
if singleflight_acquire "$LOCK"; then
  bad "붙잡힌 동안 두 번째 시도는 거부" "거부하지 않으면 사고처럼 고아 40개가 쌓인다"
else
  ok "붙잡힌 동안 두 번째 시도는 거부"
fi
singleflight_release "$LOCK"
if singleflight_acquire "$LOCK"; then ok "해제 후 다시 획득한다"; else bad "해제 후 다시 획득한다" "영구 교착"; fi
singleflight_release "$LOCK"
# 죽은 홀더의 잠금은 넘겨받아야 한다 — 안 그러면 한 번 크래시하고 영구 교착이다.
mkdir -p "$LOCK"; echo 999999 > "$LOCK/pid"
if singleflight_acquire "$LOCK"; then
  ok "죽은 홀더의 잠금은 인수한다"
else
  bad "죽은 홀더의 잠금은 인수한다" "크래시 한 번에 자동복구가 영구 정지한다"
fi
singleflight_release "$LOCK"

echo "== 배선: ensure 스크립트가 실제로 부른다 =="
# 공유 함수가 옳아도 부르지 않으면 아무것도 복구하지 못한다.
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT 없음"; exit 1; }
grep -q 'lib/colima_recover.sh' "$SCRIPT" \
  && ok "라이브러리를 로드한다" \
  || bad "라이브러리를 로드한다" "로드 안 하면 호출이 command not found 로 조용히 빈 값이 된다"
for fn in singleflight_acquire colima_failure_kind stale_lock_is_clearable \
          orphan_reap_is_safe orphan_usernet_pids; do
  grep -q "$fn" "$SCRIPT" && ok "$fn 를 부른다" || bad "$fn 를 부른다" "배선 없음"
done
# 획득이 start 보다 **앞**이어야 한다 — 뒤면 겹침을 못 막는다.
#
# ⚠️ 처음엔 파일 전체를 grep 했는데 **내 주석에 걸려 빨개졌다**: 헤더가 브루 유닛을
# 설명하며 "runs ``colima start -f`` at boot" 이라고 적어 둔 6행이 먼저 잡혔다.
# 명제는 "코드에서 획득이 start 보다 앞"이므로 주석 줄을 비우고 센다(줄 번호는
# 유지되게 **비우기만** 한다). 아래 대조군이 스트리퍼 자체를 검산한다.
CODE="$(sed 's/^[[:space:]]*#.*$//' "$SCRIPT")"
if printf '%s\n' "$CODE" | grep -q 'singleflight_acquire' &&
   printf '%s\n' "$CODE" | grep -q 'colima start' &&
   [ "$(printf '%s\n' "$CODE" | sed -n '6p' | tr -d '[:space:]')" = "" ]; then
  ok "주석 스트리퍼 대조군 (코드는 남고, 주석 6행은 비었다)"
else
  bad "주석 스트리퍼 대조군" "스트리퍼가 코드를 날렸거나 주석을 못 지웠다 — 아래 단언이 공허해진다"
fi
a=$(printf '%s\n' "$CODE" | grep -n 'singleflight_acquire' | head -1 | cut -d: -f1)
s=$(printf '%s\n' "$CODE" | grep -n 'colima start' | head -1 | cut -d: -f1)
if [ -n "$a" ] && [ -n "$s" ] && [ "$a" -lt "$s" ]; then
  ok "잠금 획득이 colima start 보다 앞에 있다 ($a < $s)"
else
  bad "잠금 획득이 colima start 보다 앞에 있다" "획득[$a] start[$s] — 뒤면 겹침을 못 막는다"
fi

echo "== 양성 대조군: VM 계수기가 실제로 뒤집히는가 =="
# 이 계수기가 0 에 박혀 있으면 해제 게이트가 **무조건 통과**한다 — 살아 있는 prod VM
# 의 디스크를 떼는 그 사고다. 2026-10-01 실측: colima 가 Running 인데 `pgrep -fc` 는
# 에러, `pgrep -f | wc -l` 는 과소 계수였다. 그래서 "켜져 있을 때 >0" 을 머신에서 센다.
if command -v limactl >/dev/null 2>&1; then
  running=$(LIMA_HOME="$HOME/.colima/_lima" limactl list 2>/dev/null |
            awk 'NR > 1 && $2 == "Running" { n++ } END { print n + 0 }')
  if [ "${running:-0}" -gt 0 ]; then
    n=$(count_vm_processes)
    if [ "${n:-0}" -gt 0 ]; then
      ok "인스턴스가 Running 일 때 VM 프로세스를 센다 (n=$n)"
    else
      bad "인스턴스가 Running 일 때 VM 프로세스를 센다" \
          "n=$n — 0 에 박힌 계수기는 해제 게이트를 무조건 통과시킨다"
    fi
  else
    echo "  SKIP — 지금 Running 인 인스턴스가 없다(계수기의 양성 대조군은 켜져 있어야 가능)"
  fi
else
  echo "  SKIP — limactl 없음 (CI)"
fi

echo "== 양성 대조군: 사고 당시 실제 로그가 분류되는가 =="
# 분류기가 내 상상이 아니라 **진짜 산출물**에 걸리는지. 워크스테이션에서만 가능.
HA="$HOME/.colima/_lima/colima/ha.stderr.log"
if [ -f "$HA" ] && grep -q 'in use by instance' "$HA" 2>/dev/null; then
  line=$(grep 'in use by instance' "$HA" | tail -1)
  eq "실제 로그 줄이 stale_disk_lock 으로 분류된다" "stale_disk_lock" "$(colima_failure_kind "$line")"
else
  echo "  SKIP — 이 머신에 사고 로그가 없다(해소됐거나 CI). 분류는 위 픽스처로 고정돼 있다"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "$fails FAIL"; exit 1; fi
