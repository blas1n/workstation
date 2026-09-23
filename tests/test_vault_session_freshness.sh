#!/usr/bin/env bash
# test_vault_session_freshness.sh — 금고 세션이 **말없이** 만료되지 않게 한다.
#
# 2026-09-23 실측. 형님이 금고에서 비밀번호를 꺼내려는 순간 이렇게 막혔다:
#
#   invalid_grant (400) — Unable to fetch ServerConfig
#
# 원인은 `lastSync: 2026-07-13` 이었다. **두 달 동안 아무도 금고를 안 썼고**,
# 그래서 리프레시 토큰이 만료된 것을 아무도 몰랐다. 필요한 바로 그 순간에 알았다.
#
# ⚠️ 이건 **장애가 아니다.** 사람이 `bw login` 한 번 하면 끝나는 유지보수다.
#    형님 원칙: 사람 대기를 알람으로 만들면 그 알람은 곧 무시되고, 진짜 고장이
#    났을 때 아무도 안 본다. 그래서 판정을 세 단계로 나눈다 — 조용함/알림/경고.
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/vault_session.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

NOW=$(date -u +%s)
ago() { echo $((NOW - $1 * 86400)); }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }

echo "== 1. 최근에 썼으면 조용하다 =="
v=$(vault_session_verdict "$(iso "$(ago 1)")" "$NOW" 21 30)
[ "$v" = fresh ] && ok "1일 전 = fresh" || bad "1일 전" "v=$v"

echo "== 2. 경계: warn 일수와 같으면 아직 fresh =="
v=$(vault_session_verdict "$(iso "$(ago 21)")" "$NOW" 21 30)
[ "$v" = fresh ] && ok "정확히 21일 = fresh" || bad "정확히 21일" "v=$v"
v=$(vault_session_verdict "$(iso "$(ago 22)")" "$NOW" 21 30)
[ "$v" = aging ] && ok "22일 = aging" || bad "22일" "v=$v"

echo "== 3. 오래되면 stale =="
v=$(vault_session_verdict "$(iso "$(ago 31)")" "$NOW" 21 30)
[ "$v" = stale ] && ok "31일 = stale" || bad "31일" "v=$v"

echo "== 4. ⭐ 오늘 실제로 막힌 값(72일)이 stale 로 잡힌다 =="
v=$(vault_session_verdict "2026-07-13T12:35:58.559Z" "$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' '2026-09-23T05:00:00Z' +%s 2>/dev/null || echo "$NOW")" 21 30)
[ "$v" = stale ] && ok "2026-07-13 → stale" || bad "실제 값" "v=$v"

echo "== 5. lastSync 가 null 이면 unknown — fresh 로 접지 않는다 =="
v=$(vault_session_verdict "null" "$NOW" 21 30)
[ "$v" = unknown ] && ok "null = unknown" || bad "null" "v=$v"
v=$(vault_session_verdict "" "$NOW" 21 30)
[ "$v" = unknown ] && ok "빈 값 = unknown" || bad "빈 값" "v=$v"

echo "== 6. ⭐ 음성 대조군 — 전부 stale 을 뱉는 구현은 통과 못 한다 =="
seen=$(for d in 1 25 40; do vault_session_verdict "$(iso "$(ago $d)")" "$NOW" 21 30; done | sort -u | tr '\n' ' ')
[ "$seen" = "aging fresh stale " ] && ok "세 단계가 각각 나온다 ($seen)" || bad "세 단계" "seen=$seen"

echo "== 7. 사유는 사람이 바로 행동할 수 있어야 한다 =="
r=$(vault_session_reason stale 72)
case "$r" in *"bw login"*) ok "고칠 명령을 담는다" ;; *) bad "고칠 명령" "r=$r" ;; esac
case "$r" in *72*) ok "며칠인지 말한다" ;; *) bad "일수" "r=$r" ;; esac
r=$(vault_session_reason fresh 1)
[ -z "$r" ] && ok "fresh 는 할 말이 없다" || bad "fresh 사유" "r=$r"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
