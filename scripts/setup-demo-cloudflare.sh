#!/usr/bin/env bash
#
# setup-demo-cloudflare.sh — Idempotently create the 8 demo DNS records.
#
# Backend (4): api-demo-{gateway,nexus,supervisor,sage}.bsvibe.dev
#   → A 119.67.169.203 (Mac Mini), Proxied
# Frontend (4): demo-{gateway,nexus,supervisor,sage}.bsvibe.dev
#   → CNAME cname.vercel-dns.com, DNS-only initially (Vercel SSL provisions),
#     flip to Proxied after the cert lands.
#
# Auth: needs a Cloudflare API token with `Zone.DNS:Edit` on bsvibe.dev.
#   1. https://dash.cloudflare.com/profile/api-tokens
#   2. "Create Token" → "Edit zone DNS" template → Zone Resources: bsvibe.dev
#   3. Export it:
#        export CLOUDFLARE_API_TOKEN=...
#   Or pass interactively when prompted.
#
# Idempotent: if a record exists with a different content, it is updated;
# if it exists with the desired content, untouched.

set -euo pipefail

ZONE_NAME="bsvibe.dev"
MAC_MINI_IP="${MAC_MINI_IP:-119.67.169.203}"
VERCEL_CNAME="${VERCEL_CNAME:-cname.vercel-dns.com}"

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  read -srp "Cloudflare API token (Zone.DNS:Edit on ${ZONE_NAME}): " CLOUDFLARE_API_TOKEN
  echo
  export CLOUDFLARE_API_TOKEN
fi

cf() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  if [ -n "$data" ]; then
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4${path}" \
      --data-raw "$data"
  else
    curl -fsS -X "$method" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4${path}"
  fi
}

echo "Resolving zone id for ${ZONE_NAME}..."
ZONE_ID=$(cf GET "/zones?name=${ZONE_NAME}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
if not d.get('success') or not d.get('result'):
    print('zone lookup failed:', d, file=sys.stderr)
    sys.exit(1)
print(d['result'][0]['id'])
")
echo "  zone id: ${ZONE_ID}"

upsert() {
  local name="$1"
  local rtype="$2"
  local content="$3"
  local proxied="$4"
  local fqdn="${name}.${ZONE_NAME}"

  local existing
  existing=$(cf GET "/zones/${ZONE_ID}/dns_records?name=${fqdn}&type=${rtype}")
  local rec_id
  rec_id=$(echo "$existing" | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('result') or []
print(r[0]['id'] if r else '')
")

  local proxied_py
  if [ "$proxied" = "true" ]; then proxied_py="True"; else proxied_py="False"; fi
  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
    'type': '${rtype}',
    'name': '${name}',
    'content': '${content}',
    'ttl': 1,
    'proxied': ${proxied_py}
}))
")

  if [ -z "$rec_id" ]; then
    cf POST "/zones/${ZONE_ID}/dns_records" "$payload" >/dev/null
    echo "  + ${fqdn} ${rtype} ${content} (proxied=${proxied})"
  else
    cf PUT "/zones/${ZONE_ID}/dns_records/${rec_id}" "$payload" >/dev/null
    echo "  ~ ${fqdn} ${rtype} ${content} (proxied=${proxied})"
  fi
}

echo
echo "Backend records (Mac Mini, Proxied):"
for sub in api-demo-gateway api-demo-nexus api-demo-supervisor api-demo-sage; do
  upsert "${sub}" A "${MAC_MINI_IP}" true
done

echo
echo "Frontend records (Vercel CNAME, DNS-only initially — flip to Proxied after cert lands):"
for sub in demo-gateway demo-nexus demo-supervisor demo-sage; do
  upsert "${sub}" CNAME "${VERCEL_CNAME}" false
done

echo
echo "Done. Verify:"
echo "  dig +short api-demo-gateway.bsvibe.dev"
echo "  dig +short demo-gateway.bsvibe.dev"
