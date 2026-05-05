#!/usr/bin/env bash
#
# setup-demo-stack.sh — One-stop orchestrator for the BSVibe public demo.
#
# Calls each step idempotently. Re-running is safe; existing resources
# are detected and left alone.
#
# Steps (numbered for skip/resume):
#   1. Cloudflare DNS — 8 records (4 backend A + 4 frontend CNAME)
#   2. Vercel — 4 demo projects + env vars + domains
#   3. Caddy reload — pick up the 4 api-demo-* entries already in ~/Caddyfile
#   4. Demo backend Docker stacks — first build (autodeploy handles subsequent)
#   5. GC cron — load launchd agent
#   6. Health probes
#
# Usage:
#   setup-demo-stack.sh              # run all steps interactively
#   setup-demo-stack.sh 1            # only step 1
#   setup-demo-stack.sh 1 2 6        # steps 1, 2, and 6
#
# Required env (or interactively prompted):
#   CLOUDFLARE_API_TOKEN  — Zone.DNS:Edit on bsvibe.dev
#   VERCEL_TOKEN          — auto-loaded from `~/Library/Application Support/com.vercel.cli/auth.json`
#                           if `vercel login` ran.

set -euo pipefail

INFRA_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"

steps="${*:-1 2 3 4 5 6}"
should_run() {
  local n="$1"
  for s in $steps; do
    [ "$s" = "$n" ] && return 0
  done
  return 1
}

banner() {
  echo
  echo "═══════════════════════════════════════════════════════════════"
  echo "  ${1}"
  echo "═══════════════════════════════════════════════════════════════"
}

# ─── 1. Cloudflare DNS ────────────────────────────────────────────────
if should_run 1; then
  banner "Step 1 — Cloudflare DNS (8 records)"
  bash "${INFRA_SCRIPTS}/setup-demo-cloudflare.sh"
fi

# ─── 2. Vercel demo projects ─────────────────────────────────────────
if should_run 2; then
  banner "Step 2 — Vercel demo projects (4)"
  bash "${INFRA_SCRIPTS}/setup-demo-vercel.sh"
fi

# ─── 3. Caddy reload ─────────────────────────────────────────────────
if should_run 3; then
  banner "Step 3 — Caddy reload"
  if ! command -v caddy >/dev/null 2>&1; then
    echo "  ! caddy not on PATH; skipping reload"
  else
    caddy reload --config "$HOME/Caddyfile"
    echo "  reloaded ~/Caddyfile (api-demo-* entries should be picked up)"
  fi
fi

# ─── 4. First Docker bring-up ────────────────────────────────────────
if should_run 4; then
  banner "Step 4 — Demo backend Docker stacks (first build)"
  for p in BSGateway BSNexus BSupervisor BSage; do
    lc=$(echo "$p" | tr '[:upper:]' '[:lower:]')
    work="$HOME/Works/$p/main"
    compose="$work/deploy/docker-compose.demo.yml"
    envfile="$work/deploy/.env.demo"
    if [ ! -f "$compose" ]; then
      echo "  ! ${p}: ${compose} missing — has feature/demo-mode merged to main?"
      continue
    fi
    if [ ! -f "$envfile" ]; then
      echo "  ! ${p}: ${envfile} missing — copy from worktree or .env.demo.example"
      continue
    fi
    echo "  bringing up ${p} demo stack..."
    (cd "$work" && docker compose -p "${lc}-demo" \
      -f deploy/docker-compose.demo.yml \
      --env-file deploy/.env.demo \
      up -d --build) || echo "  ! ${p} build failed"
  done
fi

# ─── 5. GC cron (launchd) ────────────────────────────────────────────
if should_run 5; then
  banner "Step 5 — GC cron (launchd)"
  plist_src="$HOME/Works/_infra/launchd/com.blas1n.bsvibe-demo-gc.plist"
  plist_dest="$HOME/Library/LaunchAgents/com.blas1n.bsvibe-demo-gc.plist"
  if [ ! -e "$plist_dest" ]; then
    ln -s "$plist_src" "$plist_dest"
    echo "  symlinked plist"
  fi
  launchctl unload "$plist_dest" 2>/dev/null || true
  launchctl load "$plist_dest"
  if launchctl list | grep -q "bsvibe-demo-gc"; then
    echo "  loaded — runs every 3600s (logs: ~/Works/_infra/logs/bsvibe-demo-gc.log)"
  else
    echo "  ! load failed; check launchctl error output"
  fi
fi

# ─── 6. Health probes ────────────────────────────────────────────────
if should_run 6; then
  banner "Step 6 — Health probes"
  for sub in api-demo-gateway api-demo-nexus api-demo-supervisor api-demo-sage; do
    case "$sub" in
      api-demo-supervisor|api-demo-sage) path="/api/health" ;;
      *) path="/health" ;;
    esac
    url="https://${sub}.bsvibe.dev${path}"
    if curl -fsS -o /dev/null -m 10 "$url"; then
      echo "  ✓ ${url}"
    else
      echo "  ✗ ${url} (DNS pending or backend down)"
    fi
  done
  echo
  for sub in demo-gateway demo-nexus demo-supervisor demo-sage; do
    url="https://${sub}.bsvibe.dev"
    code=$(curl -fsS -o /dev/null -w '%{http_code}' -m 10 "$url" || echo "ERR")
    echo "  ${url} → HTTP ${code}"
  done
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  Done. Soft-launch checklist: ~/Docs/BSVibe_Demo_Soft_Launch_Checklist.md"
echo "═══════════════════════════════════════════════════════════════"
