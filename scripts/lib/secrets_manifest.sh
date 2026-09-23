#!/usr/bin/env bash
# secrets_manifest.sh — 금고에서 기계로 내려보내는 **잎사귀**의 판정 층.
#
# 왜 이 모양인가 (2026-09-23 실측):
#
#   bws / Secrets Manager  → 이 vaultwarden 에 없다 (/api/secrets · /api/projects 404)
#   bw login --apikey      → 로그인만. 잠금해제는 못 한다 (제로 지식 설계)
#   bw unlock              → 비대화형 입력이 **마스터 비밀번호뿐**
#
# ⇒ 금고를 자동으로 열려면 마스터 비번이 디스크에 있어야 한다. 그러면 blasin 으로
#   도는 무엇이든 **금고 전체**를 연다 — 가져오려던 비번 하나를 저장하는 것보다 나쁘다.
#
# 그래서 배선은 이렇게 갈린다:
#   * 금고 = **사람용 단일 진실원**. 잠금해제는 사람이 한 번, 대화형으로.
#   * 기계 = 0600 **잎사귀 파일**만 읽는다. launchd 는 금고를 아예 안 본다.
#   * 매니페스트 = 이름과 목적지만. **값은 절대 안 들어간다**(git 에 올라가므로).
#
# 테스트: tests/test_secrets_manifest.sh
#
# ⚠️ `stat` 을 이름으로 부르지 마라 — zsh 빌트인이 가로채 빈 문자열을 낸다.
#    같은 날 keychain_credential.sh 에서 그 함정에 실제로 빠졌다.

_SM_STAT=/usr/bin/stat

# manifest_dest_expand <path> — 선행 ~ 를 $HOME 으로 편다.
manifest_dest_expand() {
  local p="${1:-}"
  case "$p" in "~/"*) printf '%s' "$HOME/${p#\~/}" ;; *) printf '%s' "$p" ;; esac
}

# manifest_count <file> — 주석/빈 줄을 뺀 항목 수.
manifest_count() {
  local f="${1:-}"
  [ -f "$f" ] || { printf '0'; return; }
  grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null | tr -d '[:space:]'
}

# manifest_validate <file> — ok | invalid
#   * 항목이 0개면 invalid — **아무것도 안 하고 성공하는 도구**가 가장 나쁘다.
#   * 칸이 2개가 아니면 invalid — 세 번째 칸은 거의 확실히 **값**이고, 이 파일은
#     git 에 올라간다. 값이 한 줄이라도 들어가면 그게 곧 유출이다.
#   * 목적지가 $HOME 밖이면 invalid — 이 도구는 시스템 경로에 쓰지 않는다.
manifest_validate() {
  local f="${1:-}" line item dest rest n
  [ -f "$f" ] || { echo invalid; return; }
  n=$(manifest_count "$f")
  [ "${n:-0}" -gt 0 ] 2>/dev/null || { echo invalid; return; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*|' '*\#*) continue ;; esac
    [ -z "${line//[[:space:]]/}" ] && continue
    IFS=$'\t' read -r item dest rest <<<"$line"
    [ -n "$item" ] && [ -n "$dest" ] || { echo invalid; return; }
    [ -z "${rest:-}" ] || { echo invalid; return; }
    case "$(manifest_dest_expand "$dest")" in
      "$HOME"/*) : ;;
      *) echo invalid; return ;;
    esac
  done < "$f"
  echo ok
}

# leaf_verify <path> — 쓰인 잎사귀의 **상태**. 값은 절대 읽어 내보내지 않는다.
#   ok | missing | empty | bad_mode | trailing_newline
#
# 개행을 따로 세는 이유: `echo` 로 쓰면 비번 끝에 `\n` 이 붙고 로그인이 실패한다.
# 그 실패는 "비번이 틀렸다"로 보여서 사람이 **금고를 의심하게** 된다 — 원인은
# 여기 있는데. 이 이름이 그 오진을 막는다.
leaf_verify() {
  local p="${1:-}" mode last
  [ -n "$p" ] && [ -e "$p" ] || { echo missing; return; }
  mode=$("$_SM_STAT" -f '%OLp' "$p" 2>/dev/null || "$_SM_STAT" -c '%a' "$p" 2>/dev/null)
  case "$mode" in ?00|00|0) : ;; *) echo bad_mode; return ;; esac
  [ -s "$p" ] || { echo empty; return; }
  last=$(tail -c 1 "$p" | od -An -tx1 | tr -d '[:space:]')
  [ "$last" = "0a" ] && { echo trailing_newline; return; }
  echo ok
}

# manifest_search_key <item-name> — 못 찾았을 때 후보를 보여주기 위한 검색어.
#
# 하이픈 앞 토큰을 쓴다(`bsvibe-e2e-live` → `bsvibe`). 항목 이름이 조금 다를 때
# (`BSVibe E2E Live`, `bsvibe/e2e`, …) 걸리게 하려면 전체 이름으로는 못 찾는다.
# ⚠️ 빈 입력에 빈 검색어를 내는 것은 **의도**다 — 그러면 호출자가 금고 전체를
#    덤프하지 않도록 막아야 한다는 뜻이고, 그 책임을 여기서 숨기지 않는다.
manifest_search_key() {
  local item="${1:-}"
  [ -n "$item" ] || return 0
  printf '%s' "${item%%-*}"
}
