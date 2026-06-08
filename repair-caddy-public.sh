#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_CONFIG="/etc/rixxx-panel/config.json"
PANEL_DIR="/opt/panel-naive-mieru"
CADDY_CFG_DIR="/etc/caddy-naive"
CADDY_FILE="/etc/caddy-naive/Caddyfile"
CADDY_STORAGE="/var/lib/caddy"
CADDY_LOG_DIR="/var/log/caddy-naive"
LOG_FILE="/var/log/rixxx-panel-repair.log"

exec > >(tee -a "$LOG_FILE") 2>&1

cleanup_locks() {
  local lock_dir="$CADDY_STORAGE/caddy/locks"
  if [[ -d "$lock_dir" ]]; then
    log "Removing stale Caddy lock files from $lock_dir"
    find "$lock_dir" -type f -delete || true
  fi
  find "$CADDY_STORAGE" -type f -name '*.lock' -delete 2>/dev/null || true
}

fix_permissions() {
  log "Fixing Caddy permissions"
  mkdir -p "$CADDY_CFG_DIR" "$CADDY_STORAGE" "$CADDY_LOG_DIR"
  chown -R caddy:caddy "$CADDY_STORAGE" "$CADDY_LOG_DIR" 2>/dev/null || true
  chown root:caddy "$CADDY_CFG_DIR" 2>/dev/null || true
  chmod 750 "$CADDY_CFG_DIR" 2>/dev/null || true
  [[ -f "$CADDY_FILE" ]] && chown root:caddy "$CADDY_FILE" 2>/dev/null || true
  [[ -f "$CADDY_FILE" ]] && chmod 640 "$CADDY_FILE" 2>/dev/null || true
}

stop_services() {
  log "Stopping caddy-naive"
  systemctl stop caddy-naive 2>/dev/null || true
  if command -v pm2 >/dev/null 2>&1; then
    log "Restarting panel process later through update.sh"
  fi
}

sync_panel_files() {
  if [[ ! -d "$ROOT_DIR/panel" ]]; then
    die "Missing panel source directory: $ROOT_DIR/panel"
  fi

  log "Syncing fresh panel files into $PANEL_DIR"
  mkdir -p "$PANEL_DIR"
  cp -a "$ROOT_DIR/panel/." "$PANEL_DIR/"
  [[ -f "$ROOT_DIR/update.sh" ]] && cp "$ROOT_DIR/update.sh" "$PANEL_DIR/update.sh" 2>/dev/null || true
  [[ -f "$ROOT_DIR/install.sh" ]] && cp "$ROOT_DIR/install.sh" "$PANEL_DIR/install.sh" 2>/dev/null || true
  [[ -f "$ROOT_DIR/repair-caddy-public.sh" ]] && cp "$ROOT_DIR/repair-caddy-public.sh" "$PANEL_DIR/repair-caddy-public.sh" 2>/dev/null || true
}

rebuild_configs() {
  if [[ ! -f "$PANEL_CONFIG" ]]; then
    die "Missing panel config: $PANEL_CONFIG"
  fi
  if [[ ! -f "$ROOT_DIR/update.sh" ]]; then
    die "update.sh not found in $ROOT_DIR"
  fi
  log "Rebuilding config through update.sh --repair"
  ( cd "$ROOT_DIR" && bash update.sh --repair -y )
}

restart_services() {
  log "Restarting caddy-naive"
  systemctl reset-failed caddy-naive 2>/dev/null || true
  systemctl restart caddy-naive
  sleep 2
  systemctl is-active --quiet caddy-naive || die "caddy-naive did not become active"
}

verify_https() {
  local host
  host="$(jq -r '.domain // empty' "$PANEL_CONFIG" 2>/dev/null || true)"
  local path
  path="$(jq -r '.panelPath // "/admin"' "$PANEL_CONFIG" 2>/dev/null || echo /admin)"
  if [[ -n "$host" ]]; then
    log "Verifying HTTPS handshake for ${host}${path}"
    curl -vk "https://127.0.0.1${path}/" -H "Host: $host" >/tmp/rixxx-panel-repair-curl.log 2>&1 || true
    if grep -q "SSL connection" /tmp/rixxx-panel-repair-curl.log 2>/dev/null; then
      log "TLS handshake looks alive"
    else
      warn "TLS handshake did not confirm cleanly; inspect /tmp/rixxx-panel-repair-curl.log"
      return 0
    fi

    local code
    code="$(curl -sk -o /tmp/rixxx-panel-repair-body.html -w '%{http_code}' "https://127.0.0.1${path}/" -H "Host: $host" || true)"
    if [[ "$code" == "200" || "$code" == "302" ]]; then
      log "Public panel route returned HTTP $code"
      rm -f /tmp/rixxx-panel-repair-curl.log /tmp/rixxx-panel-repair-body.html
    else
      warn "Public panel route returned HTTP ${code:-unknown}; inspect /tmp/rixxx-panel-repair-curl.log and /tmp/rixxx-panel-repair-body.html"
    fi
  fi
}

main() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo bash repair-caddy-public.sh"
  [[ -f "$PANEL_CONFIG" ]] || die "Panel is not installed: $PANEL_CONFIG is missing"

  log "Starting repair"
  stop_services
  cleanup_locks
  fix_permissions
  sync_panel_files
  rebuild_configs
  fix_permissions
  restart_services
  verify_https
  log "Repair complete"
}

main "$@"
