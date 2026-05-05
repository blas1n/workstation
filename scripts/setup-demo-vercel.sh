#!/usr/bin/env bash
#
# setup-demo-vercel.sh — Idempotently provision the 4 demo Vercel projects.
#
# For each product (BSGateway, BSNexus, BSupervisor, BSage):
#   1. Create a Vercel project named `<product>-demo-app` linked to the same
#      GitHub repo as the prod project, but pinned to `feature/demo-mode`
#      (or `main` after merge — see PRODUCTION_BRANCH below).
#   2. Set demo env vars (NEXT_PUBLIC_BSVIBE_DEMO=1, NEXT_PUBLIC_API_URL,
#      or VITE_* for BSupervisor).
#   3. Attach the public domain `demo-<product>.bsvibe.dev`.
#
# Auth: reads the Vercel token from
#   ~/Library/Application Support/com.vercel.cli/auth.json
# (login via `vercel login` if missing). Override with VERCEL_TOKEN env.
#
# Idempotent: project / env / domain creation 409s are tolerated and treated
# as "already exists, skip" — re-run safely.

set -euo pipefail

# Per-product config: name | repo | rootDirectory | framework | env_prefix
# env_prefix = "NEXT_PUBLIC_" or "VITE_"
PRODUCTS=(
  "bsgateway-demo-app|BSVibe/BSGateway|frontend|nextjs|NEXT_PUBLIC_"
  "bsnexus-demo-app|BSVibe/BSNexus|frontend|nextjs|NEXT_PUBLIC_"
  "bsupervisor-demo-app|BSVibe/BSupervisor|frontend|vite|VITE_"
  "bsage-demo-app|BSVibe/BSage|frontend|nextjs|NEXT_PUBLIC_"
)

PRODUCTION_BRANCH="${PRODUCTION_BRANCH:-feature/demo-mode}"
TEAM_SLUG="${TEAM_SLUG:-blasins-projects}"

# ─── Token ────────────────────────────────────────────────────────────
if [ -z "${VERCEL_TOKEN:-}" ]; then
  AUTH_FILE="$HOME/Library/Application Support/com.vercel.cli/auth.json"
  if [ -f "$AUTH_FILE" ]; then
    VERCEL_TOKEN=$(python3 -c "
import json, re
raw = open('${AUTH_FILE}').read()
m = re.search(r'\"token\":\s*\"([^\"]+)\"', raw)
print(m.group(1) if m else '')
")
  fi
fi
if [ -z "${VERCEL_TOKEN:-}" ]; then
  echo "VERCEL_TOKEN not set and no ${AUTH_FILE}." >&2
  echo "Run 'vercel login' first or export VERCEL_TOKEN=..." >&2
  exit 1
fi

# ─── Resolve team id ─────────────────────────────────────────────────
echo "Resolving team id for slug '${TEAM_SLUG}'..."
TEAM_ID=$(curl -fsS -H "Authorization: Bearer ${VERCEL_TOKEN}" \
  "https://api.vercel.com/v2/teams?slug=${TEAM_SLUG}" |
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('id') or '')
")
if [ -z "$TEAM_ID" ]; then
  echo "  ! could not resolve team — provisioning under personal scope"
  TEAM_QS=""
else
  echo "  team id: ${TEAM_ID}"
  TEAM_QS="?teamId=${TEAM_ID}"
fi

vapi() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local sep="?"
  [[ "$path" == *"?"* ]] && sep="&"
  if [ -n "$data" ]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer ${VERCEL_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.vercel.com${path}${TEAM_QS:+${sep}${TEAM_QS#?}}" \
      --data-raw "$data"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer ${VERCEL_TOKEN}" \
      "https://api.vercel.com${path}${TEAM_QS:+${sep}${TEAM_QS#?}}"
  fi
}

# ─── Per-product provisioning ────────────────────────────────────────
for entry in "${PRODUCTS[@]}"; do
  IFS='|' read -r project_name repo root framework env_prefix <<<"$entry"
  # Map vercel project name → demo-subdomain short name. Hard-coded because
  # BSVibe brand split is "B" prefix on products that start with S, "BS"
  # prefix on others — naive ${var#bs} strips too much.
  case "$project_name" in
    bsgateway-demo-app)   product_short="gateway" ;;
    bsnexus-demo-app)     product_short="nexus" ;;
    bsupervisor-demo-app) product_short="supervisor" ;;
    bsage-demo-app)       product_short="sage" ;;
    *) echo "  ! unknown project ${project_name}, skipping" >&2; continue ;;
  esac
  api_url="https://api-demo-${product_short}.bsvibe.dev"
  frontend_domain="demo-${product_short}.bsvibe.dev"

  echo
  echo "═══ ${project_name} ═══"

  # 1. Create project (idempotent)
  payload=$(python3 -c "
import json
print(json.dumps({
    'name': '${project_name}',
    'framework': '${framework}',
    'rootDirectory': '${root}',
    'gitRepository': {'type': 'github', 'repo': '${repo}'},
}))
")
  resp=$(vapi POST "/v10/projects" "$payload")
  err=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', {}).get('code', ''))")
  if [ "$err" = "conflict" ] || [ "$err" = "already_exists" ] || [ "$err" = "name_already_in_use" ]; then
    echo "  project: already exists"
    project_id=$(vapi GET "/v9/projects/${project_name}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id', ''))")
  else
    project_id=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id', ''))")
    if [ -z "$project_id" ]; then
      echo "  ! project creation failed:" >&2
      echo "$resp" | python3 -m json.tool >&2 | head -10
      continue
    fi
    echo "  project: created (${project_id})"
  fi

  # Pin production branch on the gitRepository link
  vapi PATCH "/v9/projects/${project_id}" "$(python3 -c "
import json
print(json.dumps({'productionBranch': '${PRODUCTION_BRANCH}'}))
")" >/dev/null
  echo "  production branch: ${PRODUCTION_BRANCH}"

  # 2. Env vars — lookup-first, PATCH if exists, POST if not.
  # (Vercel's POST /env returns 200 with item even when value differs from existing,
  # so we can't rely on the conflict code path — always lookup.)
  existing_envs=$(vapi GET "/v9/projects/${project_id}/env")
  add_env() {
    local key="$1"
    local value="$2"
    local env_id
    env_id=$(echo "$existing_envs" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for e in d.get('envs', []):
    if e.get('key') == '${key}':
        print(e['id'])
        break
")
    if [ -n "$env_id" ]; then
      vapi PATCH "/v9/projects/${project_id}/env/${env_id}" "$(python3 -c "
import json
print(json.dumps({'value': '${value}', 'target': ['production', 'preview']}))
")" >/dev/null
      echo "    env ~ ${key}"
    else
      vapi POST "/v10/projects/${project_id}/env" "$(python3 -c "
import json
print(json.dumps({'key': '${key}', 'value': '${value}', 'type': 'plain', 'target': ['production', 'preview']}))
")" >/dev/null
      echo "    env + ${key}"
    fi
  }
  add_env "${env_prefix}BSVIBE_DEMO" "1"
  add_env "${env_prefix}API_URL" "${api_url}"

  # 3. Domain (idempotent)
  domain_resp=$(vapi POST "/v10/projects/${project_id}/domains" "$(python3 -c "
import json
print(json.dumps({'name': '${frontend_domain}'}))
")")
  domain_code=$(echo "$domain_resp" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', {}).get('code', ''))")
  if [ "$domain_code" = "domain_already_in_use" ] || [ "$domain_code" = "already_exists" ]; then
    echo "  domain: ${frontend_domain} already attached"
  elif [ -n "$domain_code" ]; then
    echo "  ! domain ${frontend_domain} failed: ${domain_code}"
  else
    echo "  domain + ${frontend_domain}"
  fi
done

echo
echo "Done. Each demo project is wired to ${PRODUCTION_BRANCH}."
echo "Trigger a deploy by pushing to that branch (or via 'vercel deploy --prebuilt')."
