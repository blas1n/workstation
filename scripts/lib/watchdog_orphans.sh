#!/usr/bin/env bash
# watchdog_orphans.sh — 고아 폭주 프로세스 판정 (순수 로직, 주입 가능).
#
# watchdog.sh §8 에서 인라인이던 것을 분리했다. 이유는 2026-09-10 회귀:
# `ps ... %cpu` 는 **수명 누적 평균**이라, 수명이 긴 시스템 데몬이 과거 한 번
# 스파이크하면 평균이 며칠간 임계 위에 붙어 **지금 유휴인데도** 계속 알렸다.
# 고침은 후보마다 **순간 CPU 를 한 번 더 재서** 지금도 hot 인 것만 남기는 것.
# 경로 allowlist 로 안 거른다 — watchdog.sh 주석이 금한다("공격자도 흔한 경로를
# 쓴다"). Virtualization.framework 만 예외(Docker VM = 상시 hot 이 설계).

# _orphan_etime_secs ELAPSED → 초. `ps` etime 은 [[dd-]hh:]mm:ss.
_orphan_etime_secs() {
  awk -v e="$1" 'BEGIN{
    d=0; if (e ~ /-/) { split(e,a,"-"); d=a[1]; e=a[2] }
    n=split(e,a,":");
    if (n==3) { print d*86400+a[1]*3600+a[2]*60+a[3]; exit }
    if (n==2) { print d*86400+a[1]*60+a[2]; exit }
    print 0
  }'
}

# detect_runaway_orphans SAMPLER ME CPU_PCT MIN_S  < ps-snapshot
#   stdin: `ps -eo pid,ppid,user,etime,%cpu,comm` 출력(헤더 포함)
#   SAMPLER: `SAMPLER <pid>` 로 그 pid 의 **순간** %cpu 를 찍는 명령/함수 이름
#   출력: 폭주 pid 마다 "pid(수명%cpu,etime) " (없으면 빈 출력)
#
# 판정: PPID==1 + 내 계정 + 수명평균 CPU≥임계 + 오래됨(후보 게이트) →
#       그다음 **순간 CPU≥임계**(진짜 게이트). 둘 다여야 알린다.
detect_runaway_orphans() {
  local sampler="$1" me="$2" cpu="$3" mins="$4"
  # 1차: ps 로 후보 추림. 출력은 "pid life etime" 줄.
  awk -v me="$me" -v cpu="$cpu" -v mins="$mins" '
    function secs(e,  n,a,d) {
      d=0; if (e ~ /-/) { split(e,a,"-"); d=a[1]; e=a[2] }
      n=split(e,a,":");
      if (n==3) return d*86400+a[1]*3600+a[2]*60+a[3]
      if (n==2) return d*86400+a[1]*60+a[2]
      return 0
    }
    NR>1 && $2==1 && $3==me && ($5+0)>=(cpu+0) && secs($4)>=(mins+0) {
      # Virtualization.framework = Docker VM, 상시 고CPU 가 설계 (유일 예외).
      if ($6 ~ /Virtualization\.framework/) next
      print $1, $5, $4
    }' | while read -r pid life etime; do
      # 2차: 순간 CPU 를 재서 지금도 hot 인 것만.
      local inst; inst=$("$sampler" "$pid")
      if awk -v i="$inst" -v c="$cpu" 'BEGIN{exit !((i+0)>=(c+0))}'; then
        printf '%s(%s%%,%s) ' "$pid" "$life" "$etime"
      fi
    done
}

# _instant_cpu PID → 그 pid 의 순간 %cpu (top 2차 샘플 = 실제 구간 측정). 없으면 0.
# macOS `top -l 2` 는 1차(부팅 후 누적)·2차(샘플 구간)를 준다. 2차가 순간값.
_instant_cpu() {
  top -l 2 -pid "$1" -stats cpu 2>/dev/null \
    | awk 'NF && $1 ~ /^[0-9.]+$/ { v=$1 } END { print (v==""?0:v)+0 }'
}
