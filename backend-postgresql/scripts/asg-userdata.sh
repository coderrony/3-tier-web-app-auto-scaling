#!/bin/bash
#
# Paste this ENTIRE file into EC2 Launch Template → Advanced details → User data
# (or upload via console). Runs on first boot of ASG instances.
#
# Requires on the instance IAM instance profile: SSM read (/todo-app/*), same as manual deploy.
# Logs: /var/log/asg-backend-userdata.log  and  /var/log/backend-deploy.log
#
set -euo pipefail
exec > >(tee /var/log/asg-backend-userdata.log) 2>&1

echo "=== ASG backend userdata start: $(date -Iseconds) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git ca-certificates curl

# Ensure CodeDeploy agent exists (needed for Task 7-9 hooks).
if ! systemctl status codedeploy-agent >/dev/null 2>&1; then
  apt-get install -y -qq ruby-full wget
  # Detect region from instance metadata (best-effort).
  REGION="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -X PUT http://169.254.169.254/latest/api/token 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "${REGION}" ]]; then
    # Fallback (common defaults for this lab).
    SSM_FALLBACK_REGION="${SSM_REGION:-ap-south-1}"
    REGION="$SSM_FALLBACK_REGION"
  else
    AZ="$(curl -sf -m 2 -H "X-aws-ec2-metadata-token: ${REGION}" http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || true)"
    REGION="$(echo "${AZ}" | sed 's/[a-z]$//')"
    [[ -n "${REGION}" ]] || REGION="${SSM_REGION:-ap-south-1}"
  fi

  echo "Installing CodeDeploy agent for region: ${REGION}"
  wget -q "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install" -O /tmp/codedeploy-install
  chmod +x /tmp/codedeploy-install
  /tmp/codedeploy-install auto || /tmp/codedeploy-install auto > /tmp/codedeploy-install.log 2>&1 || true
  systemctl enable codedeploy-agent >/dev/null 2>&1 || true
  systemctl start codedeploy-agent >/dev/null 2>&1 || true
fi

DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/3tier-app}"
REPO_URL="${REPO_URL:-https://github.com/coderrony/3-tier-web-app-auto-scaling.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"

mkdir -p "$DEPLOY_ROOT"
cd "$DEPLOY_ROOT"

if [[ ! -d .git ]]; then
  git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" .
else
  git fetch origin "$REPO_BRANCH" || git fetch origin
  git checkout "$REPO_BRANCH"
  git reset --hard "origin/${REPO_BRANCH}"
fi

export SSM_REGION="${SSM_REGION:-ap-south-1}"
export LOAD_SSM=1
export PROCESS_MANAGER=pm2
export GIT_SYNC_MODE=remote

bash "${DEPLOY_ROOT}/backend-postgresql/scripts/deploy-backend.sh"

echo "=== ASG backend userdata done: $(date -Iseconds) ==="
