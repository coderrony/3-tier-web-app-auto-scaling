#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-todo-backend}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"

echo "=== CodeDeploy ApplicationStart: verify backend health ==="

# Prefer PORT from the SSM-written env file (created by deploy-backend.sh).
PORT_VAL="4000"
ENV_FILE="${BACKEND_ENV_FILE:-/etc/todo-backend/environment}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  set +u
  source "${ENV_FILE}" || true
  set -u
  PORT_VAL="${PORT:-${PORT_VAL}}"
fi

if command -v pm2 >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "${DEPLOY_USER}" env HOME="/home/${DEPLOY_USER}" pm2 restart "${SERVICE_NAME}" 2>/dev/null || true
  else
    pm2 restart "${SERVICE_NAME}" 2>/dev/null || true
  fi
fi

echo "Checking: http://127.0.0.1:${PORT_VAL}/api/health"
curl -sf "http://127.0.0.1:${PORT_VAL}/api/health" >/dev/null

echo "=== CodeDeploy ApplicationStart done ==="
