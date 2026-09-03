#!/bin/bash
# 라이브 인증 E2E + compose 렌더링 검사를 하루 한 번 돈다.
#
# 왜 데몬인가 — 이 두 검사는 **CI 가 구조적으로 못 돈다**:
#   * 인증 E2E (`apps/pwa/e2e-live/`) 는 docker 스택 + 실제 SSO 계정이 필요하다.
#   * compose 렌더링 검사는 docker 바이너리가 필요한데 CI 샌드박스엔 없다.
# 그래서 레포의 가드는 compose **텍스트**만 고정한다(PR #870 의 알려진 한계).
# 아무도 안 돌리는 검사는 조용히 썩으므로, docker 와 자격증명이 실제로 있는
# 이 머신에 정기 실행 경로를 준다. — "탐지기는 설정이 있는 곳에서 돌아야 한다"
#
# ⚠️ 비밀은 Keychain 에서만 읽는다. plist·이 파일·로그 어디에도 평문이 없다:
#   security add-generic-password -s bsvibe-e2e-live -a <email> -w
#
# ⚠️ 스택은 **일회용**이다(별도 프로젝트·포트·빈 DB). 8700 은 이 머신에서 prod 다 —
#    루프백은 증거가 아니므로 스위트 자신이 `git_sha=e2e-live-stack` 마커로
#    의도한 스택을 적극 식별하고, 아니면 테스트 0개로 멈춘다.

set -u

REPO="/Users/blasin/Works/bsvibe-app/main"
PWA="$REPO/apps/pwa"
PROJECT="bsvibe-e2e-live"
LOG_DIR="/Users/blasin/Works/_infra/logs"
LOG="$LOG_DIR/e2e-live-nightly.log"
# 알림 자격증명. 스모크 실행이 형님 폰을 울리지 않게 덮어쓸 수 있다.
WATCHDOG_ENV="${BSVIBE_E2E_ALERT_ENV:-$HOME/.bsvibe/watchdog.env}"
KEYCHAIN_SERVICE="bsvibe-e2e-live"
E2E_EMAIL="${BSVIBE_E2E_EMAIL:-admin@bsvibe.dev}"

mkdir -p "$LOG_DIR"
exec >>"$LOG" 2>&1
echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) e2e-live-nightly start ====="

failures=""
fail() { failures="${failures}$1\n"; echo "FAIL: $1"; }

# --- teardown 은 무슨 일이 있어도 돈다 -------------------------------------
# 부모가 먼저 죽어도 스택이 남지 않게 trap 으로 건다. `kill $PIDS` 류의
# "끝에서 정리" 는 부모가 살아 있을 때만 동작한다 — 20시간짜리 고아를 만든 그 형태다.
teardown() {
  echo "--- teardown ($PROJECT) ---"
  ( cd "$REPO" && docker compose -p "$PROJECT" down -v --remove-orphans ) || true
}
trap teardown EXIT INT TERM

# --- 무엇을 상대로 쟀는지 기록한다 ------------------------------------------
sha=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "?")
# TRACKED 변경만 "dirty" 로 센다. 이 트리에는 untracked 파일이 상시 있으므로
# (`.vercel/`, `product`, `.env.*.bak`) 그걸 포함하면 신호가 영원히 켜져 있어
# 아무것도 뜻하지 않게 된다.
tracked=$(git -C "$REPO" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
untracked=$(git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
echo "repo HEAD=$sha tracked-modified=$tracked untracked=$untracked"

# ===========================================================================
# 1. compose 렌더링 검사 — 텍스트가 아니라 compose 가 실제로 뭘 만드는지
# ===========================================================================
# 레포의 `tests/deploy/test_local_publish_ports_are_pinned.py` 는 compose 파일의
# **텍스트**를 핀으로 박는다(CI 가 docker 를 못 쓰므로). compose 가 `${VAR:-default}`
# 를 해석하는 방식이 바뀌면 텍스트 가드는 그대로 통과한다. 여기서 그 갭을 메운다.
render_ports() {  # $1 = compose 프로젝트에 넘길 env 접두(없으면 기본값)
  ( cd "$REPO" && env "$@" docker compose -f deploy/compose.yaml config --format json 2>/dev/null ) |
    python3 -c '
import json,sys
try: doc = json.load(sys.stdin)
except Exception: sys.exit(1)
out = []
for name, svc in sorted((doc.get("services") or {}).items()):
    for p in svc.get("ports") or []:
        pub, tgt = p.get("published"), p.get("target")
        if pub is not None: out.append(f"{name}:{pub}->{tgt}")
print(" ".join(out))'
}

echo "--- compose render: defaults ---"
default_ports=$(render_ports BSVIBE_LOCAL_BACKEND_PORT= BSVIBE_LOCAL_PG_PORT= BSVIBE_LOCAL_REDIS_PORT= BSVIBE_LOCAL_PWA_PORT=)
echo "rendered: $default_ports"
expected="backend:8700->8000 postgres:5442->5432 pwa:3700->3700 redis:6387->6379"
if [ "$default_ports" != "$expected" ]; then
  fail "compose 기본 publish 포트가 렌더링에서 달라졌다: 기대 [$expected] 실제 [$default_ports]"
fi

# 대조군 — 오버라이드가 실제로 먹는지. 이게 없으면 위 검사는
# "값을 하드코딩해도 통과"한다(파라미터화가 죽어도 초록).
echo "--- compose render: overrides (control) ---"
moved=$(render_ports BSVIBE_LOCAL_BACKEND_PORT=18700 BSVIBE_LOCAL_PG_PORT=15442 \
                     BSVIBE_LOCAL_REDIS_PORT=16387 BSVIBE_LOCAL_PWA_PORT=13700)
echo "rendered: $moved"
moved_expected="backend:18700->8000 postgres:15442->5432 pwa:13700->3700 redis:16387->6379"
if [ "$moved" != "$moved_expected" ]; then
  fail "compose 포트 오버라이드가 렌더링에 반영되지 않는다: 기대 [$moved_expected] 실제 [$moved]"
fi

# ===========================================================================
# 2. 인증된 셸 라이브 E2E
# ===========================================================================
# ⚠️ 도구 검사는 자격증명 게이트 **앞**에 있어야 한다.
#
# 실측 2026-09-03: `@playwright/test` 가 package.json 에 선언만 돼 있고 이 머신엔
# 설치돼 있지 않았다(`node_modules` 7/7 자, 그 패키지는 9월 추가 — 빠진 devDep 이
# 13개 중 딱 하나). CI 는 매번 fresh install 이라 초록이었고, 로컬 소비자는 이
# 러너뿐인데 이 러너는 **그 줄에 도달한 적이 없었다.** 자격증명이 없어 늘 SKIP 됐기
# 때문이다. 그대로 뒀으면 형님이 Keychain 에 비밀번호를 넣는 **바로 그 순간**
# `playwright: command not found` 로 죽었을 것이고, 방금 한 행동 탓으로 보였을 것이다.
#
# 게이트 뒤에 두면 같은 함정에 다시 걸린다 — 그래서 앞이다. 그리고 이건 SKIP 이
# 아니라 FAIL 이다: 도구 부재는 사람을 기다리는 상태가 아니라 이 머신의 고장이다.
if ! ( cd "$PWA" && pnpm exec playwright --version ) >/dev/null 2>&1; then
  fail "playwright 실행 불가 ($PWA) — 자격증명이 들어와도 라이브 E2E 는 못 돈다. 고치기: cd $PWA && pnpm install"
fi

password=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$E2E_EMAIL" -w 2>/dev/null)
if [ -z "$password" ]; then
  # 설정 대기는 장애가 아니다 — 사람을 기다리는 것을 알람으로 만들면 그 알람은
  # 곧 무시되고, 진짜 고장이 났을 때 아무도 안 본다. 알림 없이 크게 로그만 남긴다.
  # (렌더링 검사 절반은 이미 돌았고, 그건 실패하면 알린다.)
  echo "SKIP: 라이브 E2E — Keychain 에 자격증명이 없다."
  echo "      설정: security add-generic-password -s $KEYCHAIN_SERVICE -a $E2E_EMAIL -w"
  echo "      (넣기 전까지 이 데몬은 compose 렌더링 검사만 지킨다)"
else
  echo "--- e2e-live stack up ---"
  cd "$REPO" || { fail "cd $REPO 실패"; exit 1; }
  export BSVIBE_E2E_KMS_KEY_B64="$(openssl rand -base64 32)"
  set -a; . "$REPO/deploy/.env.prod"; set +a
  if docker compose -f deploy/compose.yaml -f deploy/compose.e2e-live.yaml up -d postgres redis backend; then
    export BSVIBE_E2E_EMAIL="$E2E_EMAIL"
    export BSVIBE_E2E_PASSWORD="$password"
    echo "--- pnpm test:e2e:live ---"
    # cd 는 절대경로로 — 상대 cd 는 백그라운드 경계를 넘으면 엉뚱한 트리에 떨어진다.
    if ! ( cd "$PWA" && pnpm test:e2e:live ); then
      fail "라이브 인증 E2E 실패 (repo $sha) — 로그: $LOG"
    fi
  else
    fail "일회용 e2e 스택이 안 떴다 (repo $sha)"
  fi
  unset BSVIBE_E2E_PASSWORD password
fi

# ===========================================================================
# 3. 보고 — 실패할 때만. 침묵이 성공이 되지 않게 성공도 로그에는 남긴다.
# ===========================================================================
if [ -n "$failures" ]; then
  if [ -f "$WATCHDOG_ENV" ]; then
    set -a; . "$WATCHDOG_ENV"; set +a
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      --data-urlencode text="$(printf '🚨 라이브 E2E 야간 실행 실패 (repo %s)\n\n%b' "$sha" "$failures")" \
      >/dev/null 2>&1
  else
    echo "no $WATCHDOG_ENV — 알림을 보낼 수 없다"
  fi
  echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) e2e-live-nightly FAILED ====="
  exit 1
fi

echo "===== $(date -u +%Y-%m-%dT%H:%M:%SZ) e2e-live-nightly OK ====="
