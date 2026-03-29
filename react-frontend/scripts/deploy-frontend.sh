#!/usr/bin/env bash
#
# One-shot Ubuntu setup: install Nginx + Node.js, build Vite app, go live on port 80.
# Repo default: https://github.com/coderrony/3-tier-web-app-auto-scaling.git
#
# Run as root on Ubuntu 22.04/24.04:
#   sudo bash scripts/deploy-frontend.sh
#
# Edit files under DEPLOY_ROOT/react-frontend (default /var/www/3tier-app/react-frontend),
# then re-run this script so Vite rebuilds and Nginx serves the new dist.
#
# Optional env:
#   BACKEND_ALB_URL   — backend base URL (no trailing slash), e.g. http://alb-dns.amazonaws.com
#   REPO_URL, REPO_BRANCH, DEPLOY_ROOT
#   NODE_MAJOR        — default 20
#   UFW_ALLOW_HTTP=1  — if UFW is enabled, allow port 80
#
#   GIT_SYNC_MODE:
#     local (default) — does NOT overwrite your files: builds whatever is on disk under
#                       DEPLOY_ROOT/react-frontend (manual EC2 edits are kept). Clones only if folder is empty.
#     remote          — git fetch + reset --hard origin/<branch> (exact copy of GitHub; discards local edits on EC2)
#     pull            — git pull (merge remote into server branch; keeps commits, may conflict)
#     none            — same as local (alias)
#
# If BACKEND_ALB_URL is unset: tries AWS SSM; on a plain Ubuntu VM falls back to http://127.0.0.1:4000
# (run your Express API on 4000 on the same machine, or set BACKEND_ALB_URL to your ALB).
#
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

LOG_FILE="${LOG_FILE:-/var/log/frontend-deploy.log}"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "========================================="
echo "Frontend deploy (Ubuntu) started: $(date -Iseconds)"
echo "========================================="

export DEBIAN_FRONTEND=noninteractive

REPO_URL="${REPO_URL:-https://github.com/coderrony/3-tier-web-app-auto-scaling.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/3tier-app}"
FRONTEND_DIR="${FRONTEND_DIR:-react-frontend}"
SSM_PARAM="${DEPLOY_SSM_PARAM:-/3tier-web-app/backend-alb-url}"
NODE_MAJOR="${NODE_MAJOR:-20}"
LOCAL_BACKEND_DEFAULT="${LOCAL_BACKEND_DEFAULT:-http://127.0.0.1:4000}"
GIT_SYNC_MODE="${GIT_SYNC_MODE:-local}"

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

bootstrap_ubuntu() {
  echo ">>> Installing base packages (apt)..."
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg git lsb-release

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v 2>/dev/null | tr -dc '0-9' | head -c 2 || echo 0)" -lt "${NODE_MAJOR}" ]]; then
    echo ">>> Installing Node.js ${NODE_MAJOR}.x (NodeSource)..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y -qq nodejs
  fi
  echo ">>> Node: $(node -v) | npm: $(npm -v)"

  if ! command -v nginx >/dev/null 2>&1; then
    echo ">>> Installing Nginx..."
    apt-get install -y -qq nginx
  fi

  systemctl enable nginx
}

resolve_backend_url() {
  if [[ -n "${BACKEND_ALB_URL:-}" ]]; then
    BACKEND_ALB_URL="${BACKEND_ALB_URL%/}"
    echo "Using BACKEND_ALB_URL from environment: ${BACKEND_ALB_URL}"
    return
  fi
  if command -v aws >/dev/null 2>&1; then
    local val
    val="$(aws ssm get-parameter --name "$SSM_PARAM" --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
    if [[ -n "${val:-}" ]] && [[ "${val}" != "None" ]]; then
      BACKEND_ALB_URL="${val%/}"
      echo "Using BACKEND_ALB_URL from SSM ${SSM_PARAM}: ${BACKEND_ALB_URL}"
      return
    fi
  fi
  BACKEND_ALB_URL="${LOCAL_BACKEND_DEFAULT}"
  echo "No BACKEND_ALB_URL or SSM; using local default for /api proxy: ${BACKEND_ALB_URL}"
  echo "    (Start backend on port 4000 on this host, or export BACKEND_ALB_URL before running.)"
}

bootstrap_ubuntu
resolve_backend_url

echo ">>> Preparing app directory: ${DEPLOY_ROOT} (GIT_SYNC_MODE=${GIT_SYNC_MODE})"
mkdir -p "$DEPLOY_ROOT"
cd "$DEPLOY_ROOT"

sync_git_remote() {
  echo ">>> Syncing from GitHub: reset to origin/${REPO_BRANCH} (local uncommitted edits on EC2 will be lost)"
  git remote -v || true
  git fetch origin "$REPO_BRANCH" --depth 1
  git checkout "$REPO_BRANCH"
  git reset --hard "origin/${REPO_BRANCH}"
  echo ">>> Tree at commit: $(git rev-parse --short HEAD 2>/dev/null) ($(git log -1 --oneline 2>/dev/null || echo '?'))"
}

sync_git_pull() {
  echo ">>> git pull origin ${REPO_BRANCH}"
  git remote -v || true
  git fetch origin
  git checkout "$REPO_BRANCH"
  git pull origin "$REPO_BRANCH" --ff-only || git pull origin "$REPO_BRANCH"
  echo ">>> Tree at commit: $(git rev-parse --short HEAD 2>/dev/null) ($(git log -1 --oneline 2>/dev/null || echo '?'))"
}

first_clone() {
  echo ">>> First deploy: cloning ${REPO_URL} (${REPO_BRANCH})..."
  if [[ -n "$(ls -A "$DEPLOY_ROOT" 2>/dev/null || true)" ]]; then
    echo "Directory not empty and not a git repo; backing up to ${DEPLOY_ROOT}.bak"
    mv "$DEPLOY_ROOT" "${DEPLOY_ROOT}.bak.$(date +%s)"
    mkdir -p "$DEPLOY_ROOT"
    cd "$DEPLOY_ROOT"
  fi
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" .
  echo ">>> Cloned at: $(git rev-parse --short HEAD 2>/dev/null) ($(git log -1 --oneline 2>/dev/null || echo '?'))"
}

# local | none = build current files on disk (manual EC2 edits survive)
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
  # local (default) or none
  if [[ -f "${DEPLOY_ROOT}/${FRONTEND_DIR}/package.json" ]]; then
    echo ">>> Local build: using ${DEPLOY_ROOT}/${FRONTEND_DIR} as-is (no git fetch/reset — your edits stay)"
    if [[ -d "${DEPLOY_ROOT}/.git" ]]; then
      echo "    Git HEAD: $(cd "${DEPLOY_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo '?') (dirty/worktree changes are included in the Vite build)"
    fi
  elif [[ -d .git ]]; then
    echo "ERROR: ${DEPLOY_ROOT}/${FRONTEND_DIR}/package.json not found but .git exists."
    echo "       Fix FRONTEND_DIR or run: GIT_SYNC_MODE=remote sudo bash $0"
    exit 1
  else
    first_clone
  fi
fi

cd "${DEPLOY_ROOT}/${FRONTEND_DIR}"

export VITE_API_URL=""
# npm omits devDependencies when NODE_ENV=production — Vite lives in devDependencies, so install without that.
unset NODE_ENV
export NPM_CONFIG_PRODUCTION=false

echo ">>> npm ci (including devDependencies: vite, plugins)..."
if [[ -f package-lock.json ]]; then
  npm ci --no-audit --no-fund --include=dev
else
  npm install --no-audit --no-fund --include=dev
fi

echo ">>> Cleaning old build output..."
rm -rf dist node_modules/.vite

echo ">>> vite build (production assets)..."
export NODE_ENV=production
npm run build

DIST_PATH="$(pwd)/dist"
if [[ ! -f "${DIST_PATH}/index.html" ]]; then
  echo "ERROR: Build failed — ${DIST_PATH}/index.html missing"
  exit 1
fi

echo ">>> Configuring Nginx..."
# Ubuntu default site conflicts with our default_server; disable it
if [[ -f /etc/nginx/sites-enabled/default ]]; then
  rm -f /etc/nginx/sites-enabled/default
fi

NGINX_CONF="/etc/nginx/conf.d/frontend.conf"
tee "$NGINX_CONF" > /dev/null << NGINX_EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root ${DIST_PATH};
    index index.html;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/json image/svg+xml;

    # SPA + always-fresh HTML (avoid stale UI after redeploy)
    location / {
        try_files \$uri \$uri/ /index.html;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
    }

    location = /index.html {
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Pragma "no-cache" always;
    }

    # Vite emits hashed filenames — safe to cache; new deploy = new names
    location ~* \\.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 7d;
        add_header Cache-Control "public, immutable";
    }

    location = /health {
        access_log off;
        default_type text/plain;
        return 200 "healthy\n";
    }

    location /api/ {
        proxy_pass ${BACKEND_ALB_URL}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
NGINX_EOF

nginx -t
systemctl restart nginx

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  if [[ "${UFW_ALLOW_HTTP:-}" == "1" ]]; then
    echo ">>> UFW active — allowing HTTP (80)..."
    ufw allow 80/tcp comment 'nginx frontend' || true
    ufw reload || true
  else
    echo "NOTE: UFW is active. If the site does not open in browser, run: sudo ufw allow 80/tcp"
  fi
fi

IPS="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "========================================="
echo "Deploy finished: $(date -Iseconds)"
echo "Static root: ${DIST_PATH}"
echo "Open in browser (this machine):"
echo "  http://${IPS:-localhost}/"
echo "  http://localhost/health   (health check)"
echo "Backend API proxied from: ${BACKEND_ALB_URL}"
echo "Log: ${LOG_FILE}"
echo ""
echo "Tip: Default is GIT_SYNC_MODE=local (EC2 file edits → rebuild → live). Hard-refresh if needed."
echo "     To match GitHub exactly (wipes uncommitted EC2 edits): GIT_SYNC_MODE=remote sudo bash $0"
echo "========================================="
