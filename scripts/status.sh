#!/bin/bash
# Show status of all projects: git worktrees + running containers

echo "=== Git Worktrees ==="
for d in ~/Works/*/.bare; do
  name=$(basename "$(dirname "$d")")
  echo ""
  echo "[$name]"
  git -C "$d" worktree list 2>/dev/null | grep -v "(bare)"
done

echo ""
echo "=== Docker Containers ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker not running"
