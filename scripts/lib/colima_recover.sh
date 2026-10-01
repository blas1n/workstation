#!/usr/bin/env bash
# colima_recover — pure decision helpers for colima-ensure's recovery path.
#
# Extracted after the 2026-10-01 outage (prod down 45 min). The machine rebooted
# at 11:23 KST; the unclean shutdown a minute earlier left the 500GiB data disk
# marked "in use" by an instance that was Stopped, so lima refused to attach it:
#
#   fatal  failed to run attach disk "colima", in use by instance "colima"
#
# Retrying cannot fix that — and the retry made it worse. ``StartInterval 60``
# fired every 60s while ``colima start`` takes 1-3 min, so attempts OVERLAPPED
# and each one leaked a ``limactl usernet`` process; 40 had piled up and load
# average was 8.43. Recovery meant stopping the retry loop by hand first.
#
# Every decision here is a pure function over injected text so the two SAFETY
# GATES are testable: the disk holds prod's postgres data, and ``usernet`` is a
# live instance's networking. Detaching a running VM's disk, or killing a live
# instance's usernet, is damage — not recovery. The gates stay deliberately
# conservative: they refuse whenever the evidence is not unambiguous.
#
# Tests: tests/test_colima_ensure_recovers_stale_disk_lock.sh

# Classify a failed ``colima start`` by its captured output.
#
# ``stale_disk_lock`` is the only kind we act on, because it is the only one a
# retry can never clear. Everything else is ``unknown`` — the transient VZ start
# errors seen 2026-06-22 and 2026-08-11 DO recover on a retry, and must not
# reach the unlock path. Both markers are required: a message that merely says
# "in use" elsewhere must not be read as this.
colima_failure_kind() {
  local text="${1-}"
  case "$text" in
    *"attach disk"*"in use by instance"*) printf 'stale_disk_lock\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# The disk name out of a stale-lock message, or empty.
# Backslashes are stripped first: the hostagent log is JSON, so the message
# arrives as ``attach disk \"colima\"``.
stale_lock_disk_name() {
  local text="${1-}"
  printf '%s' "${text//\\/}" | sed -n 's/.*attach disk "\([^"]*\)".*/\1/p' | head -1
}

# Is it safe to clear the lock on ``instance``'s disk?
#   $1 = ``limactl list`` output, $2 = count of live VM processes, $3 = instance
#
# Both must hold: the instance is listed ``Stopped`` AND no VM process is alive.
# The process count is the stricter of the two signals and wins on disagreement
# — a list that says Stopped while a VM is running is exactly the case where
# detaching the disk would corrupt prod's postgres. An instance missing from the
# list yields an empty status and is refused: we never unlock on the strength of
# some OTHER instance's row.
stale_lock_is_clearable() {
  local list="${1-}" vm_procs="${2-1}" instance="${3-}"
  [ -n "$instance" ] || return 1
  case "$vm_procs" in ''|*[!0-9]*) return 1 ;; esac   # unmeasured → refuse
  [ "$vm_procs" -eq 0 ] || return 1
  local status
  status=$(printf '%s\n' "$list" | awk -v n="$instance" '$1 == n { print $2; exit }')
  [ "$status" = "Stopped" ] || return 1
  return 0
}

# Is it safe to reap leaked ``usernet`` processes?
#   $1 = ``limactl list`` output
#
# Only when NO instance is Running. ``usernet`` is lima's user-mode networking,
# and this machine runs two instances (colima = prod, colima-palworld = game
# server). Killing a live instance's usernet cuts its network, so a single
# Running row vetoes the reap. Leaked processes are cheap to leave behind;
# severing a running server is not.
orphan_reap_is_safe() {
  local list="${1-}"
  printf '%s\n' "$list" | awk 'NR > 1 && $2 == "Running" { found = 1 } END { exit !found }' && return 1
  return 0
}

# How many live VM processes there are — the stricter half of
# ``stale_lock_is_clearable``'s evidence. Reads the machine, so it is the one
# impure helper here; the gate it feeds stays pure and testable.
#
# ⚠️ Do NOT reimplement this with ``pgrep -fc``. Measured 2026-10-01 on macOS
# while colima was Running (so the true answer was ≥1): ``pgrep -fc <pat>``
# errored out and ``pgrep -f <pat> | wc -l`` under-counted, while this
# ``ps``+``grep`` form returned 4. A counter stuck at 0 would make the unlock
# gate pass unconditionally — it would read "no VM is running" while prod's VM
# held the disk, which is precisely the corruption this gate exists to prevent.
# The bracket in each pattern keeps grep from matching itself.
count_vm_processes() {
  ps ax -o command= 2>/dev/null |
    grep -cE '[l]imactl hostagent|[V]irtualization\.VirtualMachine\.xpc' || true
}

# PIDs of ``limactl usernet`` processes, read from a ``ps`` snapshot on stdin.
# Scoped to ``usernet`` on purpose: ``limactl start`` is an in-flight attempt,
# not a leak, and killing it would truncate the very recovery we are running.
orphan_usernet_pids() {
  awk '/limactl[[:space:]]+usernet/ { print $1 }'
}

# Single-flight lock. ``mkdir`` is the atomic primitive (macOS has no flock).
#
# This is the fix for the pile-up: the retry interval is shorter than a start
# takes, so without a lock the agent races itself. A dead holder's lock is taken
# over — a lock that outlives a crash would park auto-recovery forever, which is
# the same class of failure in the opposite direction.
singleflight_acquire() {
  local lock="${1:?lock path required}"
  if mkdir "$lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock/pid"
    return 0
  fi
  local pid
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  printf '%s\n' "$$" > "$lock/pid"
  return 0
}

singleflight_release() {
  rm -rf "${1:?lock path required}"
}
