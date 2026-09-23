#!/usr/bin/env bash
# test_secrets_manifest.sh — 금고↔기계 배선의 **판정 층**.
#
# 2026-09-23. 형님: *"내부 bitwarden 에 비밀번호들 다 있어. 이럴 때 쓰라고 구비해둔거야."*
# 그런데 금고와 기계를 잇는 선이 없었다. 깔면서 잰 제약이 설계를 결정했다:
#
#   bws(Secrets Manager)  → 이 vaultwarden 에 없다 (/api/secrets 404, bws 미설치)
#   bw login --apikey     → 로그인만. **잠금해제는 안 된다**(제로 지식)
#   bw unlock             → 비대화형 입력이 **마스터 비밀번호뿐**
#
# ⇒ 금고를 자동으로 열려면 마스터 비번이 디스크에 있어야 하고, 그러면 blasin 으로
#   도는 무엇이든 **금고 전체**를 연다. 잎사귀 하나 저장하는 것보다 나쁘다.
#
# 그래서 이 도구는 **사람이 한 번 잠금해제**한 세션으로 잎사귀만 내려보낸다.
# launchd 는 금고를 아예 안 본다 — 0600 파일만 읽는다.
#
# 판정을 순수 함수로 두는 이유는 이 레포의 기존 판단과 같다: 본체는 bw 네트워크
# 호출을 통과해야 닿아서, 거기 두면 영원히 테스트되지 않는다.
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/secrets_manifest.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "== 1. 매니페스트는 이름만 담는다 — 값은 절대 =="
# 매니페스트는 git 에 들어간다. 값이 한 줄이라도 들어가면 그게 곧 유출이다.
cat > "$tmp/m.tsv" <<'M'
# item<TAB>dest
bsvibe-e2e-live	~/.bsvibe/e2e-live.password
M
v=$(manifest_validate "$tmp/m.tsv")
[ "$v" = ok ] && ok "정상 매니페스트 = ok" || bad "정상 매니페스트" "v=$v"

echo "== 2. ⭐ 값처럼 생긴 세 번째 칸이 있으면 거부한다 =="
printf 'item\t~/x\thunter2\n' > "$tmp/bad.tsv"
v=$(manifest_validate "$tmp/bad.tsv")
[ "$v" = invalid ] && ok "3칸짜리 줄 = invalid" || bad "3칸짜리 줄 = invalid" "v=$v"

echo "== 3. 목적지가 홈 밖이면 거부한다 =="
printf 'item\t/etc/passwd\n' > "$tmp/esc.tsv"
v=$(manifest_validate "$tmp/esc.tsv")
[ "$v" = invalid ] && ok "홈 밖 목적지 = invalid" || bad "홈 밖 목적지" "v=$v"

echo "== 4. 빈 매니페스트는 ok 가 아니다 (아무것도 안 하고 성공하면 안 된다) =="
: > "$tmp/empty.tsv"
v=$(manifest_validate "$tmp/empty.tsv")
[ "$v" = invalid ] && ok "빈 매니페스트 = invalid" || bad "빈 매니페스트" "v=$v"

echo "== 5. 주석과 빈 줄은 무시하되, 그것만 있으면 비어 있는 것이다 =="
printf '# 주석만\n\n' > "$tmp/c.tsv"
v=$(manifest_validate "$tmp/c.tsv")
[ "$v" = invalid ] && ok "주석뿐 = invalid" || bad "주석뿐" "v=$v"

echo "== 6. 항목 수를 센다 (전수가 비면 아래가 공허하다) =="
n=$(manifest_count "$tmp/m.tsv")
[ "$n" = 1 ] && ok "항목 1개" || bad "항목 수" "n=$n"

echo "== 7. ~ 를 홈으로 편다 =="
d=$(manifest_dest_expand '~/.bsvibe/x.password')
case "$d" in "$HOME"/.bsvibe/x.password) ok "~ 확장" ;; *) bad "~ 확장" "d=$d" ;; esac

echo "== 8. ⭐ 쓰기 검증: 내용이 아니라 **상태**를 본다 =="
# 값을 로그에 찍지 않고도 "제대로 쓰였나"를 말할 수 있어야 한다.
f="$tmp/leaf"; printf 'secret' > "$f"; chmod 600 "$f"
v=$(leaf_verify "$f")
[ "$v" = ok ] && ok "0600 + 내용 = ok" || bad "0600 + 내용" "v=$v"
chmod 644 "$f"
v=$(leaf_verify "$f")
[ "$v" = bad_mode ] && ok "0644 = bad_mode" || bad "0644 = bad_mode" "v=$v"
chmod 600 "$f"; : > "$f"
v=$(leaf_verify "$f")
[ "$v" = empty ] && ok "빈 파일 = empty" || bad "빈 파일 = empty" "v=$v"
v=$(leaf_verify "$tmp/none")
[ "$v" = missing ] && ok "없는 파일 = missing" || bad "없는 파일 = missing" "v=$v"

echo "== 9. ⭐ 개행이 붙으면 거부한다 =="
# printf %s 가 아니라 echo 를 쓰면 비번 끝에 \n 이 붙고 로그인이 실패한다.
# 그 실패는 "비번이 틀렸다"로 보여서 사람이 금고를 의심하게 된다.
f2="$tmp/nl"; printf 'secret\n' > "$f2"; chmod 600 "$f2"
v=$(leaf_verify "$f2")
[ "$v" = trailing_newline ] && ok "끝 개행 = trailing_newline" || bad "끝 개행" "v=$v"

echo "== 10. 음성 대조군 — 전부 ok 를 뱉는 구현은 통과 못 한다 =="
seen=$(for c in "$f" "$f2" "$tmp/none"; do leaf_verify "$c"; done | sort -u | tr '\n' ' ')
case "$seen" in *ok*) bad "대조군: 전부 ok 가 아님" "seen=$seen" ;; *) ok "세 고장이 각각 다른 이름을 얻는다 ($seen)" ;; esac

echo "== 11. ⭐ 못 찾았을 때 쓸 검색어를 항목 이름에서 뽑는다 =="
# 2026-09-23: 형님이 sync 를 돌렸더니 "금고에서 못 읽었다" 가 떴다. 항목 이름이
# 다른 것이다. 그때 도구가 "이름이 맞나?" 라고만 하면 사람이 별도 명령을 찾아
# 쳐야 한다 — 도구는 이미 세션을 들고 있으면서 후보를 못 보여준 셈이다.
k=$(manifest_search_key "bsvibe-e2e-live")
[ "$k" = "bsvibe" ] && ok "하이픈 앞을 검색어로" || bad "검색어 추출" "k=$k"
k=$(manifest_search_key "plain")
[ "$k" = "plain" ] && ok "하이픈 없으면 통째로" || bad "검색어 추출(하이픈 없음)" "k=$k"
# 대조군 — 빈 입력에 빈 검색어를 내면 금고 전체를 덤프하게 된다
k=$(manifest_search_key "")
[ -z "$k" ] && ok "빈 입력 = 빈 검색어 (호출자가 막아야 한다)" || bad "빈 입력" "k=$k"

echo "== 12. ⭐ 이름이 아니라 id 로 집는다 (bw get 은 검색이라 모호하다) =="
# 2026-09-23: 후보 목록에 `admin@bsvibe.dev` 가 **있는데도** get 이 실패했다.
# `bw get password <검색어>` 는 이름뿐 아니라 username/URI 도 훑어서, 다른 항목의
# username 이 admin@bsvibe.dev 면 두 건이 잡히고 "More than one result" 가 난다.
# ⇒ 정확 일치로 id 를 뽑아 **id 로** 가져온다.
J='[{"id":"aaa","name":"admin@bsvibe.dev"},{"id":"bbb","name":"Bsvibe"}]'
i=$(items_pick_exact "$J" "admin@bsvibe.dev")
[ "$i" = "aaa" ] && ok "정확 일치 하나 → id" || bad "정확 일치 → id" "i=$i"

echo "== 13. 정확 일치가 없으면 빈 값 (지어내지 않는다) =="
i=$(items_pick_exact "$J" "없는이름")
[ -z "$i" ] && ok "일치 없음 = 빈 값" || bad "일치 없음" "i=$i"

echo "== 14. ⭐ 정확 일치가 둘이면 빈 값 — 골라주면 안 된다 =="
# 모호한 걸 임의로 고르면 **엉뚱한 비밀이 파일에 쓰인다.** 사람이 정해야 한다.
J2='[{"id":"aaa","name":"dup"},{"id":"bbb","name":"dup"}]'
i=$(items_pick_exact "$J2" "dup")
[ -z "$i" ] && ok "중복 = 빈 값 (사람에게 넘긴다)" || bad "중복" "i=$i"

echo "== 15. 대소문자는 구분한다 (다른 항목일 수 있다) =="
i=$(items_pick_exact "$J" "ADMIN@BSVIBE.DEV")
[ -z "$i" ] && ok "대소문자 다르면 일치 아님" || bad "대소문자" "i=$i"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
