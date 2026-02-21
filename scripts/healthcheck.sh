#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Missing required command: $1"
    exit 1
  fi
}

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8000/health}"
FRONTEND_URL="${FRONTEND_URL:-http://127.0.0.1:3000}"

require_cmd curl

log "Checking backend health: ${BACKEND_URL}"
curl --fail --silent --show-error --max-time 5 "$BACKEND_URL" >/dev/null
log "Backend healthy."

frontend_expected="false"
if command -v systemctl >/dev/null 2>&1; then
  if systemctl list-unit-files --type=service --no-pager 2>/dev/null | awk '{print $1}' | grep -Fxq "chatos-frontend.service"; then
    frontend_expected="true"
  fi
fi

if [ -f "docker-compose.yml" ] && grep -q '^[[:space:]]*frontend:' docker-compose.yml; then
  frontend_expected="true"
fi

if [ "$frontend_expected" = "true" ]; then
  log "Checking frontend health: ${FRONTEND_URL}"
  curl --fail --silent --show-error --max-time 5 "$FRONTEND_URL" >/dev/null
  log "Frontend healthy."
else
  if curl --fail --silent --show-error --max-time 5 "$FRONTEND_URL" >/dev/null; then
    log "Frontend healthy."
  else
    log "Frontend not detected; skipping frontend healthcheck."
  fi
fi
