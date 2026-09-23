#!/bin/bash
# secrets-sync.sh — 금고(bw)의 비밀을 기계가 읽을 0600 잎사귀로 내려보낸다.
#
# 마스터 비밀번호는 **디스크에 남지 않는다.** 이 스크립트가 한 번 물어보고,
# 세션 키는 프로세스 안에서만 살다가 끝난다. launchd 데몬들은 금고를 아예 안 본다.
#
# 자세한 이유는 scripts/lib/secrets_manifest.sh 머리말에.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${SECRETS_MANIFEST:-$ROOT/secrets.manifest}"
. "$ROOT/scripts/lib/secrets_manifest.sh"
declare -F leaf_verify >/dev/null || { echo "FATAL: secrets_manifest.sh 로드 실패"; exit 1; }

command -v bw >/dev/null 2>&1 || { echo "FATAL: bw CLI 가 없다 (brew install bitwarden-cli)"; exit 1; }

v=$(manifest_validate "$MANIFEST")
if [ "$v" != ok ]; then
  echo "FATAL: 매니페스트가 유효하지 않다: $MANIFEST"
  echo "  항목 수: $(manifest_count "$MANIFEST") — 칸은 2개(이름<TAB>목적지), 목적지는 \$HOME 아래여야 한다."
  echo "  🚫 값을 적지 마라. 이 파일은 git 에 올라간다."
  exit 1
fi

status=$(bw status 2>/dev/null | tr -d ' ')
case "$status" in
  *'"status":"unauthenticated"'*) echo "FATAL: bw 에 로그인돼 있지 않다 — bw login"; exit 1 ;;
esac

# 세션: 이미 있으면 쓰고, 없으면 **여기서 한 번** 물어본다.
if [ -z "${BW_SESSION:-}" ]; then
  echo "금고를 엽니다 — 마스터 비밀번호는 저장되지 않습니다."
  BW_SESSION=$(bw unlock --raw) || { echo "FATAL: 잠금해제 실패"; exit 1; }
fi
export BW_SESSION
trap 'unset BW_SESSION' EXIT

bw sync --session "$BW_SESSION" >/dev/null 2>&1

rc=0 wrote=0 same=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|\#*) continue ;; esac
  [ -z "${line//[[:space:]]/}" ] && continue
  IFS=$'\t' read -r item dest _ <<<"$line"
  path=$(manifest_dest_expand "$dest")

  # 값은 변수에만 담고 **절대 출력하지 않는다.** 실패해도 사유만 말한다.
  if ! secret=$(bw get password "$item" --session "$BW_SESSION" 2>/dev/null); then
    echo "  FAIL  $item — 금고에서 그 이름의 항목을 못 읽었다"
    # 도구가 이미 세션을 들고 있다. "이름이 맞나?" 로 끝내면 사람이 별도 명령을
    # 찾아 쳐야 한다 — 후보를 여기서 보여준다. 값이 아니라 **이름만** 찍는다.
    key=$(manifest_search_key "$item")
    if [ -n "$key" ]; then
      cands=$(bw list items --search "$key" --session "$BW_SESSION" 2>/dev/null \
                | jq -r '.[].name' 2>/dev/null | head -10)
      if [ -n "$cands" ]; then
        echo "        '$key' 로 검색한 후보:"
        # ⚠️ 줄 단위로 읽는다. `printf ... $cands` 처럼 따옴표 없이 넘기면
        #    **공백이 든 이름이 쪼개진다**("BSVibe E2E Live" → 세 줄). 후보를
        #    보여주려던 출력이 후보를 망가뜨리면 안 보여주느니만 못하다.
        while IFS= read -r cand; do
          [ -n "$cand" ] && printf '          - %s\n' "$cand"
        done <<< "$cands"
        echo "        → secrets.manifest 의 첫 칸을 실제 이름으로 고치면 된다"
      else
        echo "        '$key' 로 검색해도 후보가 없다 — 금고에 그 항목 자체가 없을 수 있다"
      fi
    fi
    rc=1; continue
  fi
  [ -n "$secret" ] || { echo "  FAIL  $item — 금고의 값이 비어 있다"; rc=1; continue; }

  before=""
  [ -f "$path" ] && before=$(cksum < "$path")

  mkdir -p "$(dirname "$path")"
  install -m 600 /dev/null "$path" || { echo "  FAIL  $item — $path 를 만들 수 없다"; rc=1; continue; }
  # ⚠️ printf %s — echo 를 쓰면 끝에 개행이 붙고 로그인이 실패한다. 그 실패는
  #    "비번이 틀렸다"로 보여서 사람이 금고를 의심하게 된다.
  printf %s "$secret" > "$path"
  unset secret

  lv=$(leaf_verify "$path")
  if [ "$lv" != ok ]; then
    echo "  FAIL  $item — 쓰고 나서 확인이 실패했다: $lv ($path)"
    rc=1; continue
  fi
  after=$(cksum < "$path")
  if [ "$before" = "$after" ]; then
    echo "  same  $item → $path"; same=$((same+1))
  else
    echo "  wrote $item → $path (0600)"; wrote=$((wrote+1))
  fi
done < "$MANIFEST"

total=$(manifest_count "$MANIFEST")
echo "— 항목 $total 개: 새로 씀 $wrote · 변화 없음 $same · 실패 $((total - wrote - same))"
[ "$rc" = 0 ] || echo "⚠️ 실패한 항목이 있다. 위 사유를 보라."
exit "$rc"
