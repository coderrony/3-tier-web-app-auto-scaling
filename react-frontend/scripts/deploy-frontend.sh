#!/usr/bin/env bash
#
# One-shot Ubuntu setup: install Nginx + Node.js, build Vite app, go live on port 80.
# Repo default: https://github.com/coderrony/3-tier-web-app-auto-scaling.git
#
# Run as root on Ubuntu 22.04/24.04:
#   sudo bash scripts/deploy-frontend.sh
#
# Default (GIT_SYNC_MODE=remote): pulls latest from GitHub main, then builds — use AFTER
#   you push your changes. This is what you want when editing in GitHub / VS Code on PC.
#
# Only edit directly on EC2 and do NOT want GitHub to overwrite files:
#   sudo GIT_SYNC_MODE=local bash scripts/deploy-frontend.sh
#
# Optional env:
#   BACKEND_ALB_URL   — backend base URL (no trailing slash), e.g. http://alb-dns.amazonaws.com
#   REPO_URL, REPO_BRANCH, DEPLOY_ROOT
#   NODE_MAJOR        — default 20
#   UFW_ALLOW_HTTP=1  — if UFW is enabled, allow port 80
#
#   GIT_SYNC_MODE:
#     remote (default) — git fetch + reset --hard origin/<branch> (matches GitHub after push; EC2-only uncommitted edits are discarded)
#     local            — builds files on disk only; does NOT pull from GitHub (manual EC2 edits kept; GitHub pushes ignored)
#     pull             — git pull (merge; may conflict)
#     none             — same as local (alias)
#
# If BACKEND_ALB_URL is unset: tries AWS SSM; on a plain Ubuntu VM falls back to http://127.0.0.1:4000
# (run your Express API on 4000 on the same machine, or set BACKEND_ALB_URL to your ALB).
#
# Parameter Store for Vite: SSM_VITE_PREFIX=/todo-app → /todo-app/VITE_API_URL, /todo-app/VITE_ENV (at build).
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
echo "Script: deploy-frontend.sh (includes Parameter Store → Vite build env)"
echo "========================================="

export DEBIAN_FRONTEND=noninteractive

REPO_URL="${REPO_URL:-https://github.com/coderrony/3-tier-web-app-auto-scaling.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/var/www/3tier-app}"
FRONTEND_DIR="${FRONTEND_DIR:-react-frontend}"
# Nginx proxy target (server-side). Prefer a dedicated param; VITE_API_URL is used only as fallback
# when it holds the backend ALB DNS (same as /todo-app/VITE_API_URL in many setups).
SSM_PARAM_BACKEND_CANDIDATES=(
  "${DEPLOY_SSM_PARAM:-}"
  "/todo-app/BACKEND_ALB_URL"
  "/3tier-web-app/backend-alb-url"
  "/bmi-app/backend-alb-url"
  "/todo-app/VITE_API_URL"
)
NODE_MAJOR="${NODE_MAJOR:-20}"
LOCAL_BACKEND_DEFAULT="${LOCAL_BACKEND_DEFAULT:-http://127.0.0.1:4000}"
GIT_SYNC_MODE="${GIT_SYNC_MODE:-remote}"
SSM_VITE_PREFIX="${SSM_VITE_PREFIX:-/todo-app}"
LOAD_SSM_VITE="${LOAD_SSM_VITE:-1}"
# If parameters live in a different region than the EC2 instance, set e.g. SSM_REGION=ap-south-1
SSM_REGION="${SSM_REGION:-}"

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
  echo ">>> Installing AWS CLI (needed for SSM)..."
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
    *) echo "ERROR: Unsupported CPU arch for AWS CLI v2: $arch"; return 1 ;;
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
  # Do not use $(npm -v) inside echo with set -e — a failing subshell aborts the whole script.
  _node_v="$(node -v 2>/dev/null || echo '?')"
  _npm_v="$(npm -v 2>/dev/null || echo 'missing')"
  echo ">>> Node: ${_node_v} | npm: ${_npm_v}"

  if ! command -v nginx >/dev/null 2>&1; then
    echo ">>> Installing Nginx..."
    apt-get install -y -qq nginx
  fi

  if [[ "${LOAD_SSM_VITE:-1}" == "1" ]]; then
    ensure_aws_cli || echo ">>> WARN: AWS CLI install failed — SSM reads may fail"
  fi

  if systemctl list-unit-files nginx.service &>/dev/null; then
    systemctl enable nginx 2>/dev/null || true
  else
    echo ">>> WARN: nginx.service not found (is nginx installed?)"
  fi
  echo ">>> bootstrap_ubuntu: done"
}

normalize_http_origin() {
  # Nginx proxy_pass needs a proper origin (scheme + host[:port]); SSM often stores host only.
  local u="$1"
  u="${u%% *}"
  u="${u%/}"
  [[ -z "$u" ]] && return 1
  if [[ "$u" != http://* && "$u" != https://* ]]; then
    u="http://${u}"
  fi
  printf '%s' "$u"
}

resolve_backend_url() {
  if [[ -n "${BACKEND_ALB_URL:-}" ]]; then
    BACKEND_ALB_URL="$(normalize_http_origin "${BACKEND_ALB_URL%/}")" || BACKEND_ALB_URL="${LOCAL_BACKEND_DEFAULT}"
    echo "Using BACKEND_ALB_URL from environment: ${BACKEND_ALB_URL}"
    return
  fi
  if command -v aws >/dev/null 2>&1; then
    local pname val
    for pname in "${SSM_PARAM_BACKEND_CANDIDATES[@]}"; do
      [[ -z "${pname}" ]] && continue
      val="$(aws ssm get-parameter --name "$pname" --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)"
      if [[ -n "${val:-}" ]] && [[ "${val}" != "None" ]]; then
        if val_norm="$(normalize_http_origin "$val")"; then
          BACKEND_ALB_URL="$val_norm"
          echo "Using BACKEND_ALB_URL from SSM ${pname}: ${BACKEND_ALB_URL}"
          return
        fi
      fi
    done
  fi
  BACKEND_ALB_URL="${LOCAL_BACKEND_DEFAULT}"
  echo "No BACKEND_ALB_URL or SSM; using local default for /api proxy: ${BACKEND_ALB_URL}"
  echo "    (Start backend on port 4000 on this host, or set SSM /todo-app/BACKEND_ALB_URL or /todo-app/VITE_API_URL to the internal ALB URL.)"
}

load_vite_env_for_build() {
  if [[ "${LOAD_SSM_VITE}" != "1" ]]; then
    export VITE_API_URL="${VITE_API_URL:-}"
    export VITE_ENV="${VITE_ENV:-production}"
    echo ">>> Vite env: LOAD_SSM_VITE!=1 — VITE_ENV=${VITE_ENV}"
    return
  fi
  if ! command -v aws >/dev/null 2>&1; then
    export VITE_API_URL="${VITE_API_URL:-}"
    export VITE_ENV="${VITE_ENV:-production}"
    echo ">>> ERROR: AWS CLI still missing — cannot read SSM. apt install awscli"
    return
  fi

  # Region: explicit SSM_REGION, else instance region; Mumbai users often need ap-south-1
  local reg="${SSM_REGION:-${AWS_REGION:-$REGION}}"
  echo ">>> Loading Vite env from SSM: ${SSM_VITE_PREFIX}/VITE_API_URL, ${SSM_VITE_PREFIX}/VITE_ENV"
  echo "    Using region: ${reg} (override with SSM_REGION=ap-south-1 if parameters are in another region)"
  if aws sts get-caller-identity --region "${reg}" &>/dev/null; then
    echo "    AWS identity OK ($(aws sts get-caller-identity --query Account --output text --region "${reg}" 2>/dev/null || echo '?'))"
  else
    echo "    WARN: aws sts get-caller-identity failed — check EC2 instance role / IAM (ssm:GetParameter)"
  fi

  ssm_read() {
    local pname="$1"
    local out rc
    set +e
    out="$(aws ssm get-parameter --name "$pname" --with-decryption --query Parameter.Value --output text --region "${reg}" 2>&1)"
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
    return 0
  }

  local v_url v_env
  v_url="$(ssm_read "${SSM_VITE_PREFIX}/VITE_API_URL" || true)"
  v_env="$(ssm_read "${SSM_VITE_PREFIX}/VITE_ENV" || true)"

  if [[ -n "${v_url}" ]]; then
    # Internal ALB hostnames are for Nginx proxy only — the browser cannot call them directly.
    if [[ "${v_url}" == *internal-*elb.amazonaws.com* ]] || [[ "${v_url}" == http://internal-* ]] || [[ "${v_url}" == https://internal-* ]]; then
      export VITE_API_URL=""
      echo "    NOTE: SSM VITE_API_URL is an internal ALB — leaving VITE_API_URL empty for build (same-origin /api via Nginx)"
    else
      export VITE_API_URL="${v_url}"
      echo "    OK VITE_API_URL from SSM (length ${#v_url})"
    fi
  else
    export VITE_API_URL="${VITE_API_URL:-}"
    echo "    VITE_API_URL: empty — browser will use same-origin /api (Nginx proxy)"
  fi
  if [[ -n "${v_env}" ]]; then
    export VITE_ENV="${v_env}"
    echo "    OK VITE_ENV=${VITE_ENV}"
  else
    export VITE_ENV="${VITE_ENV:-production}"
    echo "    VITE_ENV: SSM read failed or missing — fallback VITE_ENV=${VITE_ENV}"
  fi

  echo ">>> Vite build will embed: VITE_ENV='${VITE_ENV}' (must show in UI after deploy + hard refresh)"
}

bootstrap_ubuntu
resolve_backend_url

echo ">>> Preparing app directory: ${DEPLOY_ROOT} (GIT_SYNC_MODE=${GIT_SYNC_MODE})"
mkdir -p "$DEPLOY_ROOT"
cd "$DEPLOY_ROOT"

sync_git_remote() {
  echo ">>> Syncing from GitHub: reset to origin/${REPO_BRANCH} (EC2-only uncommitted edits in this repo will be overwritten)"
  git remote -v || true
  # Shallow clone: fetch enough to move to latest remote tip
  git fetch origin "$REPO_BRANCH" || git fetch origin
  git checkout "$REPO_BRANCH"
  git reset --hard "origin/${REPO_BRANCH}"
  echo ">>> Deploying commit: $(git rev-parse --short HEAD 2>/dev/null) — $(git log -1 --oneline 2>/dev/null || echo '?')"
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
  # local or none — GitHub is NOT updated
  if [[ -f "${DEPLOY_ROOT}/${FRONTEND_DIR}/package.json" ]]; then
    echo ">>> GIT_SYNC_MODE=local: building from disk only — NO git pull from GitHub"
    echo "    Pushes to GitHub will NOT appear here. To deploy latest from GitHub after push, run:"
    echo "    sudo GIT_SYNC_MODE=remote bash $0"
    if [[ -d "${DEPLOY_ROOT}/.git" ]]; then
      echo "    Current HEAD: $(cd "${DEPLOY_ROOT}" && git rev-parse --short HEAD 2>/dev/null || echo '?') (includes uncommitted EC2 edits in the build)"
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

load_vite_env_for_build

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
        # Backend ALB must see its own hostname (not the public frontend ALB host), or routing/upstream can fail.
        proxy_set_header Host \$proxy_host;
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
echo "Tip: Default is GIT_SYNC_MODE=remote (git pull from GitHub, then build). Push first, then deploy."
echo "     EC2-only edits without Git: sudo GIT_SYNC_MODE=local bash $0"
echo "========================================="
