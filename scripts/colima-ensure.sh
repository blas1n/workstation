#!/usr/bin/env bash
# colima-ensure — keep the docker VM (colima) up so the prod stack can run.
#
# Why this exists (readiness audit §Ⅳ, 게이트 3): prod (postgres/backend/worker/
# redis) all run on colima. The brew-managed launchd unit
# (homebrew.mxcl.colima) runs ``colima start -f`` at boot, but its
# ``KeepAlive{SuccessfulExit:true}`` does NOT retry a FAILED start — so a
# transient VZ (Virtualization.framework) start error at boot (observed
# 2026-06-22, 2026-08-11: "error starting vm: exit status 1") leaves docker down
# with no auto-recovery, and every ``restart: unless-stopped`` container with it.
# This agent retries: it is a NO-OP while colima is up, and starts it when down.
# It never STOPS colima. Editing the brew plist is not durable (brew regenerates
# it); a separate tracked unit is.
set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
LOG_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if colima status >/dev/null 2>&1; then
  exit 0  # up — nothing to do (the common case)
fi

echo "[$LOG_TS] colima is DOWN — starting ..." >&2
if colima start >/dev/null 2>&1; then
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] colima started." >&2
  exit 0
fi
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] colima start FAILED — will retry next interval." >&2
exit 1
