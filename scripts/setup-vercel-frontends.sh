#!/usr/bin/env bash
#
# BSVibe Frontend Vercel Setup
#
# Connects each frontend project to Vercel for automatic deployment.
# Run once to set up, then every push to main auto-deploys.
#
# Prerequisites:
#   - Vercel CLI: npm i -g vercel
#   - Logged in: vercel login
#   - Domain bsvibe.dev configured in Vercel

set -euo pipefail

echo "═══ BSVibe Frontend Vercel Setup ═══"
echo ""

# ─── 1. bsvibe.dev (main site) ───
echo "1. bsvibe.dev (landing + docs)"
echo "   Repo: blas1n/bsvibe-site"
echo "   Domain: bsvibe.dev"
echo ""
echo "   Setup:"
echo "   cd ~/Works/bsvibe-site && vercel link"
echo "   vercel domains add bsvibe.dev"
echo "   # Then: push to main → auto deploys"
echo ""

# ─── 2. BSGateway frontend ───
echo "2. gateway.bsvibe.dev"
echo "   Source: ~/Works/BSGateway/main/frontend/"
echo ""
echo "   Option A — Vercel (recommended for SPA):"
echo "   cd ~/Works/BSGateway/main/frontend && vercel link"
echo "   vercel domains add gateway.bsvibe.dev"
echo ""
echo "   Option B — Served by FastAPI backend:"
echo "   Frontend is already built into Docker image (deploy/Dockerfile)"
echo "   Backend serves frontend/dist/ as static files"
echo "   → No separate Vercel needed if using Docker deployment"
echo ""

# ─── 3. BSNexus frontend ───
echo "3. nexus.bsvibe.dev"
echo "   Source: ~/Works/BSNexus/main/frontend/"
echo ""
echo "   cd ~/Works/BSNexus/main/frontend && vercel link"
echo "   vercel domains add nexus.bsvibe.dev"
echo ""

# ─── 4. BSage frontend ───
echo "4. sage.bsvibe.dev"
echo "   Source: ~/Works/BSage/main/frontend/"
echo ""
echo "   cd ~/Works/BSage/main/frontend && vercel link"
echo "   vercel domains add sage.bsvibe.dev"
echo ""

echo "═══ Notes ═══"
echo ""
echo "• Each Vercel project auto-deploys on push to main branch"
echo "• Set VITE_API_URL env var in Vercel for each project:"
echo "    gateway.bsvibe.dev → VITE_API_URL=https://gateway-api.bsvibe.dev"
echo "    nexus.bsvibe.dev   → VITE_API_URL=https://nexus-api.bsvibe.dev"
echo "    sage.bsvibe.dev    → VITE_API_URL=https://sage-api.bsvibe.dev"
echo ""
echo "• Alternative: Frontend built into Docker image (BSGateway already does this)"
echo "  In this case, backend serves the SPA. No Vercel needed."
echo "  This is simpler but doesn't get Vercel CDN benefits."
