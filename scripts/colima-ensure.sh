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
#
# ── 2026-10-01: retrying was not enough, and the retry itself did harm ────────
# The machine rebooted at 11:23 KST and prod stayed down 45 minutes. Two faults
# compounded, and this script now addresses both:
#
#  1. The unclean shutdown left the 500GiB data disk marked "in use" by an
#     instance that was Stopped, so lima refused to attach it:
#       fatal  failed to run attach disk "colima", in use by instance "colima"
#     No number of retries clears that. It needs ``limactl disk unlock``.
#  2. ``StartInterval 60`` fires every 60s but ``colima start`` takes 1-3 min, so
#     attempts OVERLAPPED. Each overlap leaked a ``limactl usernet`` process —
#     40 had piled up and load average was 8.43. Recovery required stopping this
#     agent by hand first, i.e. the auto-recovery was blocking recovery.
#
# The unlock is gated, not automatic: the disk holds prod's postgres data, so it
# is cleared only when the instance is provably Stopped AND no VM process is
# alive. See scripts/lib/colima_recover.sh for the gates and what they refuse.
set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
# colima keeps its lima state here; ``limactl`` needs it to see the instance.
export LIMA_HOME="${LIMA_HOME:-$HOME/.colima/_lima}"
LOCK_DIR="${COLIMA_ENSURE_LOCK:-${TMPDIR:-/tmp}/colima-ensure.lock}"

# shellcheck source=lib/colima_recover.sh
source "$(cd "$(dirname "$0")" && pwd)/lib/colima_recover.sh"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

# ── single-flight ────────────────────────────────────────────────────────────
# Before anything else: a second attempt while the first is still starting is
# what leaked 40 processes. Exiting 0 here is deliberate — an attempt IS in
# flight, so this tick has nothing to report as a failure.
if ! singleflight_acquire "$LOCK_DIR"; then
  exit 0
fi
trap 'singleflight_release "$LOCK_DIR"' EXIT

if colima status >/dev/null 2>&1; then
  exit 0  # up — nothing to do (the common case)
fi

log "colima is DOWN — starting ..."

# Clear leaked usernet processes from earlier overlapping attempts, but only
# when no instance is Running: usernet is a live instance's networking, and this
# machine also runs colima-palworld.
instances="$(limactl list 2>/dev/null)"
if orphan_reap_is_safe "$instances"; then
  leaked="$(ps ax -o pid,command= 2>/dev/null | orphan_usernet_pids | tr '\n' ' ')"
  if [ -n "${leaked// /}" ]; then
    log "reaping leaked usernet processes: $leaked"
    # shellcheck disable=SC2086 # intentional word splitting: a pid list
    kill $leaked 2>/dev/null || true
    sleep 2
  fi
fi

start_out="$(colima start 2>&1)"
if [ -z "${start_out##*done*}" ] && colima status >/dev/null 2>&1; then
  log "colima started."
  exit 0
fi

# ── the one failure a retry cannot clear ─────────────────────────────────────
if [ "$(colima_failure_kind "$start_out")" = stale_disk_lock ]; then
  disk="$(stale_lock_disk_name "$start_out")"
  instances="$(limactl list 2>/dev/null)"
  vm_procs="$(count_vm_processes)"
  if [ -n "$disk" ] && stale_lock_is_clearable "$instances" "$vm_procs" "$disk"; then
    log "stale disk lock on \"$disk\" (instance Stopped, VM processes=$vm_procs) — unlocking"
    if limactl disk unlock "$disk" >/dev/null 2>&1; then
      if colima start >/dev/null 2>&1 && colima status >/dev/null 2>&1; then
        log "colima started after clearing the stale lock on \"$disk\"."
        exit 0
      fi
      log "start still FAILED after unlocking \"$disk\" — will retry next interval."
    else
      log "limactl disk unlock \"$disk\" FAILED — will retry next interval."
    fi
  else
    # Refusing is the correct outcome, not an error to work around: the disk
    # carries prod's postgres data. Say WHY, so the next reader is not tempted
    # to unlock it by hand on the strength of the message alone.
    log "stale disk lock on \"$disk\" but NOT provably safe to clear" \
        "(VM processes=$vm_procs) — refusing. Check \`limactl list\` before touching it."
  fi
fi

log "colima start FAILED — will retry next interval."
exit 1
