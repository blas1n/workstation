#!/usr/bin/env bash
# prod_log_archive.sh — keep a prod container's logs past its recreation.
#
# Docker's json-file log belongs to the CONTAINER. autodeploy recreates the
# bsvibe-prod containers on every merge (`up -d --force-recreate`), and their
# logs go with them — on 2026-10-07 the backend log that held an agent's MCP tool
# calls (#1145) was gone five deploys later. So autodeploy calls this just before
# recreating: one file per container INCARNATION, named by its start time, so a
# second archive of the same container overwrites rather than duplicates.
#
#   archive_prod_container_logs <dir> <keep> <container>...
#
# Keeps the newest <keep> files per container. A container that does not exist
# (first deploy, renamed service) is skipped — never a failure: archiving must
# not be able to block a deploy.

archive_prod_container_logs() {
  local dir="$1" keep="$2"
  shift 2
  mkdir -p "$dir" || return 0
  local c started stamp
  for c in "$@"; do
    started=$(docker inspect -f '{{.State.StartedAt}}' "$c" 2>/dev/null | tr -d '[:space:]')
    [ -n "$started" ] || continue
    # 2026-10-07T06:41:10.123456789Z -> 2026-10-07T06-41-10 (sortable, filename-safe)
    stamp=$(printf '%s' "$started" | cut -c1-19 | tr ':' '-')
    docker logs "$c" > "$dir/$c--$stamp.log" 2>&1 || true
    # Newest first by name (the stamp sorts chronologically); drop past <keep>.
    ls -1 "$dir/$c--"*.log 2>/dev/null | sort -r | tail -n +"$((keep + 1))" | while IFS= read -r old; do
      rm -f "$old"
    done
  done
  return 0
}
