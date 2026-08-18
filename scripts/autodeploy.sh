#!/bin/bash
# Auto-deploy: fetch origin/main, pull + rebuild if changed
# Run via launchd every 2 minutes

export PATH="/opt/homebrew/bin:$PATH"

# Pin the docker context. The CLI's *current* context is global user state — any
# `colima start <other-profile>` (or a stray `docker context use`) silently
# repoints every docker/compose call in this script at that VM. It does not
# fail: compose happily BUILDS the images and STARTS a full duplicate stack —
# its own postgres, its own redis, empty — inside the wrong VM, writes "Done",
# and leaves the real containers untouched on their old code. Both VMs then
# publish the same host ports, so a restart can hand live traffic to the empty
# copy (2026-07-13: the current context had drifted to `colima-palworld`; the
# bsvibe-app fix built + "deployed" into that VM three cycles running while prod
# kept serving 14-hour-old code).
export DOCKER_CONTEXT=colima

PROJECTS=(bloasis BSGateway BSNexus bsai BSForge BSage BSupervisor)
# Projects with a public demo stack (deploy/docker-compose.demo.yml + .env.demo)
DEMO_PROJECTS=(BSGateway BSNexus BSage BSupervisor)
LOG_DIR=~/Works/_infra/logs
LOG=$LOG_DIR/autodeploy.log
# Per-project state files recording the commit hash of the last
# *successfully deployed* image. Compared against LOCAL — a mismatch
# means the build artifact is stale even when the source tree matches
# origin/main, which is the failure mode that kept BSNexus's PR #53
# from going live for ~30 minutes after merge (2026-05-05). Without
# this check, ``LOCAL == REMOTE`` is taken as "all good" and rebuild
# is skipped, even when the running container is older than LOCAL.
mkdir -p "$LOG_DIR"

for name in "${PROJECTS[@]}"; do
  BARE=~/Works/${name}/.bare
  WORK=~/Works/${name}/main
  COMPOSE=${WORK}/deploy/docker-compose.yml
  DEMO_COMPOSE=${WORK}/deploy/docker-compose.demo.yml
  DEMO_ENV=${WORK}/deploy/.env.demo
  DEPLOYED_FILE=$LOG_DIR/${name}.deployed

  [ ! -d "$BARE" ] && continue

  # fetch refspec이 없으면 추가 (bare repo에서 origin/main ref 생성에 필요)
  if ! git -C "$BARE" config --get remote.origin.fetch &>/dev/null; then
    git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  fi

  git -C "$BARE" fetch origin main --quiet 2>/dev/null
  # Also fetch inside $WORK. When $WORK is a linked worktree of $BARE this
  # is redundant (shared object store + refs). But when $WORK is a
  # *standalone clone* — its own .git, its own origin remote — the $BARE
  # fetch never advances $WORK's refs/remotes/origin/main, so the
  # ``git -C $WORK merge origin/main --ff-only`` below resolves a stale
  # ref, reports "Already up to date", and the poller rebuilds stale code
  # every cycle forever. Fetching where we merge fixes both layouts.
  git -C "$WORK" fetch origin main --quiet 2>/dev/null
  LOCAL=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
  REMOTE=$(git -C "$BARE" rev-parse origin/main 2>/dev/null)
  DEPLOYED=$(cat "$DEPLOYED_FILE" 2>/dev/null)

  [ -z "$REMOTE" ] && continue

  # Trigger rebuild when EITHER:
  #   * source tree diverged from origin/main (normal: PR was merged)
  #   * source tree matches origin/main BUT the recorded deployed
  #     commit doesn't (the container is stale because someone reset
  #     the worktree, or this is the very first deploy after the
  #     state-file was introduced)
  needs_merge=false
  needs_build=false
  [ "$LOCAL" != "$REMOTE" ] && needs_merge=true
  [ "$DEPLOYED" != "$REMOTE" ] && needs_build=true

  if [ "$needs_merge" = false ] && [ "$needs_build" = false ]; then
    continue
  fi

  # G-A — do not recreate the BSNexus app container while a work phase
  # is in flight: a `docker-compose up --force-recreate` kills the
  # in-process qwen3 work phase and orphans its RunAttempt. Defer the
  # deploy until no RunAttempt is `running`. Capped at 60 min so a
  # genuine zombie (a `running` row whose process already died) can't
  # block deploys forever — past the cap we deploy anyway and the
  # app's startup reaper (reap_orphaned_run_attempts) cleans it up.
  if [ "$name" = "BSNexus" ]; then
    DEFER_FILE=$LOG_DIR/${name}.deploy-deferred-since
    running=$(docker exec bsnexus-postgres psql -U bsnexus -d bsnexus -tAc \
      "select count(*) from run_attempts where status='running'" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$running" ] && [ "$running" -gt 0 ] 2>/dev/null; then
      now=$(date +%s)
      [ -f "$DEFER_FILE" ] || echo "$now" > "$DEFER_FILE"
      since=$(cat "$DEFER_FILE" 2>/dev/null || echo "$now")
      if [ $((now - since)) -lt 3600 ]; then
        echo "$(date) [${name}] Work phase in flight (${running} running) — deferring deploy" >> "$LOG"
        continue
      fi
      echo "$(date) [${name}] Deferral cap reached — deploying anyway (startup reaper will clean zombies)" >> "$LOG"
    fi
    rm -f "$DEFER_FILE"
  fi

  if [ "$needs_merge" = true ]; then
    echo "$(date) [${name}] Deploying ${REMOTE:0:7}..." >> "$LOG"
    if ! git -C "$WORK" merge origin/main --ff-only 2>> "$LOG"; then
      echo "$(date) [${name}] Merge failed, skipping rebuild" >> "$LOG"
      continue
    fi
  else
    echo "$(date) [${name}] Stale image (deployed=${DEPLOYED:0:7} vs source=${REMOTE:0:7}) — rebuilding" >> "$LOG"
  fi

  if [ -f "$COMPOSE" ]; then
    PROJECT_NAME=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    # ``--force-recreate`` (Round 4 Phase 8 dogfood 2026-05-11): without
    # this, ``up -d --build`` rebuilds the image but compose silently
    # reuses an existing container when the image ID hash collides with
    # the previous build (cache-hit on layers + identical context →
    # identical image SHA → no recreate). Symptom: ``.deployed`` file
    # bumped to the new commit, but the container keeps running the old
    # code. Force-recreate is safe here because we only enter this
    # block when needs_merge or needs_build was true — meaning we
    # actually want to flip to the new code.
    if ! docker-compose -p "$PROJECT_NAME" -f "$COMPOSE" up -d --build --force-recreate >> "$LOG" 2>&1; then
      echo "$(date) [${name}] Prod build failed!" >> "$LOG"
      continue
    fi
  fi

  # Rebuild demo stack alongside prod (only if demo files exist for this project)
  is_demo_project=false
  for dp in "${DEMO_PROJECTS[@]}"; do
    [ "$dp" = "$name" ] && is_demo_project=true && break
  done
  if [ "$is_demo_project" = true ] && [ -f "$DEMO_COMPOSE" ] && [ -f "$DEMO_ENV" ]; then
    DEMO_PROJECT_NAME="$(echo "$name" | tr '[:upper:]' '[:lower:]')-demo"
    if ! docker-compose -p "$DEMO_PROJECT_NAME" -f "$DEMO_COMPOSE" --env-file "$DEMO_ENV" up -d --build --force-recreate >> "$LOG" 2>&1; then
      echo "$(date) [${name}] Demo build failed (non-fatal)!" >> "$LOG"
      # Demo failure is non-fatal — prod kept running
    fi
  fi

  # Record the commit we just deployed so the next loop knows the
  # container matches LOCAL even when LOCAL == REMOTE.
  echo "$REMOTE" > "$DEPLOYED_FILE"
  echo "$(date) [${name}] Done" >> "$LOG"
done

# --- bsvibe-app (separate block — distinct compose layout) ---
# The legacy projects above use `docker-compose -f deploy/docker-compose.yml`;
# bsvibe-app uses `docker compose -f deploy/compose.yaml -f deploy/compose.prod.yaml
# --env-file deploy/.env.prod` with project `bsvibe-prod`. PWA prod is on Vercel
# (auto-deploys on main merge), so we only rebuild backend + worker here.
# Postgres + Redis are stateful — don't touch.
{
  name="bsvibe-app"
  BARE=~/Works/${name}/.bare
  WORK=~/Works/${name}/main
  COMPOSE_BASE=${WORK}/deploy/compose.yaml
  COMPOSE_PROD=${WORK}/deploy/compose.prod.yaml
  ENV_PROD=${WORK}/deploy/.env.prod
  DEPLOYED_FILE=$LOG_DIR/${name}.deployed

  if [ -d "$BARE" ] && [ -f "$COMPOSE_BASE" ] && [ -f "$COMPOSE_PROD" ] && [ -f "$ENV_PROD" ]; then
    if ! git -C "$BARE" config --get remote.origin.fetch &>/dev/null; then
      git -C "$BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
    fi

    git -C "$BARE" fetch origin main --quiet 2>/dev/null
    git -C "$WORK" fetch origin main --quiet 2>/dev/null
    LOCAL=$(git -C "$WORK" rev-parse HEAD 2>/dev/null)
    REMOTE=$(git -C "$BARE" rev-parse origin/main 2>/dev/null)
    DEPLOYED=$(cat "$DEPLOYED_FILE" 2>/dev/null)

    # Deploy scope. The cheap path force-recreates only backend+worker (same-tag
    # app images that `up -d --build` alone would NOT recreate). Infra services
    # (sandbox-dind/redis/postgres) are not depends_on of those, so a change to
    # their compose/Dockerfile would otherwise never deploy. When THIS deploy
    # touches anything under deploy/ (compose, Dockerfile.sandbox-dind, ...),
    # recreate the WHOLE stack so infra changes land regardless of image tag;
    # otherwise stay cheap and never needlessly restart sandbox-dind (which would
    # kill in-flight verify runs) / postgres / redis.
    # The runtime stack recreated on an infra change — pwa is intentionally
    # EXCLUDED (Vercel-fronted; recreating it here would couple the deploy to a
    # pwa build and needlessly rebuild/restart it).
    RUNTIME_STACK="backend worker sandbox-dind redis postgres"
    RECREATE_SVCS="backend worker"
    if [ -z "$DEPLOYED" ] || ! git -C "$BARE" cat-file -e "${DEPLOYED}^{commit}" 2>/dev/null; then
      RECREATE_SVCS="$RUNTIME_STACK"   # unknown / first deploy -> recreate the runtime stack (safe)
    elif [ -n "$(git -C "$BARE" diff --name-only "$DEPLOYED" "$REMOTE" -- deploy/ 2>/dev/null)" ]; then
      RECREATE_SVCS="$RUNTIME_STACK"   # deploy/ (infra) changed -> recreate the runtime stack
    fi

    needs_merge=false
    needs_build=false
    [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ] && needs_merge=true
    [ -n "$REMOTE" ] && [ "$DEPLOYED" != "$REMOTE" ] && needs_build=true

    if [ -n "$REMOTE" ] && { [ "$needs_merge" = true ] || [ "$needs_build" = true ]; }; then
      proceed=true
      # Dogfood self-disruption guard: bsvibe-app IS the platform, so a PR merged
      # to its OWN main (e.g. BSVibe auto-merging a dogfood change) triggers THIS
      # rebuild — which force-recreates backend+worker and drops the backend MCP
      # server mid-run, so any of BSVibe's OWN in-flight executor runs lose their
      # tools and WEDGE (observed 2026-07-30: a conflict re-drive died on
      # claude_code_unsanctioned_tools when autodeploy rebuilt under it). Defer the
      # rebuild while an executor run's agent loop is ALIVE.
      #
      # "Alive" is the APP'S definition, not a guess — see scripts/lib/run_liveness.sh
      # and tests/test_run_liveness.sh. The earlier "updated_at within 3 minutes"
      # rule was wrong in BOTH directions and cost a live run on 2026-08-18: run
      # abe9e2b9 ran its own declared `uv run pytest -ra` (353 s) and left the DB
      # untouched for 8m39s, so this guard logged "in flight" at 14:48:57 and then
      # force-recreated backend+worker under that same run at 14:51:01. It also
      # protected OPEN rows that nothing is driving, needlessly blocking deploys.
      DEFER_FILE=$LOG_DIR/${name}.deploy-deferred-since
      # Lease = 2 x the app's executor turn cap (agent_worker._stale_claim_lease_s).
      # Past it the run belongs to the app's stale-claim reaper, not to this guard,
      # so the query self-expires and a zombie claim can never block deploys forever.
      turn_cap_s=$(docker exec bsvibe-prod-backend-1 printenv BSVIBE_EXECUTOR_TASK_TIMEOUT_S 2>/dev/null | tr -d '[:space:]')
      [ -n "$turn_cap_s" ] || turn_cap_s=3600
      lease_s=$(( ${turn_cap_s%.*} * 2 ))
      # The drive loop lives IN the worker container, so a claim stamped before
      # that container's CURRENT start is orphaned — no loop can still hold it.
      # Without this, one crashed run blocks every deploy for the whole lease.
      loop_started=$(docker inspect -f '{{.State.StartedAt}}' bsvibe-prod-worker-1 2>/dev/null | tr -d '[:space:]')
      # shellcheck source=lib/run_liveness.sh
      . "$(dirname "$0")/lib/run_liveness.sh"
      running=$(docker exec bsvibe-prod-postgres-1 psql -U bsvibe -d bsvibe -tAc \
        "$(run_liveness_sql "$lease_s" "$loop_started")" 2>/dev/null | tr -d '[:space:]')
      # Safety cap ABOVE the lease: the query already self-expires, so this only
      # catches a state we did not foresee (e.g. a claim being refreshed forever).
      defer_cap_s=$(( lease_s + 900 ))
      if [ -n "$running" ] && [ "$running" -gt 0 ] 2>/dev/null; then
        now=$(date +%s)
        [ -f "$DEFER_FILE" ] || echo "$now" > "$DEFER_FILE"
        since=$(cat "$DEFER_FILE" 2>/dev/null || echo "$now")
        if [ $((now - since)) -lt "$defer_cap_s" ]; then
          echo "$(date) [${name}] ${running} executor run(s) in flight — deferring rebuild (self-disruption guard)" >> "$LOG"
          proceed=false
        else
          echo "$(date) [${name}] Deferral cap ($((defer_cap_s/60))m) reached — rebuilding anyway (reaper cleans wedged runs)" >> "$LOG"
          rm -f "$DEFER_FILE"
        fi
      else
        rm -f "$DEFER_FILE"
      fi
      if [ "$needs_merge" = true ]; then
        echo "$(date) [${name}] Deploying ${REMOTE:0:7}..." >> "$LOG"
        if ! git -C "$WORK" merge origin/main --ff-only 2>> "$LOG"; then
          echo "$(date) [${name}] Merge failed, skipping rebuild" >> "$LOG"
          proceed=false
        fi
      else
        echo "$(date) [${name}] Stale image (deployed=${DEPLOYED:0:7} vs source=${REMOTE:0:7}) — rebuilding" >> "$LOG"
      fi

      if [ "$proceed" = true ]; then
        [ -z "$RECREATE_SVCS" ] && echo "$(date) [${name}] deploy/ changed — recreating full stack" >> "$LOG"
        # sandbox-dind carries a FIXED `container_name`, and `--force-recreate`
        # renames the old container to `<id>_bsvibe-sandbox-dind` before creating
        # the replacement. If a previous run died between those two steps, the
        # leftover still holds (or half-holds) the name and every later recreate
        # fails with "Conflict. The container name is already in use" — taking
        # backend+worker DOWN with it (observed 2026-08-03: a deploy/ change hit
        # this and left the whole stack in `Created`). Sweep the leftovers first;
        # the live container is untouched because its name has no `_` prefix.
        for stale in $(docker ps -aq --filter 'name=_bsvibe-sandbox-dind' 2>/dev/null); do
          echo "$(date) [${name}] removing stale sandbox-dind leftover $stale" >> "$LOG"
          docker rm -f "$stale" >> "$LOG" 2>&1 || true
        done
        # What is actually being deployed, surfaced at /api/health -> git_sha.
        # compose.prod.yaml reads `${GIT_SHA:-prod}`; nobody ever exported it, so
        # the endpoint reported the literal "prod" forever and there was no way
        # to ask "is what merged what is running?". That question matters: on
        # 2026-08-10 this poller stopped firing for 2.5h and a merged+CI-green PR
        # simply never deployed, with nothing anywhere to show the drift.
        GIT_SHA=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null || echo prod)
        export GIT_SHA
        # shellcheck disable=SC2086 -- intentional word-split: empty RECREATE_SVCS = all services
        if docker compose -p bsvibe-prod \
             -f "$COMPOSE_BASE" -f "$COMPOSE_PROD" --env-file "$ENV_PROD" \
             up -d --build --force-recreate $RECREATE_SVCS >> "$LOG" 2>&1; then
          echo "$REMOTE" > "$DEPLOYED_FILE"
          echo "$(date) [${name}] Done" >> "$LOG"
          # Reclaim the previous (now-dangling) image + aged build cache so
          # rebuilds don't accumulate — the 451GB image pileup that nearly filled
          # the dev+prod disk (2026-08-03). Dangling-only (NOT -a) so base images
          # for the next build survive; running containers keep their images.
          docker image prune -f >> "$LOG" 2>&1 || true
          docker builder prune -f --filter 'until=168h' >> "$LOG" 2>&1 || true
        else
          echo "$(date) [${name}] Prod build failed!" >> "$LOG"
        fi
      fi
    fi
  fi
}
