#!/usr/bin/env bash
# test_prod_log_archive.sh — prod 컨테이너 로그는 재생성 전에 파일로 남는다.
#
# 2026-10-07 실측. BSVibe 실측 런의 MCP 도구 호출(#1145 — 에이전트가 왜 스크래치
# 스크립트를 썼나)을 사후에 보려 했더니 backend 로그가 없었다. 로그는 docker 의
# json-file 이라 **컨테이너에 붙어 있고**, autodeploy 가 머지마다
# `up -d --force-recreate` 로 컨테이너를 새로 만들면 함께 사라진다. 그날만 재배포가
# 다섯 번이었다.
#
# 그래서 재생성 직전에 지금 컨테이너의 로그를 떠 둔다. 파일 이름은 컨테이너
# **시작 시각**으로 정해서, 같은 컨테이너를 두 번 떠도 한 파일이다(덮어쓴다).
set -u
cd "$(dirname "$0")/.." || exit 1
. scripts/lib/prod_log_archive.sh

fails=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1 ($2)"; fails=$((fails + 1)); }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/out"

# 가짜 docker: inspect 는 컨테이너별 시작 시각, logs 는 그 컨테이너의 줄.
cat > "$tmp/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1" in
  inspect)
    name="${@: -1}"
    f="$FAKE_DOCKER_DIR/$name.started"
    [ -f "$f" ] || { echo "Error: No such object: $name" >&2; exit 1; }
    cat "$f" ;;
  logs)
    name="${@: -1}"
    cat "$FAKE_DOCKER_DIR/$name.log" ;;
esac
SH
chmod +x "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" FAKE_DOCKER_DIR="$tmp"

printf '2026-10-07T06:41:10.123456789Z\n' > "$tmp/bsvibe-prod-backend-1.started"
printf 'line-a\nline-b\n' > "$tmp/bsvibe-prod-backend-1.log"

echo "== 1. 재생성 전 로그가 파일로 남는다 =="
archive_prod_container_logs "$tmp/out" 5 bsvibe-prod-backend-1
f=$(ls "$tmp/out"/bsvibe-prod-backend-1--*.log 2>/dev/null | head -1)
[ -n "$f" ] && grep -q line-b "$f" && ok "파일 + 내용" || bad "아카이브" "f=[$f]"
case "$f" in *2026-10-07T06-41-10*) ok "이름에 시작 시각" ;; *) bad "이름" "$f" ;; esac

echo "== 2. 같은 컨테이너를 두 번 떠도 한 파일 =="
printf 'line-a\nline-b\nline-c\n' > "$tmp/bsvibe-prod-backend-1.log"
archive_prod_container_logs "$tmp/out" 5 bsvibe-prod-backend-1
n=$(ls "$tmp/out"/bsvibe-prod-backend-1--*.log | wc -l | tr -d ' ')
[ "$n" = 1 ] && grep -q line-c "$f" && ok "한 파일, 최신 내용" || bad "중복" "n=$n"

echo "== 3. 컨테이너마다 최근 N 개만 남긴다 =="
for i in 1 2 3 4 5 6; do
  printf '2026-10-0%dT00:00:00Z\n' "$i" > "$tmp/bsvibe-prod-worker-1.started"
  printf 'w%d\n' "$i" > "$tmp/bsvibe-prod-worker-1.log"
  archive_prod_container_logs "$tmp/out" 3 bsvibe-prod-worker-1
done
n=$(ls "$tmp/out"/bsvibe-prod-worker-1--*.log | wc -l | tr -d ' ')
[ "$n" = 3 ] && ok "워커 3개" || bad "보존 수" "n=$n"
ls "$tmp/out"/bsvibe-prod-worker-1--2026-10-06* >/dev/null 2>&1 && ok "최신은 남는다" || bad "최신" "missing"
ls "$tmp/out"/bsvibe-prod-worker-1--2026-10-01* >/dev/null 2>&1 && bad "가장 오래된 것" "kept" || ok "가장 오래된 것은 지운다"
n=$(ls "$tmp/out"/bsvibe-prod-backend-1--*.log | wc -l | tr -d ' ')
[ "$n" = 1 ] && ok "다른 컨테이너의 보존은 건드리지 않는다" || bad "교차 삭제" "n=$n"

echo "== 4. 없는 컨테이너는 실패가 아니다 (첫 배포 · 이름 바뀜) =="
archive_prod_container_logs "$tmp/out" 3 bsvibe-prod-없음 && ok "rc=0" || bad "없는 컨테이너" "rc!=0"

echo
[ "$fails" = 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
