#!/usr/bin/env bash
# logrotate_targets.sh — 로테이터의 대상을 **plist 에서 유도한다.**
#
# 왜 (2026-09-23 실측):
# 기존 로테이터는 `~/Library/Logs` 의 `bsvibe-worker*.log` 하나만 덮었다. 그 사이
# `_infra/logs/autodeploy.log` 가 **225MB**, `ollama.log` 가 102MB 로 자랐다 —
# launchd 로그 전체 345.5MB 중 **상한을 넘은 둘이 전부 목록 밖**이었다.
#
# 목록을 하나 더 늘리는 건 같은 함정을 다시 파는 것이다. 그때도 "지금 있는 것"만
# 적었고, 다음 데몬이 생기면 또 빠진다. launchd 가 쓰는 로그는 plist 의
# StandardOutPath / StandardErrorPath 에 **적혀 있다** — 거기서 세면 새 데몬이
# 생겨도 자동으로 들어온다.
#
# 테스트: tests/test_logrotate_targets.sh
# ⚠️ `stat` / `plutil` 을 경로로 부른다 — zsh 빌트인이 `stat` 을 가로챈다.

_LR_STAT=/usr/bin/stat
_LR_PLUTIL=/usr/bin/plutil

# launchd_log_targets <plist-dir> — 그 디렉터리의 plist 들이 쓰는 로그 경로(중복 제거).
launchd_log_targets() {
  local dir="${1:-}" p
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  for p in "$dir"/*.plist; do
    [ -f "$p" ] || continue
    "$_LR_PLUTIL" -p "$p" 2>/dev/null \
      | grep -oE '"Standard(Out|Error)Path" *=> *"[^"]+"' \
      | sed 's/.*=> *"//; s/"$//'
  done | sort -u
}

# rotate_verdict <path> <max-bytes> — rotate | skip | missing
#
# 경계는 **초과**다. 상한과 정확히 같으면 안 돌린다 — 매 실행마다 같은 파일을
# 돌리는 경계 진동을 막는다.
rotate_verdict() {
  local path="${1:-}" max="${2:-0}" size
  [ -n "$path" ] && [ -f "$path" ] || { echo missing; return; }
  size=$("$_LR_STAT" -f '%z' "$path" 2>/dev/null) || { echo missing; return; }
  if [ "${size:-0}" -gt "${max:-0}" ] 2>/dev/null; then echo rotate; else echo skip; fi
}
