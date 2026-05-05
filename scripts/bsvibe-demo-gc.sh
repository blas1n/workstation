#!/usr/bin/env bash
#
# bsvibe-demo-gc.sh — hourly garbage collector for the demo stack.
#
# Triggers each product's `python -m <product>.demo.gc` inside its demo
# container. Tenants whose `settings->>'last_active_at'` is older than
# 2 hours are cascade-deleted.
#
# Schedule via crontab:
#   17 * * * * /Users/blasin/Works/_infra/scripts/bsvibe-demo-gc.sh
#
# Or via launchd (preferred on macOS — survives reboots, integrates with
# `launchctl print`):
#   ln -s ~/Works/_infra/launchd/com.blas1n.bsvibe-demo-gc.plist \
#         ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.blas1n.bsvibe-demo-gc.plist
#
# Logs to ~/Works/_infra/logs/bsvibe-demo-gc.log.

set -uo pipefail

export PATH="/opt/homebrew/bin:$PATH"

LOG=~/Works/_infra/logs/bsvibe-demo-gc.log
mkdir -p "$(dirname "$LOG")"

ts() {
  date '+%Y-%m-%d %H:%M:%S'
}

run_gc() {
  local product="$1"
  local lc
  lc="$(echo "$product" | tr '[:upper:]' '[:lower:]')"
  local container="${lc}-demo-app"
  # Each product's demo container has its own __main__ entrypoint that
  # imports its config + bsvibe-demo's run_gc_cli helper. Module path
  # mirrors the product package layout.
  local module
  case "$product" in
    BSGateway)
      module="bsgateway.demo.gc"
      ;;
    BSNexus)
      module="backend.src.demo.gc"
      ;;
    BSupervisor|BSage)
      # Shared-tenant products — no per-visitor data to GC.
      echo "$(ts) [${product}] shared-tenant demo, no GC needed" >> "$LOG"
      return 0
      ;;
    *)
      echo "$(ts) [${product}] unknown product" >> "$LOG"
      return 1
      ;;
  esac

  if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
    echo "$(ts) [${product}] container ${container} not running, skipping" >> "$LOG"
    return 0
  fi

  if docker exec "$container" python -m "$module" >> "$LOG" 2>&1; then
    echo "$(ts) [${product}] gc ok" >> "$LOG"
  else
    echo "$(ts) [${product}] gc FAILED" >> "$LOG"
    # Optional: ping a Telegram or alert webhook here. For now, log only.
    return 1
  fi
}

echo "$(ts) demo-gc tick start" >> "$LOG"

failed=0
for p in BSGateway BSNexus BSupervisor BSage; do
  run_gc "$p" || failed=$((failed + 1))
done

if [ $failed -gt 0 ]; then
  echo "$(ts) demo-gc tick complete with $failed failure(s)" >> "$LOG"
  exit 1
fi
echo "$(ts) demo-gc tick complete" >> "$LOG"
