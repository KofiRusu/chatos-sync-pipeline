#!/usr/bin/env bash
set -euo pipefail

umask 077

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

is_true() {
  case "${1:-}" in
    true|TRUE|1|yes|YES|y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

ensure_safe_env() {
  if is_true "${ENABLE_MOCK_DATA:-}" || is_true "${USE_MOCK_DATA:-}" || is_true "${MOCK_DATA:-}"; then
    log "Refusing to deploy with mock data enabled."
    exit 1
  fi

  if is_true "${AUTO_TRADE_LIVE:-}" || is_true "${LIVE_TRADING:-}" || is_true "${TRADING_LIVE:-}"; then
    log "Refusing to deploy with live auto-trading enabled."
    exit 1
  fi

  if is_true "${WIPE_DB:-}" || is_true "${RESET_DB:-}"; then
    log "Refusing to deploy with destructive DB flags enabled."
    exit 1
  fi
}

has_systemd_service() {
  local service="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    return 1
  fi
  systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "${service}.service"
}

restart_systemd_service() {
  local service="$1"
  log "Restarting systemd service: ${service}.service"
  systemctl restart "${service}.service"
}

detect_compose_cmd() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      echo "docker compose"
      return
    fi
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    echo "docker-compose"
    return
  fi

  echo ""
}

restart_compose_service() {
  local service="$1"
  local compose_cmd="$2"

  if [ -z "$compose_cmd" ]; then
    log "Docker compose not available; cannot restart ${service}."
    exit 1
  fi

  if [ ! -f "docker-compose.yml" ]; then
    log "docker-compose.yml not found; cannot restart ${service}."
    exit 1
  fi

  log "Restarting docker compose service: ${service}"
  $compose_cmd up -d --no-deps "${service}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
pipeline_root="$(cd "${script_dir}/.." && pwd -P)"
healthcheck_path="${script_dir}/healthcheck.sh"

DEPLOY_PATH="${DEPLOY_PATH:-/data/ChatOS}"
DEPLOY_DRY_RUN="${DEPLOY_DRY_RUN:-}"
DEPLOY_REF_RAW="${DEPLOY_REF:-main}"
DEPLOY_REF="${DEPLOY_REF_RAW#refs/heads/}"

summary_exit_code=0
summary_old_head="unknown"
summary_new_head="unknown"
summary_remote_head="unknown"
summary_updated="unknown"
summary_migrations="false"
summary_backend_restart="skipped"
summary_frontend_restart="skipped"
summary_healthcheck="skipped"
summary_deploy_ref="${DEPLOY_REF}"
summary_dry_run="${DEPLOY_DRY_RUN:-false}"

print_summary() {
  local exit_code="$1"
  log "=== Evidence Summary ==="
  log "exit_code=${exit_code}"
  log "deploy_path=${DEPLOY_PATH}"
  log "deploy_ref=${summary_deploy_ref}"
  log "dry_run=${summary_dry_run}"
  log "head_before=${summary_old_head}"
  log "head_target=${summary_remote_head}"
  log "head_after=${summary_new_head}"
  log "updated=${summary_updated}"
  log "migrations_ran=${summary_migrations}"
  log "backend_restart=${summary_backend_restart}"
  log "frontend_restart=${summary_frontend_restart}"
  log "healthcheck=${summary_healthcheck}"
}

trap 'summary_exit_code=$?; print_summary "$summary_exit_code"' EXIT

if [ "$(id -u)" -eq 0 ]; then
  log "Refusing to run as root."
  exit 1
fi

if [ -z "$DEPLOY_PATH" ] || [ "$DEPLOY_PATH" = "/" ]; then
  log "Invalid DEPLOY_PATH: '${DEPLOY_PATH}'"
  exit 1
fi

if [ -z "$DEPLOY_REF" ]; then
  log "Invalid DEPLOY_REF: '${DEPLOY_REF_RAW}'"
  exit 1
fi

require_cmd git
require_cmd flock

if [ ! -d "$DEPLOY_PATH" ]; then
  log "DEPLOY_PATH does not exist: $DEPLOY_PATH"
  exit 1
fi

deploy_path_real="$(cd "$DEPLOY_PATH" && pwd -P)"
if [ "$deploy_path_real" = "$pipeline_root" ]; then
  log "DEPLOY_PATH points to the pipeline repo (${pipeline_root}); refusing to deploy itself."
  exit 1
fi

if [ -f "$DEPLOY_PATH/.github/workflows/deploy.yml" ] && [ -f "$DEPLOY_PATH/scripts/deploy_remote.sh" ]; then
  if command -v cmp >/dev/null 2>&1; then
    if cmp -s "$script_path" "$DEPLOY_PATH/scripts/deploy_remote.sh"; then
      log "DEPLOY_PATH appears to be the pipeline repo (deploy script matches); refusing."
      exit 1
    fi
  else
    log "cmp not available to validate pipeline repo guard; refusing to deploy."
    exit 1
  fi
fi

if [ ! -d "$DEPLOY_PATH/src/backend" ]; then
  log "DEPLOY_PATH does not look like ChatOS (missing src/backend)."
  exit 1
fi

if [ ! -d "$DEPLOY_PATH/src/frontend" ] && [ ! -f "$DEPLOY_PATH/docker-compose.yml" ]; then
  log "DEPLOY_PATH does not look like ChatOS (missing src/frontend and docker-compose.yml)."
  exit 1
fi

cd "$DEPLOY_PATH"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log "DEPLOY_PATH is not a git repository: $DEPLOY_PATH"
  exit 1
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "$DEPLOY_REF" ]; then
  log "Refusing to deploy from non-target branch: ${current_branch} (expected ${DEPLOY_REF})"
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  log "Working tree is not clean; resolve local changes before deploy."
  exit 1
fi

ensure_safe_env

lock_file="${DEPLOY_PATH}/.deploy.lock"
exec 9>"$lock_file"
if ! flock -n 9; then
  log "Another deploy is in progress; exiting."
  exit 1
fi

export GIT_TERMINAL_PROMPT=0

old_head="$(git rev-parse HEAD)"
summary_old_head="$old_head"
log "Current HEAD: ${old_head}"

log "Fetching origin/${DEPLOY_REF}"
git fetch --prune origin "${DEPLOY_REF}"
remote_head="$(git rev-parse "origin/${DEPLOY_REF}")"
summary_remote_head="$remote_head"
log "Target HEAD: ${remote_head}"

updated="false"
if [ "$old_head" != "$remote_head" ]; then
  updated="true"
fi
summary_updated="$updated"

if is_true "$DEPLOY_DRY_RUN"; then
  log "Dry-run mode enabled."
  if [ "$updated" = "true" ]; then
    log "Would fast-forward from ${old_head} to ${remote_head}."
  else
    log "No git changes detected."
  fi

  if is_true "${ALLOW_DB_MIGRATIONS:-}"; then
    log "Would run alembic upgrade head (ALLOW_DB_MIGRATIONS=true)."
  fi

  log "Skipping restarts and healthchecks due to dry-run."
  summary_new_head="$old_head"
  exit 0
fi

if [ "$updated" = "true" ]; then
  log "Fast-forwarding to ${remote_head}"
  git merge --ff-only "origin/${DEPLOY_REF}"
else
  log "No git updates; HEAD unchanged."
fi

new_head="$(git rev-parse HEAD)"
summary_new_head="$new_head"
log "Current HEAD after sync: ${new_head}"

migrations_ran="false"
if is_true "${ALLOW_DB_MIGRATIONS:-}"; then
  if [ ! -f "src/backend/alembic.ini" ]; then
    log "ALLOW_DB_MIGRATIONS=true but src/backend/alembic.ini is missing."
    exit 1
  fi
  require_cmd alembic
  log "Running alembic upgrade head"
  alembic -c src/backend/alembic.ini upgrade head
  migrations_ran="true"
else
  log "DB migrations disabled (ALLOW_DB_MIGRATIONS not set to true)."
fi
summary_migrations="$migrations_ran"

needs_restart="false"
if [ "$updated" = "true" ] || [ "$migrations_ran" = "true" ]; then
  needs_restart="true"
fi

if [ "$needs_restart" = "true" ]; then
  compose_cmd="$(detect_compose_cmd)"

  if has_systemd_service "chatos-backend"; then
    summary_backend_restart="systemd:chatos-backend"
    restart_systemd_service "chatos-backend"
  else
    summary_backend_restart="compose:backend"
    restart_compose_service "backend" "$compose_cmd"
  fi

  frontend_expected="false"
  if has_systemd_service "chatos-frontend"; then
    frontend_expected="true"
  elif [ -f "docker-compose.yml" ] && grep -q '^[[:space:]]*frontend:' docker-compose.yml; then
    frontend_expected="true"
  fi

  if [ "$frontend_expected" = "true" ]; then
    if has_systemd_service "chatos-frontend"; then
      summary_frontend_restart="systemd:chatos-frontend"
      restart_systemd_service "chatos-frontend"
    else
      summary_frontend_restart="compose:frontend"
      restart_compose_service "frontend" "$compose_cmd"
    fi
  else
    summary_frontend_restart="skipped:not-detected"
    log "Frontend service not detected; skipping frontend restart."
  fi

  if [ -x "$healthcheck_path" ]; then
    log "Running healthchecks"
    summary_healthcheck="running"
    if ! "$healthcheck_path"; then
      summary_healthcheck="failed"
      log "Healthcheck failed."
      exit 1
    fi
    summary_healthcheck="ok"
    log "Healthchecks passed."
  else
    summary_healthcheck="skipped:missing"
    log "Healthcheck script not found or not executable; skipping."
  fi
else
  log "No restart required."
  summary_healthcheck="skipped:no-restart"
fi
