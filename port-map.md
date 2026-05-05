# Port Allocation Map

## Deploy (main worktree)

| Project | APP_PORT | FRONTEND_PORT | PG_PORT | REDIS_PORT | Other |
|---------|----------|-------------|---------|-----------|-------|
| bloasis | 8000 | 3000 | 5432 | 6379 | GRAFANA_PORT=3001, PROMETHEUS_PORT=9090 |
| BSGateway | 4000 | 3300 | 5433 | 6380 | - |
| BSNexus | 8100 | 3100 | 5434 | 6381 | - |
| bsai | 8200 | 3200 | 5435 | 6382 | KEYCLOAK_PORT=8443 |
| BSForge | 8300 | - | 5436 | 6383 | FLOWER_PORT=5555 |
| BSage | 8400 | 3400 | - | - | - |
| MetaSummarizer | - | - | - | - | CLI only |

## Demo (interactive demo stack — +500 offset from prod)

Public demo deployments at `demo-{product}.bsvibe.dev` / `api-demo-{product}.bsvibe.dev`. Per-visitor ephemeral tenants, separate PG, isolated from prod.

| Project | APP_PORT | PG_PORT | REDIS_PORT |
|---------|----------|---------|-----------|
| BSGateway | 4500 | 5933 | 6880 |
| BSNexus | 8600 | 5934 | 6881 |
| BSupervisor | 9000 | 5937 | 6884 |
| BSage | 8900 | - | - |

## DevContainer (agent worktree) — +10000 offset

| Slot | Rule | Example (bloasis) |
|------|------|-------------------|
| deploy (main) | defaults | 8000/3000/5432/6379 |
| wt-1 | +10000 | 18000/13000/15432/16379 |
| wt-2 | +10001 | 18001/13001/15433/16380 |
| wt-3 | +10002 | 18002/13002/15434/16381 |
