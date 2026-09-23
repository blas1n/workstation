#!/usr/bin/env bash
# vault_session.sh — 금고 세션이 **말없이** 만료되지 않게 하는 판정.
#
# 2026-09-23. 형님이 금고에서 비밀번호를 꺼내려는 순간 `invalid_grant` 로 막혔다.
# `bw status` 의 `lastSync` 가 **2026-07-13** 이었다 — 두 달 동안 아무도 안 써서
# 리프레시 토큰이 만료된 것을 **필요한 바로 그 순간에** 알았다.
#
# ⚠️ 이건 장애가 아니다. `bw login` 한 번이면 끝나는 유지보수다. 형님 원칙:
#    사람 대기를 알람으로 만들면 그 알람은 곧 무시되고, 진짜 고장이 났을 때
#    아무도 안 본다. 그래서 세 단계로 나눈다 — 조용함 / 알림 / 경고.
#
# 📏 임계값은 **추정이다.** 실측된 것은 "72일은 만료였다" 하나뿐이고, 정확한
#    수명은 모른다. 그래서 보수적으로 21/30 을 기본으로 둔다 — 일찍 알리는 대가는
#    문장 한 줄이고, 늦게 아는 대가는 형님이 막히는 것이다.
#    ⇒ 다음에 만료를 관측하면 그 날짜로 이 숫자를 고쳐라.
#
# 테스트: tests/test_vault_session_freshness.sh

# vault_session_verdict <lastSync-iso|null> <now-epoch> <warn-days> <fail-days>
#   fresh | aging | stale | unknown
#
# 경계는 **초과**다(21일 정각은 아직 fresh). null/빈 값은 `unknown` — 모르는 것을
# fresh 로 접으면 그 순간부터 이 검사는 아무것도 안 한다.
vault_session_verdict() {
  local iso="${1:-}" now="${2:-0}" warn="${3:-21}" fail="${4:-30}" epoch days
  case "$iso" in ''|null|NULL) echo unknown; return ;; esac
  # 소수점과 Z 를 떼고 UTC 로 읽는다 (bw 는 2026-09-23T05:32:29.650Z 형식).
  iso="${iso%%.*}"; iso="${iso%Z}"
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null) \
    || epoch=$(date -u -d "$iso" +%s 2>/dev/null) || { echo unknown; return; }
  days=$(( (now - epoch) / 86400 ))
  if   [ "$days" -gt "$fail" ]; then echo stale
  elif [ "$days" -gt "$warn" ]; then echo aging
  else echo fresh
  fi
}

# vault_session_days <lastSync-iso> <now-epoch> — 경과 일수 (모르면 빈 값).
vault_session_days() {
  local iso="${1:-}" now="${2:-0}" epoch
  case "$iso" in ''|null|NULL) return 0 ;; esac
  iso="${iso%%.*}"; iso="${iso%Z}"
  epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null) \
    || epoch=$(date -u -d "$iso" +%s 2>/dev/null) || return 0
  printf '%s' $(( (now - epoch) / 86400 ))
}

# vault_session_reason <verdict> <days> — 사람이 바로 행동할 한 줄. fresh 면 빈 값.
vault_session_reason() {
  local v="${1:-}" d="${2:-?}"
  case "$v" in
    fresh) : ;;
    aging) printf '%s' "금고를 ${d}일째 안 썼다 — 세션이 곧 만료된다. 지금 한 번 열어 두면 나중에 막히지 않는다: bw login (또는 bw unlock)" ;;
    stale) printf '%s' "금고를 ${d}일째 안 썼다 — 세션이 이미 만료됐을 수 있다. 필요한 순간에 막히기 전에: bw login" ;;
    *)     printf '%s' "금고 세션 상태를 알 수 없다 (lastSync 없음) — bw login 으로 한 번 맞춰라" ;;
  esac
}
