#!/usr/bin/env bash
# run_liveness.sh — "is an executor run ALIVE right now?"
#
# Sourced by autodeploy.sh (self-disruption guard) so the definition of "alive"
# lives in ONE place and is tested against a real Postgres
# (tests/test_run_liveness.sh).
#
# Liveness is the APP'S OWN contract, not a guess. In bsvibe-app:
#
#   * ``_drive_loop`` refreshes ``ExecutionRun.claimed_at`` at each TURN
#     BOUNDARY only — "a single long turn running a full test suite goes the
#     WHOLE turn without refreshing its claim".
#   * ``agent_worker._stale_claim_lease_s`` = ``2 x executor_task_timeout_s``
#     (default 3600s -> a 7200s lease), and the reaper resets any RUNNING run
#     past that lease back to OPEN.
#
# So the app's answer to "alive?" is: the claim is HELD and not past the lease.
# A run past the lease belongs to the reaper, not to this guard.
#
# The previous query asked ``updated_at > now() - interval '3 minutes'`` and was
# wrong in BOTH directions:
#   * it dropped protection from a live run mid-turn (run abe9e2b9 on
#     2026-08-18: its own declared ``uv run pytest -ra`` took 353s and the run
#     left the DB untouched for 8m39s — the guard logged "in flight" at
#     14:48:57 and force-recreated backend+worker under it at 14:51:01);
#   * it protected OPEN rows that nothing is driving, needlessly blocking deploys.

# Within the lease we normally cannot tell "mid-long-turn" from "crashed" — but
# in ONE case we can, exactly: the drive loop lives IN the worker container, so a
# claim stamped BEFORE that container's current start is ORPHANED and no loop can
# still be holding it. Without this a crashed run blocks every deploy for the full
# 2 h lease (run abe9e2b9 would have, after the recreate that killed it).

# Emit the SQL counting runs whose agent loop is alive and would be destroyed by
# a `docker compose up --force-recreate`.
#   $1 — stale-claim lease in seconds (default 7200 = 2 x the 3600s turn cap)
#   $2 — optional ISO-8601 start time of the container hosting the drive loop;
#        claims older than it are orphaned. Omit to skip the orphan check.
run_liveness_sql() {
  local lease_s="${1:-7200}" loop_started_at="${2:-}" orphan_clause=""
  [ -n "$loop_started_at" ] && orphan_clause="and claimed_at > '${loop_started_at}'::timestamptz "
  printf "%s" "select count(*) from execution_runs \
where status = 'running' \
and claimed_at is not null \
and claimed_at > now() - interval '${lease_s} seconds' \
${orphan_clause}"
}
