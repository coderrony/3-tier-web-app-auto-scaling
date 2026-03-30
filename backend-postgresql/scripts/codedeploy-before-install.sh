#!/usr/bin/env bash
set -euo pipefail

# This runs as part of CodeDeploy lifecycle hooks.
# We keep it defensive: stop whatever is running, but don't fail if nothing is running.

SERVICE_NAME="${SERVICE_NAME:-todo-backend}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

echo "=== CodeDeploy BeforeInstall: stopping ${SERVICE_NAME} (if running) ==="

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
fi

if command -v pm2 >/dev/null 2>&1; then
  # PM2 processes usually run under DEPLOY_USER.
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "${DEPLOY_USER}" env HOME="/home/${DEPLOY_USER}" pm2 delete "${SERVICE_NAME}" 2>/dev/null || true
  else
    pm2 delete "${SERVICE_NAME}" 2>/dev/null || true
  fi
fi

echo "=== CodeDeploy BeforeInstall done ==="
