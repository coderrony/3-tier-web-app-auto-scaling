#!/usr/bin/env bash
set -euo pipefail

# CodeDeploy AfterInstall hook wrapper.
# It forces GIT_SYNC_MODE=none so the deployment uses the revision bundle content,
# not a fresh git clone from GitHub.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

export DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/3tier-app}"
export BACKEND_DIR="${BACKEND_DIR:-backend-postgresql}"
export GIT_SYNC_MODE="${GIT_SYNC_MODE:-none}"
export LOAD_SSM="${LOAD_SSM:-1}"
export PROCESS_MANAGER="${PROCESS_MANAGER:-pm2}"

echo "=== CodeDeploy AfterInstall: deploying backend ==="
echo "DEPLOY_ROOT=${DEPLOY_ROOT}"
echo "BACKEND_DIR=${BACKEND_DIR}"
echo "GIT_SYNC_MODE=${GIT_SYNC_MODE}"
echo "LOAD_SSM=${LOAD_SSM}"
echo "PROCESS_MANAGER=${PROCESS_MANAGER}"

cd "${REPO_ROOT}"
if command -v sudo >/dev/null 2>&1; then
  sudo -E bash "${REPO_ROOT}/backend-postgresql/scripts/deploy-backend.sh"
else
  bash "${REPO_ROOT}/backend-postgresql/scripts/deploy-backend.sh"
fi

echo "=== CodeDeploy AfterInstall done ==="
