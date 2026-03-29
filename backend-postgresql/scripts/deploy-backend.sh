#!/usr/bin/env bash
#
# Deploy Express + Prisma backend on Ubuntu (EC2 / golden AMI / manual redeploy).
#
# Assignment alignment (Module 9 — AWS CI/CD):
#   Production path: GitHub → CodePipeline → CodeBuild (artifact) → CodeDeploy → ASG
#   with appspec.yml hooks: BeforeInstall, AfterInstall, ApplicationStart.
#   This script performs the SAME logical steps in one place so you can:
#     • run it manually after `git push` (quick iteration), or
#     • call the same commands from CodeDeploy hooks (ApplicationStart / AfterInstall).
#
# Run on the backend EC2 instance (same VPC as RDS; IAM role must allow ssm:GetParameter):
#   sudo bash backend-postgresql/scripts/deploy-backend.sh
#
# Parameter Store (default prefix /todo-app) — production EC2 has NO .env inside backend-postgresql/.
#   Required:
#     /todo-app/DATABASE_URL
#   Optional (defaults shown):
#     /todo-app/NODE_ENV     → production
#     /todo-app/PORT         → 4000
#     /todo-app/CORS_ORIGIN  → * (only if you need a tight origin; not a secret)
#
# Secrets are written only to BACKEND_ENV_FILE (default /etc/todo-backend/environment), not the app tree.
#
# Optional env:
#   REPO_URL (public Git URL only — not an AWS credential)
#   REPO_BRANCH, DEPLOY_ROOT, BACKEND_DIR
#   BACKEND_ENV_FILE=/etc/todo-backend/environment
#   SSM_PREFIX=/todo-app   SSM_REGION=ap-south-1
#   GIT_SYNC_MODE=remote|local|pull|none
#   LOAD_SSM=1   (default on EC2 — set 0 only for offline dev with BACKEND_ENV_FILE pre-filled)
#   SERVICE_NAME=todo-backend
#   DEPLOY_USER=ubuntu
#
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

LOG_FILE="${LOG_FILE:-/var/log/backend-deploy.log}"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================="
echo "Backend deploy started: $(date -Iseconds)"
echo "Script: backend-postgresql/scripts/deploy-backend.sh"
echo "========================================="

export DEBIAN_FRONTEND=noninteractive

REPO_URL="${REPO_URL:-https://github.com/coderrony/3-tier-web-app-auto-scaling.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/3tier-app}"
BACKEND_DIR="${BACKEND_DIR:-backend-postgresql}"
NODE_MAJOR="${NODE_MAJOR:-20}"
GIT_SYNC_MODE="${GIT_SYNC_MODE:-remote}"
SSM_PREFIX="${SSM_PREFIX:-/todo-app}"
LOAD_SSM="${LOAD_SSM:-1}"
SSM_REGION="${SSM_REGION:-}"
SERVICE_NAME="${SERVICE_NAME:-todo-backend}"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
BACKEND_ENV_FILE="${BACKEND_ENV_FILE:-/etc/todo-backend/environment}"
if ! id "$DEPLOY_USER" &>/dev/null; then
  echo ">>> WARN: user ${DEPLOY_USER} not found — using root for files + systemd"
  DEPLOY_USER=root
fi

get_region() {
  if command -v ec2-metadata >/dev/null 2>&1; then
    ec2-metadata --availability-zone 2>/dev/null | cut -d' ' -f2 | sed 's/[a-z]$//' && return 0
  fi
  local token
  token=$(curl -sf -m 2 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600") || return 1
  curl -sf -m 2 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//'
}

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "${REGION}" ]]; then
  REGION="$(get_region)" || REGION="us-east-1"
fi
export AWS_DEFAULT_REGION="$REGION"

# Ubuntu 24.04+ often has no `awscli` apt package — use Snap or official AWS CLI v2.
ensure_aws_cli() {
  command -v aws >/dev/null 2>&1 && return 0
  echo ">>> Installing AWS CLI (needed for SSM Parameter Store)..."
  apt-get update -qq
  if apt-get install -y -qq awscli 2>/dev/null && command -v aws >/dev/null 2>&1; then
    echo "    OK: aws from apt"
    return 0
  fi
  if command -v snap >/dev/null 2>&1; then
    echo ">>> apt has no awscli — trying: snap install aws-cli --classic"
    if snap install aws-cli --classic 2>/dev/null; then
      export PATH="/snap/bin:/usr/local/bin:${PATH}"
      hash -r 2>/dev/null || true
      command -v aws >/dev/null 2>&1 && return 0
    fi
  fi
  local arch url
  arch="$(uname -m)"
  case "$arch" in
    x86_64) url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;;
    aarch64) url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;;
    *)
      echo "ERROR: Unsupported CPU arch for AWS CLI v2 bundle: $arch"
      return 1
      ;;
  esac
  echo ">>> Installing AWS CLI v2 from AWS (${arch})..."
  apt-get install -y -qq curl unzip ca-certificates
  curl -fsSL "$url" -o /tmp/awscliv2.zip
  rm -rf /tmp/aws
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install -i /usr/local/aws-cli -b /usr/local/bin --update
  export PATH="/usr/local/bin:${PATH}"
  hash -r 2>/dev/null || true
  command -v aws >/dev/null 2>&1
}

bootstrap_ubuntu() {
  echo ">>> Installing base packages (apt)..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg git lsb-release

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -dc '0-9' | head -c 2 || echo 0)" -lt "${NODE_MAJOR}" ]]; then
    echo ">>> Installing Node.js ${NODE_MAJOR}.x (NodeSource)..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y -qq nodejs
  fi
  _node_v="$(node -v 2>/dev/null || echo '?')"
  _npm_v="$(npm -v 2>/dev/null || echo 'missing')"
  echo ">>> Node: ${_node_v} | npm: ${_npm_v}"

  if [[ "${LOAD_SSM}" == "1" ]]; then
    ensure_aws_cli || {
      echo "ERROR: Could not install AWS CLI. Use one of:"
      echo "  sudo snap install aws-cli --classic"
      echo "  Or: LOAD_SSM=0 with secrets in ${BACKEND_ENV_FILE} (not inside backend-postgresql/)"
      exit 1
    }
  fi
  echo ">>> bootstrap_ubuntu: done"
}

ssm_read() {
  local pname="$1"
  local out rc
  set +e
  out="$(aws ssm get-parameter --name "$pname" --with-decryption --query Parameter.Value --output text --region "${SSM_REG}" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "    FAIL ${pname}: ${out}" >&2
    return 1
  fi
  if [[ -z "${out}" || "${out}" == "None" ]]; then
    return 1
  fi
  printf '%s' "$out"
}

# Optional SSM key — no error log if ParameterNotFound.
ssm_read_optional() {
  local pname="$1"
  aws ssm get-parameter --name "$pname" --with-decryption --query Parameter.Value --output text --region "${SSM_REG}" 2>/dev/null || true
}

load_env_from_ssm() {
  SSM_REG="${SSM_REGION:-$REGION}"
  echo ">>> Loading config from SSM prefix ${SSM_PREFIX}/ (region: ${SSM_REG})"

  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: AWS CLI missing — cannot read SSM. Install awscli or set LOAD_SSM=0 and ${BACKEND_ENV_FILE}."
    exit 1
  fi
  if aws sts get-caller-identity --region "${SSM_REG}" &>/dev/null; then
    echo "    AWS identity OK ($(aws sts get-caller-identity --query Account --output text --region "${SSM_REG}" 2>/dev/null || echo '?'))"
  else
    echo "    WARN: aws sts get-caller-identity failed — check EC2 instance role (ssm:GetParameter)"
  fi

  DATABASE_URL="$(ssm_read "${SSM_PREFIX}/DATABASE_URL" || true)"
  NODE_ENV_VAL="$(ssm_read "${SSM_PREFIX}/NODE_ENV" || true)"
  PORT_VAL="$(ssm_read "${SSM_PREFIX}/PORT" || true)"
  CORS_VAL="$(ssm_read_optional "${SSM_PREFIX}/CORS_ORIGIN")"

  if [[ -z "${DATABASE_URL}" ]]; then
    echo "ERROR: ${SSM_PREFIX}/DATABASE_URL missing or unreadable in SSM."
    exit 1
  fi
  echo "    OK DATABASE_URL (length ${#DATABASE_URL})"
  NODE_ENV_VAL="${NODE_ENV_VAL:-production}"
  PORT_VAL="${PORT_VAL:-4000}"
  CORS_ORIGIN="${CORS_VAL:-*}"
  echo "    NODE_ENV=${NODE_ENV_VAL} PORT=${PORT_VAL} CORS_ORIGIN=${CORS_ORIGIN}"
}

# Dotenv format for node --env-file (safe quoting for # $ = in URLs).
write_backend_env() {
  local env_file="$1"
  umask 077
  mkdir -p "$(dirname "$env_file")"
  _env_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
  }
  {
    printf '%s\n' "# SSM-backed runtime env — ${SERVICE_NAME} — do not commit"
    printf 'DATABASE_URL="%s"\n' "$(_env_escape "$DATABASE_URL")"
    printf 'NODE_ENV=%s\n' "$NODE_ENV_VAL"
    printf 'PORT=%s\n' "$PORT_VAL"
    printf 'CORS_ORIGIN=%s\n' "${CORS_ORIGIN:-*}"
  } > "$env_file"
  chmod 600 "$env_file"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "$env_file"
  if ! sudo -u "${DEPLOY_USER}" test -r "$env_file"; then
    echo "ERROR: ${DEPLOY_USER} cannot read ${env_file} after chown"
    exit 1
  fi
  echo ">>> Wrote ${env_file} (outside app dir; ${DEPLOY_USER} can read)"
}

sync_git_remote() {
  echo ">>> Syncing from GitHub: reset to origin/${REPO_BRANCH}"
  git fetch origin "$REPO_BRANCH" || git fetch origin
  git checkout "$REPO_BRANCH"
  git reset --hard "origin/${REPO_BRANCH}"
  echo ">>> Deploying commit: $(git rev-parse --short HEAD 2>/dev/null) — $(git log -1 --oneline 2>/dev/null || echo '?')"
}

sync_git_pull() {
  echo ">>> git pull origin ${REPO_BRANCH}"
  git fetch origin
  git checkout "$REPO_BRANCH"
  git pull origin "$REPO_BRANCH" --ff-only || git pull origin "$REPO_BRANCH"
  echo ">>> Tree at commit: $(git rev-parse --short HEAD 2>/dev/null) ($(git log -1 --oneline 2>/dev/null || echo '?'))"
}

first_clone() {
  echo ">>> First deploy: cloning ${REPO_URL} (${REPO_BRANCH})..."
  if [[ -n "$(ls -A "$DEPLOY_ROOT" 2>/dev/null || true)" ]]; then
    echo "Directory not empty; backing up to ${DEPLOY_ROOT}.bak"
    mv "$DEPLOY_ROOT" "${DEPLOY_ROOT}.bak.$(date +%s)"
    mkdir -p "$DEPLOY_ROOT"
  fi
  cd "$DEPLOY_ROOT"
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" .
  echo ">>> Cloned at: $(git rev-parse --short HEAD 2>/dev/null) ($(git log -1 --oneline 2>/dev/null || echo '?'))"
}

install_systemd_unit() {
  local app_dir="$1"
  local port="$2"
  local env_file="$3"
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  local run_user="$DEPLOY_USER"

  if [[ ! -f "${env_file}" ]]; then
    echo "ERROR: env file missing before systemd update: ${env_file}"
    exit 1
  fi

  cat > "$unit" << UNIT_EOF
[Unit]
Description=Todo backend API (Express + Prisma)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${run_user}
Group=${run_user}
WorkingDirectory=${app_dir}
# Node 20+ --env-file loads before ESM; path must be absolute. No systemd EnvironmentFile= here.
ExecStart=/usr/bin/node --env-file=${env_file} ${app_dir}/src/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNIT_EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  systemctl restart "${SERVICE_NAME}.service"
  echo ">>> systemd: ${SERVICE_NAME}.service (port ${port} — env ${env_file})"
}

bootstrap_ubuntu

if [[ "${LOAD_SSM}" == "1" ]]; then
  load_env_from_ssm
  write_backend_env "${BACKEND_ENV_FILE}"
  export DATABASE_URL
else
  echo ">>> LOAD_SSM=0 — reading ${BACKEND_ENV_FILE} (no SSM; for local/offline only)"
  if [[ ! -f "${BACKEND_ENV_FILE}" ]]; then
    echo "ERROR: ${BACKEND_ENV_FILE} not found. On EC2 use LOAD_SSM=1 (default)."
    exit 1
  fi
  set +u
  set -a
  # shellcheck source=/dev/null
  source "${BACKEND_ENV_FILE}"
  set +a
  set -u
  if [[ -z "${DATABASE_URL:-}" ]]; then
    echo "ERROR: DATABASE_URL missing in ${BACKEND_ENV_FILE}"
    exit 1
  fi
  NODE_ENV_VAL="${NODE_ENV:-${NODE_ENV_VAL:-production}}"
  PORT_VAL="${PORT:-${PORT_VAL:-4000}}"
  CORS_ORIGIN="${CORS_ORIGIN:-*}"
  export DATABASE_URL
fi

echo ">>> Preparing app directory: ${DEPLOY_ROOT} (GIT_SYNC_MODE=${GIT_SYNC_MODE})"
mkdir -p "$DEPLOY_ROOT"
cd "$DEPLOY_ROOT"

if [[ "${GIT_SYNC_MODE}" == "remote" ]]; then
  if [[ -d .git ]]; then
    sync_git_remote
  else
    first_clone
  fi
elif [[ "${GIT_SYNC_MODE}" == "pull" ]]; then
  if [[ -d .git ]]; then
    sync_git_pull
  else
    first_clone
  fi
else
  if [[ -f "${DEPLOY_ROOT}/${BACKEND_DIR}/package.json" ]]; then
    echo ">>> GIT_SYNC_MODE=local|none — no git pull; building from disk"
  elif [[ -d .git ]]; then
    echo "ERROR: ${BACKEND_DIR}/package.json not found. Run: sudo GIT_SYNC_MODE=remote bash $0"
    exit 1
  else
    first_clone
  fi
fi

APP_DIR="${DEPLOY_ROOT}/${BACKEND_DIR}"
if [[ ! -f "${APP_DIR}/package.json" ]]; then
  echo "ERROR: ${APP_DIR}/package.json not found"
  exit 1
fi

cd "$APP_DIR"

# Never keep credentials under the repo path on EC2 — systemd + Prisma use SSM → BACKEND_ENV_FILE only.
rm -f "${APP_DIR}/.env"
if [[ "${LOAD_SSM}" == "1" ]]; then
  echo ">>> Runtime env: ${BACKEND_ENV_FILE} (no ${BACKEND_DIR}/.env)"
fi

chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "$APP_DIR" 2>/dev/null || true

# Prisma CLI is a devDependency — install with dev deps before migrate
unset NODE_ENV
export NPM_CONFIG_PRODUCTION=false

echo ">>> npm ci (includes devDependencies for prisma migrate)..."
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund --include=dev
else
  npm install --no-audit --no-fund --include=dev
fi

echo ">>> prisma generate + migrate deploy..."
npx prisma generate
npx prisma migrate deploy

export NODE_ENV="${NODE_ENV_VAL}"
BACKEND_ENV_ABS="$(readlink -f "${BACKEND_ENV_FILE}" 2>/dev/null || echo "${BACKEND_ENV_FILE}")"
install_systemd_unit "$APP_DIR" "$PORT_VAL" "${BACKEND_ENV_ABS}"

sleep 3
if curl -sf "http://127.0.0.1:${PORT_VAL}/api/health" >/dev/null; then
  echo ">>> Health OK: http://127.0.0.1:${PORT_VAL}/api/health"
else
  echo ">>> WARN: health check failed — last logs:"
  journalctl -u "${SERVICE_NAME}" -n 45 --no-pager || true
fi

echo "========================================="
echo "Backend deploy finished: $(date -Iseconds)"
echo "Service: systemctl status ${SERVICE_NAME}"
echo "Logs:    journalctl -u ${SERVICE_NAME} -f"
echo "Log file: ${LOG_FILE}"
echo ""
echo "CI/CD (assignment): map these steps to CodeDeploy —"
echo "  AfterInstall:   npm ci, prisma generate, prisma migrate deploy"
echo "  ApplicationStart: systemctl restart ${SERVICE_NAME}"
echo "========================================="
