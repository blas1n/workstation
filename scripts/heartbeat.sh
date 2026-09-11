#!/usr/bin/env bash
# heartbeat — dead-man's-switch PUSH to an OFF-BOX monitor (readiness audit §Ⅳ,
# 게이트 3). Every monitor that runs ON the Mac Mini (watchdog, uptime-probe)
# dies WITH the machine — a power cut / kernel panic / network loss goes
# unnoticed. This pings an external check URL ONLY while prod is actually healthy;
# if the box dies OR prod goes down, the pings stop and the external service
# alerts. Superior to poll-in monitoring (which a CF cache or tunnel quirk can
# fool, and which cannot see a dead machine vs a slow one).
#
# Setup (the one off-box step): create a free "cron/heartbeat" check at
# healthchecks.io (or BetterStack Heartbeats), set its expected period a bit
# ABOVE this interval, and put its ping URL in ~/.bsvibe/heartbeat.env:
#     HEARTBEAT_PING_URL=https://hc-ping.com/<uuid>
# Until that file/URL exists this logs a one-line NOTE and exits 0 (inert).
set -uo pipefail

ENV_FILE="${HEARTBEAT_ENV:-$HOME/.bsvibe/heartbeat.env}"
HEALTH_URL="${BSVIBE_HEALTH_URL:-https://api.bsvibe.dev/api/health}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
PING_URL="${HEARTBEAT_PING_URL:-}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [ -z "$PING_URL" ]; then
  echo "[$ts] NOTE: HEARTBEAT_PING_URL unset ($ENV_FILE) — off-box heartbeat inert." >&2
  exit 0
fi

# Only ping while prod actually answers ITS OWN health route with 200.
# ``/api/health`` returns {"status":"ok","version":…,"git_sha":…}.
#
# This used to probe ``/api/v1/health`` — a path that DOES NOT EXIST — and accept
# "any real HTTP response (200/404/401…)" as healthy. So the 404 that Caddy or
# Cloudflare returns with the backend completely gone read as "prod is up", and
# the heartbeat would have kept pinging happily through exactly the outage it
# exists to catch. A check that cannot go red measures nothing.
code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "$HEALTH_URL" 2>/dev/null)"
code="${code:-000}"
if [ "$code" != "200" ]; then
  echo "[$ts] prod unhealthy (HTTP $code) — withholding heartbeat so the off-box check fires." >&2
  exit 1
fi

# ``/api/health`` is settings-in-settings-out: it touches no database and no
# Supabase. On 2026-09-11 Supabase was paused and login was broken while that
# route answered 200 THROUGH THE WHOLE OUTAGE — so a heartbeat gated on it alone
# would have kept pinging happily and the dead-man's switch would never fire.
#
# The deep reading exercises the auth dependency. A 4xx is HEALTHY here: it means
# the app processed the request and its dependency answered (these credentials
# are deliberately bogus, and the call creates nothing). Only 5xx / no-connection
# mean the dependency is gone.
DEEP_URL="${BSVIBE_DEEP_URL:-https://api.bsvibe.dev/api/auth/login}"
deep="$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
  -X POST -H 'Content-Type: application/json' \
  --data '{"email":"offbox-probe@invalid.example","password":"not-a-real-password"}' \
  "$DEEP_URL" 2>/dev/null)"
deep="${deep:-000}"
case "$deep" in
  2??|4??) ;;
  *)
    echo "[$ts] app is up but its auth dependency is down ($DEEP_URL HTTP $deep) — withholding heartbeat." >&2
    exit 1
    ;;
esac

# Healthy — ping the dead-man's-switch. ``/fail`` is not used; absence IS the signal.
if curl -fsS -m 15 "$PING_URL" >/dev/null 2>&1; then
  exit 0
fi
echo "[$ts] heartbeat ping to the off-box monitor failed (network?) — will retry." >&2
exit 1
