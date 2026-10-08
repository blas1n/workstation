#!/usr/bin/env bash
# 로그 아카이브가 **재생성보다 먼저** 불린다 — 나중에 부르면 떠 둘 컨테이너가 이미 없다.
# 라이브 실증(실제 배포를 기다리기)은 배포 자체가 prod 행동이라, 순서를 정적으로 고정한다.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/autodeploy.sh"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fails=$((fails+1)); }

grep -q 'lib/prod_log_archive.sh' "$SCRIPT" && ok "sources prod_log_archive.sh" \
  || bad "sources prod_log_archive.sh" "로드하지 않으면 호출은 command not found 로 조용히 지나간다"

archive=$(grep -n 'archive_prod_container_logs ' "$SCRIPT" | head -1 | cut -d: -f1)
# The legacy PROJECTS loop recreates too — compare inside the bsvibe-app block only.
MARK=$(grep -n '^# --- bsvibe-app' "$SCRIPT" | head -1 | cut -d: -f1)
recreate=$(awk -v m="${MARK:-0}" 'NR > m && /up -d --build --force-recreate/ {print NR; exit}' "$SCRIPT")
if [ -n "$archive" ] && [ -n "$recreate" ] && [ "$archive" -lt "$recreate" ]; then
  ok "archive (line $archive) before recreate (line $recreate)"
else
  bad "archive before recreate" "archive=[$archive] recreate=[$recreate]"
fi
for c in bsvibe-prod-backend-1 bsvibe-prod-worker-1; do
  sed -n "${archive:-1}p" "$SCRIPT" | grep -q "$c" && ok "archives $c" || bad "archives $c" "missing"
done

[ "$fails" = 0 ] && { echo "PASS"; exit 0; } || { echo "FAIL ($fails)"; exit 1; }
