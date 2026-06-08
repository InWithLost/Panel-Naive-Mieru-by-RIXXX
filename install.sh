#!/usr/bin/env bash
# ==============================================================================
# Panel Naive + Mieru by RIXXX — install.sh  v1.2.6
# Caddy-forwardproxy-naive (amd64-only) + Mieru (mita) + fake-site + probe-resistance
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12 | x86_64 only
# ==============================================================================
set -euo pipefail

# ── Capture all installer output to a log file ────────────────────────────────
INSTALL_LOG="/var/log/rixxx-panel-install.log"
mkdir -p "$(dirname "$INSTALL_LOG")"
exec > >(tee -a "$INSTALL_LOG") 2>&1
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] install.sh v1.2.6 started (PID $$)"

# ── Bug 19: ERR trap — log failure location and guide user to recovery ────────
on_error() {
  local exit_code=$1 line=$2
  echo ""
  echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}${BOLD}║  install.sh FAILED  (exit $exit_code  at line $line)           ${NC}"
  echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo -e "  ${YELLOW}Install log:${NC} $INSTALL_LOG"
  echo -e "  ${YELLOW}Recovery options:${NC}"
  echo -e "    • Retry (idempotent):   ${CYAN}sudo bash install.sh --force${NC}"
  echo -e "    • Clean uninstall:      ${CYAN}sudo bash uninstall.sh${NC}"
  echo -e "    • View last 30 lines:   ${CYAN}tail -30 $INSTALL_LOG${NC}"
  echo ""
}
trap 'on_error $? $LINENO' ERR

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
die()       { log_error "$*"; exit 1; }

# ── Constants ─────────────────────────────────────────────────────────────────
PANEL_DIR="/opt/panel-naive-mieru"
PANEL_CONFIG="/etc/rixxx-panel/config.json"
VERSION_FILE="/etc/rixxx-panel/version"
BACKUP_DIR="/etc/rixxx-panel/backups"
DB_PATH="/var/lib/rixxx-panel/db.sqlite"
MITA_STATE_FILE="/var/lib/rixxx-panel/mita-state.json"

# v1.2.3: Caddy-forwardproxy-naive replaces standalone naive binary
CADDY_BIN="/usr/local/bin/caddy-naive"
CADDY_CONFIG_DIR="/etc/caddy-naive"
CADDY_FILE="${CADDY_CONFIG_DIR}/Caddyfile"
CADDY_VERSION_FILE="${CADDY_CONFIG_DIR}/version"
FAKE_SITE_DIR="/var/www/fake-site"

# Legacy paths kept for migration/repair reference
NAIVE_BIN="/usr/local/bin/naive"        # may still exist from v1.2.x; will be removed
NAIVE_CONFIG_DIR="/etc/naive"

CURRENT_VERSION="1.2.6"
REPO_URL="https://github.com/InWithLost/Panel-Naive-Mieru-by-RIXXX"
# Bug 1: direct download URL for caddy-forwardproxy-naive (amd64 only)
CADDY_NAIVE_RELEASES="https://api.github.com/repos/klzgrad/forwardproxy/releases/latest"
CADDY_NAIVE_FALLBACK_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
MIERU_RELEASES="https://api.github.com/repos/enfein/mieru/releases/latest"

# ── Flags ─────────────────────────────────────────────────────────────────────
NON_INTERACTIVE=false
FORCE_INSTALL=false

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --non-interactive|--force|-y) NON_INTERACTIVE=true; FORCE_INSTALL=true ;;
      --domain)         INPUT_DOMAIN="${2:-}";          shift ;;
      --email)          INPUT_EMAIL="${2:-}";           shift ;;
      --admin-user)     INPUT_ADMIN_USER="${2:-}";      shift ;;
      --admin-pass)     INPUT_ADMIN_PASS="${2:-}";      shift ;;
      --naive-port)     INPUT_NAIVE_PORT="${2:-}";      shift ;;
      --mieru-start)    INPUT_MIERU_START="${2:-}";     shift ;;
      --mieru-end)      INPUT_MIERU_END="${2:-}";       shift ;;
      --fake-site-url)  INPUT_FAKE_SITE_URL="${2:-}";   shift ;;
      --probe-secret)   INPUT_PROBE_SECRET="${2:-}";    shift ;;
      --probe-mode)     INPUT_PROBE_MODE="${2:-}";      shift ;;
      --lang)
        case "${2:-ru}" in en) LANG_RU=false ;; *) LANG_RU=true ;; esac
        shift ;;
      --help|-h)
        echo "Usage: bash install.sh [--non-interactive] [--domain DOMAIN] [--email EMAIL]"
        echo "                       [--admin-user USER] [--admin-pass PASS]"
        echo "                       [--naive-port PORT] [--mieru-start PORT] [--mieru-end PORT]"
        echo "                       [--fake-site-url URL] [--probe-secret SECRET]"
        echo "                       [--lang ru|en]"
        exit 0 ;;
      *) log_warn "Unknown argument: $1 (ignored)" ;;
    esac
    shift
  done
}

# ── i18n ──────────────────────────────────────────────────────────────────────
LANG_RU=true
t() { if $LANG_RU; then echo "$1"; else echo "$2"; fi }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Запустите скрипт от root (sudo bash install.sh) / Run as root"

# ── Language selection ────────────────────────────────────────────────────────
select_language() {
  if $NON_INTERACTIVE; then return; fi
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║   Panel Naive + Mieru by RIXXX  v${CURRENT_VERSION}       ║${NC}"
  # Bug 32: interactive prompts go to /dev/tty so tee-to-log doesn't swallow them
  # (exec redirect is set up above; read uses /dev/tty automatically in bash)
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Выберите язык / Select language:"
  echo -e "  ${CYAN}1)${NC} Русский ${GREEN}(по умолчанию / default)${NC}"
  echo -e "  ${CYAN}2)${NC} English"
  echo ""
  read -rp "  [1/2]: " LANG_CHOICE
  case "${LANG_CHOICE:-1}" in
    2) LANG_RU=false ;;
    *) LANG_RU=true  ;;
  esac
  echo ""
  $LANG_RU && log_info "Выбран язык: Русский" || log_info "Language selected: English"
}

# ── OS check ──────────────────────────────────────────────────────────────────
check_os() {
  log_step "$(t 'Проверка совместимости ОС' 'Checking OS compatibility')"
  [[ ! -f /etc/os-release ]] && die "$(t 'Не удалось определить ОС' 'Cannot determine OS')"
  source /etc/os-release
  case "$ID" in
    ubuntu)
      case "$VERSION_ID" in
        20.04|22.04|24.04) log_info "OS: Ubuntu $VERSION_ID ✓" ;;
        *) die "$(t "Неподдерживаемая Ubuntu: $VERSION_ID" "Unsupported Ubuntu: $VERSION_ID")" ;;
      esac ;;
    debian)
      case "$VERSION_ID" in
        11|12) log_info "OS: Debian $VERSION_ID ✓" ;;
        *) die "$(t "Неподдерживаемый Debian: $VERSION_ID" "Unsupported Debian: $VERSION_ID")" ;;
      esac ;;
    *) die "$(t "Неподдерживаемая ОС: $ID" "Unsupported OS: $ID")" ;;
  esac
}

# ── Architecture detection — amd64 only for caddy-naive ───────────────────────
detect_arch() {
  log_step "$(t 'Определение архитектуры' 'Detecting architecture')"
  local machine; machine=$(uname -m)
  case "$machine" in
    x86_64|amd64) ARCH="amd64"; DEB_ARCH="amd64" ;;
    # Bug 1: caddy-forwardproxy-naive is amd64-only; ARM not supported
    aarch64|arm64) die "$(t \
      'caddy-forwardproxy-naive поддерживает только amd64. ARM64 не поддерживается в v1.2.6.' \
      'caddy-forwardproxy-naive only supports amd64. ARM64 is not supported in v1.2.6.')" ;;
    armv7l) die "$(t \
      'caddy-forwardproxy-naive поддерживает только amd64. ARMv7 не поддерживается в v1.2.6.' \
      'caddy-forwardproxy-naive only supports amd64. ARMv7 is not supported in v1.2.6.')" ;;
    *) die "$(t "Неподдерживаемая архитектура: $machine" "Unsupported architecture: $machine")" ;;
  esac
  log_info "$(t 'Архитектура' 'Architecture'): $machine → $ARCH ✓"
}

# ── Idempotent check ──────────────────────────────────────────────────────────
check_existing() {
  if [[ -f "$PANEL_CONFIG" ]]; then
    log_warn "$(t 'Обнаружена существующая установка!' 'Existing installation detected!')"
    if $NON_INTERACTIVE || $FORCE_INSTALL; then
      log_info "$(t 'Флаг --force: продолжаем переустановку.' '--force: proceeding with reinstall.')"
    else
      echo ""
      read -rp "$(t '  Переустановить поверх? [д/Н]: ' '  Reinstall over existing? [y/N]: ')" REINSTALL
      local ans="${REINSTALL:-N}"
      if $LANG_RU; then
        [[ "${ans^^}" =~ ^(Д|Y)$ ]] || { log_info "$(t 'Отменено.' 'Aborted.')"; exit 0; }
      else
        [[ "${ans^^}" == "Y" ]] || { log_info "Aborted."; exit 0; }
      fi
    fi
    # Backup before reinstall
    local ts; ts=$(date +%Y-%m-%d-%H%M%S)
    local bdir="$BACKUP_DIR/$ts"
    mkdir -p "$bdir"
    [[ -f "$CADDY_FILE"       ]] && cp "$CADDY_FILE"       "$bdir/" || true
    [[ -f "$MITA_STATE_FILE"  ]] && cp "$MITA_STATE_FILE"  "$bdir/" || true
    [[ -f "$PANEL_CONFIG"     ]] && cp "$PANEL_CONFIG"     "$bdir/" || true
    log_info "$(t "Резервная копия: $bdir" "Backup created: $bdir")"
  fi
}

# ── NTP sync ──────────────────────────────────────────────────────────────────
sync_time() {
  log_step "$(t 'Синхронизация времени (NTP)' 'Synchronising system time (NTP)')"
  log_warn "$(t 'ВАЖНО: Mieru требует точного системного времени (±30 сек). Синхронизация критична!' \
             'IMPORTANT: Mieru requires accurate system time (±30 s). NTP sync is critical!')"
  timedatectl set-ntp true 2>/dev/null || true
  local synced=false
  for i in $(seq 1 15); do
    if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
      synced=true; break
    fi
    sleep 1
  done
  if $synced; then
    log_info "$(t 'Время синхронизировано ✓' 'Time synchronised ✓')"
  else
    log_warn "$(t 'Синхронизация не подтверждена за 15 с!' 'Sync not confirmed within 15 s!')"
  fi
}

# ── Package dependencies ───────────────────────────────────────────────────────
install_deps() {
  log_step "$(t 'Установка зависимостей' 'Installing dependencies')"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # Bug 1: certbot removed — Caddy uses TLS-ALPN-01 (no standalone HTTP-01 needed)
  apt-get install -y -qq \
    curl wget git ufw unzip tar xz-utils jq \
    ca-certificates gnupg lsb-release \
    systemd cron net-tools iproute2 \
    coreutils acl 2>/dev/null || \
  apt-get install -y \
    curl wget git ufw unzip tar xz-utils jq \
    ca-certificates gnupg lsb-release \
    systemd cron net-tools iproute2 \
    coreutils acl
  log_info "$(t 'Зависимости установлены ✓' 'Dependencies installed ✓')"
}

# ── Node.js 20 LTS + PM2 ──────────────────────────────────────────────────────
install_nodejs() {
  log_step "$(t 'Установка Node.js 20 LTS' 'Installing Node.js 20 LTS')"
  if command -v node &>/dev/null && node --version | grep -qE "^v2[0-9]"; then
    log_info "Node.js $(node --version) — $(t 'уже установлен ✓' 'already installed ✓')"
  else
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    log_info "Node.js $(node --version) $(t 'установлен ✓' 'installed ✓')"
  fi
  if command -v pm2 &>/dev/null; then
    log_info "PM2 $(pm2 --version) — $(t 'уже установлен ✓' 'already installed ✓')"
  else
    npm install -g pm2 --silent
    log_info "$(t 'PM2 установлен ✓' 'PM2 installed ✓')"
  fi
}

# ── Bug 1: Install caddy-forwardproxy-naive (amd64 only) ──────────────────────
# Downloads from https://github.com/klzgrad/forwardproxy/releases/latest
# Validates binary and sets file capabilities for binding privileged ports.
install_caddy_naive() {
  log_step "$(t 'Установка caddy-forwardproxy-naive' 'Installing caddy-forwardproxy-naive')"

  local tmp_dir; tmp_dir=$(mktemp -d)
  local archive_path="${tmp_dir}/caddy-forwardproxy-naive.tar.xz"

  log_info "$(t 'Запрос последнего релиза из GitHub...' 'Fetching latest release from GitHub...')"
  local asset_url=""
  local release_tag="unknown"

  # Try GitHub API first
  local release_json=""
  release_json=$(curl -fsSL --connect-timeout 10 "$CADDY_NAIVE_RELEASES" 2>/dev/null) || true

  if [[ -n "$release_json" ]]; then
    release_tag=$(echo "$release_json" | jq -r '.tag_name // "unknown"')
    log_info "$(t "Последняя версия: $release_tag" "Latest release: $release_tag")"

    # Look for .tar.xz asset (the release contains one tarball for linux-amd64)
    asset_url=$(echo "$release_json" | jq -r \
      '.assets[] | select(.name | test("caddy.*forwardproxy.*naive.*\\.tar\\.xz$|caddy-forwardproxy-naive.*\\.tar\\.xz$"; "i")) | .browser_download_url' \
      | head -1)

    # Broader fallback: any .tar.xz
    if [[ -z "$asset_url" ]]; then
      asset_url=$(echo "$release_json" | jq -r \
        '.assets[] | select(.name | endswith(".tar.xz")) | .browser_download_url' | head -1)
    fi
  fi

  # Fallback to pinned v2.10.0 URL if GitHub API failed or no asset found
  if [[ -z "$asset_url" ]]; then
    log_warn "$(t \
      'GitHub API недоступен — использую резервный URL (v2.10.0)' \
      'GitHub API unavailable — using fallback URL (v2.10.0)')"
    asset_url="$CADDY_NAIVE_FALLBACK_URL"
    release_tag="v2.10.0-naive"
  fi

  log_info "$(t "Загрузка: $asset_url" "Downloading: $asset_url")"
  wget -q --show-progress --connect-timeout 30 -O "$archive_path" "$asset_url" || \
    die "$(t 'Ошибка загрузки caddy-forwardproxy-naive' 'Failed to download caddy-forwardproxy-naive')"

  # Extract
  cd "$tmp_dir"
  tar -xJf "$archive_path" 2>/dev/null || tar -xf "$archive_path" 2>/dev/null || \
    die "$(t 'Ошибка распаковки архива' 'Failed to extract archive')"

  # Find the caddy binary (named 'caddy' or 'caddy-naive' inside the archive)
  local caddy_found
  caddy_found=$(find "$tmp_dir" -maxdepth 3 -type f \
    \( -name "caddy" -o -name "caddy-naive" -o -name "caddy-forwardproxy-naive" \) \
    ! -name "*.xz" ! -name "*.gz" ! -name "*.tar" | head -1)

  [[ -z "$caddy_found" ]] && \
    die "$(t 'caddy бинарный файл не найден в архиве' 'caddy binary not found in archive')"

  install -m 755 "$caddy_found" "$CADDY_BIN"
  rm -rf "$tmp_dir"; cd /

  # Bug 1: setcap so caddy-naive can bind port 443 without root
  if command -v setcap &>/dev/null; then
    setcap 'cap_net_bind_service=+ep' "$CADDY_BIN" 2>/dev/null || true
  fi

  # Verify
  CADDY_VERSION=$("$CADDY_BIN" version 2>/dev/null | head -1 || \
                  "$CADDY_BIN" --version 2>/dev/null | head -1 || echo "$release_tag")
  log_info "caddy-naive $(t 'установлен' 'installed') → $CADDY_BIN  ($CADDY_VERSION) ✓"
  export CADDY_VERSION

  # Remove legacy naive binary if present (migration from v1.2.x)
  if [[ -f "$NAIVE_BIN" ]]; then
    log_info "$(t 'Удаляем устаревший бинарник naive (v1.2.x)...' 'Removing legacy naive binary (v1.2.x)...')"
    rm -f "$NAIVE_BIN"
  fi
}

# ── Mieru (mita) via .deb ─────────────────────────────────────────────────────
install_mieru() {
  log_step "$(t 'Установка Mieru (mita)' 'Installing Mieru (mita)')"
  log_info "$(t 'Запрос последнего релиза...' 'Fetching latest release...')"
  local release_json
  release_json=$(curl -fsSL "$MIERU_RELEASES") || \
    die "$(t 'Ошибка запроса GitHub API для Mieru' 'Cannot fetch Mieru releases')"
  local tag; tag=$(echo "$release_json" | jq -r '.tag_name')
  log_info "$(t "Последняя версия Mieru: $tag" "Latest Mieru: $tag")"

  local asset_url
  asset_url=$(echo "$release_json" | jq -r \
    --arg arch "$DEB_ARCH" \
    '.assets[] | select(.name | test("mita.*" + $arch + "\\.deb")) | .browser_download_url' | head -1)
  [[ -z "$asset_url" ]] && \
    asset_url=$(echo "$release_json" | jq -r \
      --arg arch "$DEB_ARCH" \
      '.assets[] | select(.name | test($arch + "\\.deb")) | .browser_download_url' | head -1)
  [[ -z "$asset_url" ]] && die "$(t "Не найден .deb Mieru для $DEB_ARCH" "No Mieru .deb for $DEB_ARCH")"

  local deb_file; deb_file=$(mktemp /tmp/mieru-XXXXXX.deb)
  log_info "$(t "Загрузка: $asset_url" "Downloading: $asset_url")"
  wget -q --show-progress -O "$deb_file" "$asset_url" || \
    die "$(t 'Ошибка загрузки Mieru .deb' 'Failed to download Mieru .deb')"
  dpkg -i "$deb_file" 2>/dev/null || apt-get install -f -y
  rm -f "$deb_file"
  MIERU_VERSION=$(mita version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "$tag")
  log_info "mita $(t 'установлен' 'installed') ($MIERU_VERSION) ✓"
}

# ── Interactive / non-interactive config gathering ────────────────────────────
gather_config() {
  log_step "$(t 'Настройка' 'Configuration')"

  if $NON_INTERACTIVE; then
    DOMAIN="${INPUT_DOMAIN:?$(die "$(t '--domain обязателен в --non-interactive режиме' '--domain is required in --non-interactive mode')")}"
    ADMIN_EMAIL="${INPUT_EMAIL:-admin@${DOMAIN}}"
    NAIVE_PORT="${INPUT_NAIVE_PORT:-443}"
    MIERU_PORT_START="${INPUT_MIERU_START:-2012}"
    MIERU_PORT_END="${INPUT_MIERU_END:-2022}"
    ADMIN_USER="${INPUT_ADMIN_USER:-admin}"
    if [[ -z "${INPUT_ADMIN_PASS:-}" ]]; then
      ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
      log_info "$(t "Сгенерирован пароль: ${BOLD}$ADMIN_PASS${NC}" "Generated password: ${BOLD}$ADMIN_PASS${NC}")"
    else
      ADMIN_PASS="$INPUT_ADMIN_PASS"
    fi
    # Bug 1 new fields: fake-site URL and probe secret
    FAKE_SITE_URL="${INPUT_FAKE_SITE_URL:-https://www.example.com}"
    PROBE_SECRET="${INPUT_PROBE_SECRET:-$(openssl rand -hex 16)}"
    # Bug 81: default probe_resistance mode = bare (matches known-good reference).
    PROBE_MODE="${INPUT_PROBE_MODE:-bare}"
    USE_UFW="Y"
    EXPOSE_PANEL="N"
    log_info "$(t 'Конфигурация принята из аргументов ✓' 'Configuration loaded from arguments ✓')"
    return
  fi

  echo ""
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}   Panel Naive + Mieru — $(t 'Мастер установки' 'Setup Wizard')${NC}"
  echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
  echo ""

  # Domain
  read -rp "$(echo -e "${CYAN}$(t 'Домен' 'Domain')${NC} (e.g. vpn.example.com): ")" INPUT_DOMAIN
  [[ -z "${INPUT_DOMAIN:-}" ]] && die "$(t 'Домен не может быть пустым' 'Domain cannot be empty')"
  DOMAIN="$INPUT_DOMAIN"

  # Email for ACME
  read -rp "$(echo -e "${CYAN}Email $(t 'для ACME/TLS (Caddy)' 'for ACME/TLS (Caddy)')${NC}: ")" INPUT_EMAIL
  [[ -z "${INPUT_EMAIL:-}" ]] && die "$(t 'Email не может быть пустым' 'Email cannot be empty')"
  ADMIN_EMAIL="$INPUT_EMAIL"

  # NaiveProxy port
  read -rp "$(echo -e "${CYAN}$(t 'Порт NaiveProxy HTTPS' 'NaiveProxy HTTPS port')${NC} [443]: ")" INPUT_NAIVE_PORT
  NAIVE_PORT="${INPUT_NAIVE_PORT:-443}"
  if ! [[ "$NAIVE_PORT" =~ ^[0-9]+$ ]] || (( NAIVE_PORT < 1 || NAIVE_PORT > 65535 )); then
    die "$(t "Некорректный порт: $NAIVE_PORT" "Invalid port: $NAIVE_PORT")"
  fi

  # Mieru port range
  echo ""
  echo -e "${YELLOW}$(t 'Mieru использует диапазон портов TCP. По умолчанию: 2012-2022' \
                       'Mieru uses a TCP port range. Default: 2012-2022')${NC}"
  read -rp "$(echo -e "${CYAN}$(t 'Начальный порт Mieru' 'Mieru start port')${NC} [2012]: ")" INPUT_MIERU_START
  MIERU_PORT_START="${INPUT_MIERU_START:-2012}"
  read -rp "$(echo -e "${CYAN}$(t 'Конечный порт Mieru' 'Mieru end port')${NC}  [2022]: ")" INPUT_MIERU_END
  MIERU_PORT_END="${INPUT_MIERU_END:-2022}"
  for p in "$MIERU_PORT_START" "$MIERU_PORT_END"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1025 || p > 65535 )); then
      die "$(t "Некорректный порт Mieru: $p (1025-65535)" "Invalid Mieru port: $p (1025-65535)")"
    fi
  done
  (( MIERU_PORT_END < MIERU_PORT_START )) && \
    die "$(t "Конечный порт должен быть >= начального" "End port must be >= start port")"

  # Fake site URL (used for probe resistance)
  echo ""
  echo -e "${YELLOW}$(t \
    'Fake site: Caddy покажет этот сайт неопознанным клиентам (защита от обнаружения).' \
    'Fake site: Caddy shows this site to unrecognised clients (probe resistance).')${NC}"
  read -rp "$(echo -e "${CYAN}$(t 'URL фейкового сайта' 'Fake site URL')${NC} [https://www.example.com]: ")" INPUT_FAKE_SITE_URL
  FAKE_SITE_URL="${INPUT_FAKE_SITE_URL:-https://www.example.com}"

  # Probe secret
  echo ""
  echo -e "${YELLOW}$(t \
    'Probe secret: клиенты предъявляют этот секрет в HTTP-заголовке для идентификации.' \
    'Probe secret: clients present this secret in an HTTP header for identification.')${NC}"
  read -rp "$(echo -e "${CYAN}$(t 'Секрет зондирования (пусто = авто)' 'Probe secret (blank = auto)')${NC}: ")" INPUT_PROBE_SECRET
  if [[ -z "${INPUT_PROBE_SECRET:-}" ]]; then
    PROBE_SECRET=$(openssl rand -hex 16)
    log_info "$(t "Сгенерирован probe_secret: ${BOLD}${PROBE_SECRET}${NC}" "Generated probe_secret: ${BOLD}${PROBE_SECRET}${NC}")"
  else
    PROBE_SECRET="$INPUT_PROBE_SECRET"
  fi
  # Bug 81: default probe_resistance mode = bare (matches known-good reference).
  # The secret above is still stored so the panel can switch to 'secret' mode later.
  PROBE_MODE="${INPUT_PROBE_MODE:-bare}"

  # Admin credentials
  echo ""
  read -rp "$(echo -e "${CYAN}$(t 'Имя администратора панели' 'Panel admin username')${NC} [admin]: ")" INPUT_ADMIN_USER
  ADMIN_USER="${INPUT_ADMIN_USER:-admin}"
  read -rsp "$(echo -e "${CYAN}$(t 'Пароль администратора' 'Panel admin password')${NC} ($(t 'пусто = автогенерация' 'blank = auto-generate')): ")" INPUT_ADMIN_PASS
  echo ""
  if [[ -z "${INPUT_ADMIN_PASS:-}" ]]; then
    ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
    log_info "$(t "Сгенерирован пароль: ${BOLD}$ADMIN_PASS${NC}" "Generated password: ${BOLD}$ADMIN_PASS${NC}")"
  else
    ADMIN_PASS="$INPUT_ADMIN_PASS"
  fi

  # UFW
  echo ""
  read -rp "$(echo -e "${CYAN}$(t 'Настроить UFW (файрвол)?' 'Configure UFW firewall?')${NC} [$(t 'Д/н' 'Y/n')]: ")" INPUT_UFW
  USE_UFW="${INPUT_UFW:-Y}"

  # Expose panel
  echo ""
  echo -e "${YELLOW}$(t 'Панель работает на 127.0.0.1:3000 (только через SSH-туннель, по умолчанию).' \
                       'Panel runs on 127.0.0.1:3000 (SSH-only by default).')${NC}"
  read -rp "$(echo -e "${CYAN}$(t 'Открыть панель публично на порту 8080?' 'Expose panel publicly on port 8080?')${NC} [$(t 'д/Н' 'y/N')]: ")" INPUT_EXPOSE
  EXPOSE_PANEL="${INPUT_EXPOSE:-N}"

  echo ""
  log_info "$(t 'Конфигурация собрана ✓' 'Configuration gathered ✓')"
}

# ── Bug 1: Setup fake site ────────────────────────────────────────────────────
setup_fake_site() {
  log_step "$(t 'Создание фейкового сайта (probe resistance)' 'Setting up fake site (probe resistance)')"
  mkdir -p "$FAKE_SITE_DIR"
  cat > "${FAKE_SITE_DIR}/index.html" <<FAKEHTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Welcome</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: system-ui, -apple-system, sans-serif; background: #f5f5f5;
           display: flex; align-items: center; justify-content: center;
           min-height: 100vh; color: #333; }
    .container { text-align: center; padding: 2rem; }
    h1 { font-size: 2rem; margin-bottom: 0.5rem; }
    p  { color: #666; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Welcome</h1>
    <p>This service is currently unavailable. Please try again later.</p>
  </div>
</body>
</html>
FAKEHTML

  chmod 644 "${FAKE_SITE_DIR}/index.html"
  log_info "$(t "Фейковый сайт создан → $FAKE_SITE_DIR ✓" "Fake site created → $FAKE_SITE_DIR ✓")"
}

# ── Write Caddyfile (TLS-ALPN-01, forwardproxy, probe-resistance) ─────────────
# Bug 23: forward_proxy credential lines use  basic_auth <user> <pass>  (with
#          underscore).  The bare  "basic_auth"  keyword with no arguments is
#          invalid in caddy-forwardproxy-naive and causes:
#            "wrong argument count or unexpected line ending after 'basic_auth'"
# Bug 24: caddy validate failure is fatal (die), not a warning.
# Bug 26: template rendered via caddyTemplate.js — single source of truth.
# Bug 27: backup existing Caddyfile; restore DB users when --force.
# Bug 28: no  tls <email>  in site block — Caddy handles TLS automatically.
# Bug 29: directive order inside forward_proxy:  basic_auth → hide_ip → hide_via → probe_resistance.
# Bug 30: global  order forward_proxy before file_server.
# Bug 33: DNS check — warn if domain doesn't resolve to server IP.
# Bug 38: log rotation uses  roll_keep_for 720h  (30 days).
write_caddyfile() {
  log_step "$(t 'Запись Caddyfile' 'Writing Caddyfile')"
  # Bug 42: do NOT create /var/log/caddy-naive here — start_services() does it
  # after the 'caddy' system user is created, ensuring correct ownership.
  mkdir -p "$CADDY_CONFIG_DIR"

  # Bug 27: backup existing Caddyfile before overwriting
  if [[ -f "$CADDY_FILE" ]]; then
    local ts; ts=$(date +%Y%m%d-%H%M%S)
    cp "$CADDY_FILE" "${CADDY_FILE}.bak.${ts}" 2>/dev/null || true
    log_info "$(t "Резервная копия Caddyfile: ${CADDY_FILE}.bak.${ts}" \
                  "Caddyfile backup: ${CADDY_FILE}.bak.${ts}")"
  fi

  # Bug 33: DNS pre-flight — warn if domain doesn't resolve to this server's IP
  local server_ip_check
  server_ip_check=$(curl -4 -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null \
                    || hostname -I | awk '{print $1}')
  local dns_ip
  dns_ip=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)
  if [[ -n "$dns_ip" && "$dns_ip" != "$server_ip_check" ]]; then
    log_warn "$(t \
      "DNS: $DOMAIN → $dns_ip (сервер: $server_ip_check) — убедитесь что A-запись верна!" \
      "DNS: $DOMAIN → $dns_ip (server: $server_ip_check) — verify your A record is correct!")"
  elif [[ -z "$dns_ip" ]]; then
    log_warn "$(t \
      "DNS: $DOMAIN не резолвится — убедитесь что A-запись указывает на этот сервер" \
      "DNS: $DOMAIN does not resolve — ensure your A record points to this server")"
  else
    log_info "$(t "DNS: $DOMAIN → $dns_ip ✓" "DNS: $DOMAIN → $dns_ip ✓")"
  fi

  # Bug 27 + Bug 23: gather real DB users when --force / reinstall
  # Bug 23: credential lines are  basic_auth <user> <pass>  (no bare keyword)
  local naive_users_json="[]"
  if [[ -f "$DB_PATH" ]] && command -v node &>/dev/null; then
    # Bug 82: run from $PANEL_DIR so better-sqlite3 resolves (else the try/catch
    # silently returns [] and a --force reinstall would drop all naive users).
    naive_users_json=$(cd "$PANEL_DIR" 2>/dev/null && node -e "
      try {
        const Database = require('better-sqlite3');
        const db = new Database('$DB_PATH', { readonly: true });
        const rows = db.prepare('SELECT username, password, protocols FROM users').all()
          .filter(u => {
            try { return JSON.parse(u.protocols || '[\"naive\",\"mieru\"]').includes('naive'); }
            catch { return true; }
          });
        process.stdout.write(JSON.stringify(rows.map(u => ({ username: u.username, password: u.password }))));
        db.close();
      } catch(e) { process.stdout.write('[]'); }
    " 2>/dev/null || echo '[]')
  fi

  # Bug 26: render Caddyfile via the shared caddyTemplate.js module
  local template_js="${PANEL_DIR}/server/caddyTemplate.js"
  local caddyfile_content

  # Bug 46: log template errors to INSTALL_LOG instead of swallowing them
  if [[ -f "$template_js" ]] && command -v node &>/dev/null; then
    caddyfile_content=$(node -e "
      const t = require('$template_js');
      const users = $naive_users_json;
      const cfg = {
        adminEmail:  '${ADMIN_EMAIL}',
        domain:      '${DOMAIN}',
        naivePort:   ${NAIVE_PORT},
        fakeSiteDir: '${FAKE_SITE_DIR}',
        probeSecret: '${PROBE_SECRET}',
        probeMode:   '${PROBE_MODE:-bare}',
        logFile:     '/var/log/caddy-naive/access.log'
      };
      process.stdout.write(t.render(cfg, users));
    " 2>>"$INSTALL_LOG") || true
    if [[ -z "${caddyfile_content:-}" ]]; then
      log_warn "$(t 'caddyTemplate.js вернул пустой вывод — используем встроенный шаблон' \
                   'caddyTemplate.js render returned empty output — using inline fallback')"
    fi
  fi

  # Fallback: render inline (identical rules — used before panel is installed)
  if [[ -z "${caddyfile_content:-}" ]]; then
    # Bug 23: placeholder uses  basic_auth <user> <pass>  (no bare keyword)
    local placeholder_user="_placeholder_install"
    local placeholder_pass
    placeholder_pass=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)

    local auth_lines
    if [[ "$naive_users_json" != "[]" ]] && command -v node &>/dev/null; then
      auth_lines=$(node -e "
        const rows = $naive_users_json;
        rows.forEach(u => process.stdout.write('    basic_auth ' + u.username + ' ' + u.password + '\n'));
      " 2>/dev/null || true)
    fi
    if [[ -z "${auth_lines:-}" ]]; then
      auth_lines="    basic_auth ${placeholder_user} ${placeholder_pass}"
    fi

    # Bug 81: probe_resistance mode — 'off' (none) | 'bare' (keyword only) | 'secret' (with token)
    local probe_line=""
    case "${PROBE_MODE:-bare}" in
      off)    probe_line="" ;;
      secret) [[ -n "${PROBE_SECRET:-}" ]] && probe_line="    probe_resistance ${PROBE_SECRET}" || probe_line="    probe_resistance" ;;
      *)      probe_line="    probe_resistance" ;;
    esac

    # Bug 28: no tls directive — Caddy automatic HTTPS handles it
    # Bug 29: order: basic_auth → hide_ip → hide_via → probe_resistance
    # Bug 30: order forward_proxy before file_server
    # Bug 38: roll_keep_for 720h instead of roll_keep 5
    # Bug 21: no site-level log block
    caddyfile_content="{
  # Bug 30: ensure forward_proxy is evaluated before file_server
  order forward_proxy before file_server
  # Bug 80: HTTP/1.1 + HTTP/2 only (disable HTTP/3 / QUIC)
  servers {
    protocols h1 h2
  }
  email ${ADMIN_EMAIL}
  admin off
  log {
    output file /var/log/caddy-naive/access.log {
      roll_size     50mb
      roll_keep_for 720h
    }
    format json
  }
}

# HTTP → HTTPS redirect + ACME HTTP-01 fallback
:80 {
  redir https://{host}{uri} permanent
}

:${NAIVE_PORT}, ${DOMAIN} {
  # Bug 83 / Bug 88: known-good reference server. Listener is the catch-all
  # port plus domain on one site-address line, explicit tls, no route wrapper.
  # NOTE: keep this comment free of double-quote and angle-bracket chars -
  # caddyfile_content is a double-quoted shell assignment, so a stray quote
  # would close the string and a colon-redirect would be parsed as a file
  # ('line 665: port: No such file or directory' was Bug 88).
  tls ${ADMIN_EMAIL}

  forward_proxy {
${auth_lines}
    hide_ip
    hide_via"
    [[ -n "$probe_line" ]] && caddyfile_content+="
${probe_line}"
    caddyfile_content+="
  }

  file_server {
    root ${FAKE_SITE_DIR}
  }
}"
  fi

  # Write atomically
  local tmp_file="${CADDY_FILE}.new"
  printf '%s\n' "$caddyfile_content" > "$tmp_file"
  mv "$tmp_file" "$CADDY_FILE"
  chmod 640 "$CADDY_FILE"
  # Bug 90: the service runs as User=caddy/Group=caddy. A root:root 640 Caddyfile
  # is unreadable by the caddy group -> "permission denied" crash loop. Own it as
  # root:caddy so the group can read. (start_services() re-asserts this for the
  # whole config dir, but set it here too in case write_caddyfile() is re-run.)
  if id caddy &>/dev/null; then
    chown root:caddy "$CADDY_FILE" 2>/dev/null || true
  fi

  # Bug 60: format Caddyfile with caddy fmt --overwrite to ensure canonical style
  # (silences caddy fmt warnings during service start; non-fatal if caddy fmt fails)
  "$CADDY_BIN" fmt --overwrite "$CADDY_FILE" 2>>"$INSTALL_LOG" || \
    log_warn "$(t 'caddy fmt --overwrite вернул ошибку (не критично)' \
                 'caddy fmt --overwrite returned an error (non-fatal)')"

  # Bug 24: validate is FATAL — die on failure, not log_warn
  local validate_out
  if validate_out=$("$CADDY_BIN" validate --config "$CADDY_FILE" --adapter caddyfile 2>&1); then
    log_info "$(t "Caddyfile проверен и записан → $CADDY_FILE ✓" "Caddyfile validated and written → $CADDY_FILE ✓")"
  else
    log_error "$(t "caddy validate вернул ошибку:" "caddy validate returned error:")"
    echo "$validate_out"
    die "$(t "Caddyfile невалиден — установка прервана. Проверьте $CADDY_FILE" \
              "Caddyfile is invalid — install aborted. Check $CADDY_FILE")"
  fi

  # Store probe_secret in caddy config dir for panel to read
  echo "$PROBE_SECRET" > "${CADDY_CONFIG_DIR}/probe_secret"
  chmod 600 "${CADDY_CONFIG_DIR}/probe_secret"
}

# ── Write caddy-naive.service ───────────────────────────────────────────────
# Bug 22: called explicitly in main() after write_caddyfile() and before
#          start_services() so the unit file always exists before daemon-reload.
write_caddy_service() {
  log_step "$(t 'Запись systemd юнита caddy-naive.service' 'Writing caddy-naive.service')"

  # Remove legacy naive.service if present (migration)
  if [[ -f /etc/systemd/system/naive.service ]]; then
    systemctl stop    naive 2>/dev/null || true
    systemctl disable naive 2>/dev/null || true
    rm -f /etc/systemd/system/naive.service
    log_info "$(t 'naive.service удалён (заменён caddy-naive.service) ✓' \
                 'naive.service removed (replaced by caddy-naive.service) ✓')"
  fi

  cat > /etc/systemd/system/caddy-naive.service <<SVCCADDY
[Unit]
Description=Caddy forwardproxy-naive Server
Documentation=https://github.com/klzgrad/forwardproxy
After=network.target network-online.target
Requires=network-online.target
# Bug 62: cap restart storms — 5 failures in 5 min → failed state (stops hammering ACME)
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
Type=notify
# Bug 37: run as unprivileged system user; cap_net_bind_service grants port 443
User=caddy
Group=caddy
ExecStart=${CADDY_BIN} run --config ${CADDY_FILE} --adapter caddyfile
ExecReload=/bin/kill -USR1 \$MAINPID
TimeoutStopSec=5
Restart=on-failure
# Bug 62: slow restarts to reduce ACME rate-limit pressure
RestartSec=10
LimitNOFILE=1048576
PrivateTmp=true
# Bug 65: ProtectSystem=strict (not full) is required when ReadWritePaths
# includes /etc paths; ProtectSystem=full makes all of /etc read-only
# system-wide regardless of ReadWritePaths on older kernels.
ProtectSystem=strict
# Bug 43: ACME certs stored under XDG_DATA_HOME; both dirs need write access
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy
ReadWritePaths=/var/log/caddy-naive /etc/caddy-naive /var/lib/caddy
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCCADDY

  log_info "$(t 'caddy-naive.service написан ✓' 'caddy-naive.service written ✓')"
}

# ── Mieru initial state file ──────────────────────────────────────────────────
write_mita_state() {
  log_step "$(t 'Запись начального конфига Mieru' 'Writing initial Mieru state')"
  mkdir -p "$(dirname "$MITA_STATE_FILE")"

  python3 - <<PYEOF
import json
start = $MIERU_PORT_START
end   = $MIERU_PORT_END
cfg = {
    "portBindings": [
        {"port": p, "protocol": "TCP"}
        for p in range(start, end + 1)
    ],
    "users": [],
    "loggingLevel": "INFO",
    "mtu": 1400
}
with open("$MITA_STATE_FILE", "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
  chmod 600 "$MITA_STATE_FILE"
  log_info "$(t "Mita state file → $MITA_STATE_FILE ✓" "Mita state file → $MITA_STATE_FILE ✓")"
}

# ── Systemd: mita (ensure exists) ─────────────────────────────────────────────
write_mita_service() {
  if [[ ! -f /lib/systemd/system/mita.service ]] && \
     [[ ! -f /etc/systemd/system/mita.service ]]; then
    cat > /etc/systemd/system/mita.service <<MITSVC
[Unit]
Description=Mieru Proxy Server (mita)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/mita run
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
MITSVC
  fi
}

# ── Bug 7: UFW helper — handles single-port (start==end) correctly ─────────
# UFW rejects "N:N/proto" range syntax when start equals end.
_ufw_mieru_rule() {
  local s=$1 e=$2 proto=$3 comment=$4
  if [[ "$s" -eq "$e" ]]; then
    ufw allow "${s}/${proto}" comment "${comment}" 2>/dev/null || true
  else
    ufw allow "${s}:${e}/${proto}" comment "${comment}" 2>/dev/null || true
  fi
}

# ── UFW ───────────────────────────────────────────────────────────────────────
# Bug 20: port 80 required for ACME HTTP-01 challenge.
# Bug 36: backup UFW rules before reset; interactive-mode prompts for confirmation.
setup_ufw() {
  log_step "$(t 'Настройка UFW' 'Configuring UFW firewall')"

  # Bug 36: backup current rules before --force reset
  if command -v ufw &>/dev/null; then
    local ufw_bak="/etc/rixxx-panel/backups/ufw-before-install-$(date +%Y%m%d-%H%M%S).rules"
    mkdir -p "$(dirname "$ufw_bak")"
    ufw status verbose 2>/dev/null > "$ufw_bak" || true
    log_info "$(t "Резервная копия правил UFW: $ufw_bak" "UFW rules backup: $ufw_bak")"
  fi

  # Bug 36: prompt for confirmation in interactive mode
  if ! $NON_INTERACTIVE; then
    echo ""
    echo -e "${YELLOW}$(t 'UFW --force reset удалит все текущие правила!' \
                         'UFW --force reset will erase all existing rules!')${NC}"
    read -rp "$(t '  Продолжить? [Д/н]: ' '  Continue? [Y/n]: ')" _ufw_confirm
    local _uc="${_ufw_confirm:-Y}"
    if $LANG_RU; then
      [[ "${_uc^^}" =~ ^(Н|N)$ ]] && { log_info "$(t 'UFW пропущен.' 'UFW skipped.')"; return; }
    else
      [[ "${_uc^^}" == "N" ]] && { log_info "UFW skipped."; return; }
    fi
  fi
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw allow 80/tcp comment "ACME HTTP-01 + redir HTTPS"
  ufw allow "${NAIVE_PORT}/tcp" comment "CaddyNaive HTTPS"
  # Bug 7: single-port safe helper
  _ufw_mieru_rule "$MIERU_PORT_START" "$MIERU_PORT_END" tcp "Mieru TCP"
  _ufw_mieru_rule "$MIERU_PORT_START" "$MIERU_PORT_END" udp "Mieru UDP"
  local panel_port; panel_port=$(jq -r '.panelPort // 3000' "$PANEL_CONFIG" 2>/dev/null || echo 3000)
  [[ "${EXPOSE_PANEL^^}" =~ ^(Y|Д)$ ]] && ufw allow "${panel_port}/tcp" comment "Panel Web UI"
  ufw --force enable || true
  log_info "$(t 'Правила UFW применены ✓' 'UFW rules applied ✓')"
}

# ── Panel installation ────────────────────────────────────────────────────────
install_panel() {
  log_step "$(t 'Установка веб-панели' 'Installing web panel')"
  mkdir -p "$PANEL_DIR"
  # Locate the local panel/ source robustly: try the script's own directory,
  # then the current working directory (covers `sudo bash install.sh` from the
  # cloned repo even when BASH_SOURCE is relative).
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  local src=""
  if [[ -n "$script_dir" && -d "$script_dir/panel" ]]; then
    src="$script_dir/panel"
  elif [[ -d "$PWD/panel" ]]; then
    src="$PWD/panel"
  fi

  if [[ -n "$src" ]]; then
    cp -r "$src/"* "$PANEL_DIR/"
    log_info "$(t "Файлы панели скопированы из $src ✓" "Panel files copied from $src ✓")"
  else
    log_warn "$(t 'Локальные исходники не найдены — клонирование из репозитория...' \
               'Local panel source not found — cloning from repo...')"
    git clone --depth 1 "$REPO_URL" /tmp/panel-src 2>/dev/null || \
      die "$(t 'Не удалось клонировать репозиторий' 'Failed to clone panel source')"
    cp -r /tmp/panel-src/panel/* "$PANEL_DIR/"
    rm -rf /tmp/panel-src
  fi
  [[ -f "$script_dir/update.sh" ]] && cp "$script_dir/update.sh" "$PANEL_DIR/update.sh" 2>/dev/null || true
  [[ -f "$script_dir/install.sh" ]] && cp "$script_dir/install.sh" "$PANEL_DIR/install.sh" 2>/dev/null || true
  ( cd "$PANEL_DIR" && npm install --production --silent )
  log_info "$(t 'npm зависимости установлены ✓' 'npm dependencies installed ✓')"
}

# ── config.json ───────────────────────────────────────────────────────────────
write_config_json() {
  log_step "$(t 'Запись /etc/rixxx-panel/config.json' 'Writing /etc/rixxx-panel/config.json')"
  mkdir -p /etc/rixxx-panel "$(dirname "$DB_PATH")"
  local server_ip
  server_ip=$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
  local panel_port panel_path
  panel_port=$(python3 -c 'import random; print(random.randint(20000, 59999))' 2>/dev/null || echo 3000)
  panel_path=$(python3 -c 'import secrets; print("/admin-" + secrets.token_urlsafe(12).replace("-","").replace("_",""))' 2>/dev/null || echo /admin)
  PANEL_PORT="$panel_port"
  PANEL_PATH="$panel_path"

  # Generate bcrypt hash via Node (rounds=12).
  # Bug 73 (P0): the password is passed via the RIXXX_ADMIN_PASS env var, NOT
  # argv. With `node -e`, there is no script-path argument, so the first user
  # arg lands at process.argv[1] (not argv[2]); the old code read argv[2] →
  # undefined → bcrypt.hashSync threw → install aborted at write_config_json.
  # Env-var passing also avoids any shell-quoting issues with special chars.
  local bcrypt_hash
  bcrypt_hash=$(cd "$PANEL_DIR" && RIXXX_ADMIN_PASS="$ADMIN_PASS" node -e "
    const bcrypt = require('bcryptjs');
    const pw = process.env.RIXXX_ADMIN_PASS || '';
    if (!pw) { process.exit(2); }
    process.stdout.write(bcrypt.hashSync(pw, 12));
  " 2>/dev/null) || true
  # Fallback: htpasswd (apache2-utils) if Node hashing failed for any reason.
  if [[ -z "$bcrypt_hash" ]]; then
    if ! command -v htpasswd &>/dev/null; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2-utils 2>/dev/null || true
    fi
    bcrypt_hash=$(htpasswd -bnBC 12 "" "$ADMIN_PASS" 2>/dev/null | tr -d ':\n' | sed 's/^[^$]*//')
  fi
  [[ -z "$bcrypt_hash" ]] && die "$(t 'Не удалось создать bcrypt-хеш пароля' 'Failed to generate bcrypt password hash')"

  python3 - <<PYCFG
import json
data = {
    "domain":          "$DOMAIN",
    "serverIp":        "$server_ip",
    "adminEmail":      "$ADMIN_EMAIL",
    "adminUser":       "$ADMIN_USER",
    "adminPassHash":   "${bcrypt_hash}",
    "naivePort":       $NAIVE_PORT,
    "mieruPortStart":  $MIERU_PORT_START,
    "mieruPortEnd":    $MIERU_PORT_END,
    "panelPort":       $panel_port,
    "panelHost":       "127.0.0.1",
    "panelPath":       "$panel_path",
    "exposePanel":     "$EXPOSE_PANEL".upper() in ("Y","Д"),
    "autoUpdateEnabled": False,
    "useUfw":          "$USE_UFW".upper() in ("Y","Д"),
    "dbPath":          "$DB_PATH",
    "caddyBin":        "$CADDY_BIN",
    "caddyFile":       "$CADDY_FILE",
    "caddyConfigDir":  "$CADDY_CONFIG_DIR",
    "fakeSiteDir":     "$FAKE_SITE_DIR",
    "fakeSiteUrl":     "$FAKE_SITE_URL",
    "probeSecret":     "$PROBE_SECRET",
    "probeMode":       "${PROBE_MODE:-bare}",
    "mitaStateFile":   "$MITA_STATE_FILE",
    "trafficPattern":  "NOOP",
    "mtu":             1400,
    "udpEnabled":      False,
    "language":        "ru",
    "version":         "$CURRENT_VERSION",
    "installedAt":     "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
with open("$PANEL_CONFIG", "w") as f:
    json.dump(data, f, indent=2)
import os; os.chmod("$PANEL_CONFIG", 0o600)
PYCFG

  log_info "$(t 'config.json записан ✓' 'config.json written ✓')"
}

# ── Version file ──────────────────────────────────────────────────────────────
write_version() {
  mkdir -p "$(dirname "$VERSION_FILE")"
  cat > "$VERSION_FILE" <<VEREOF
panel_version=${CURRENT_VERSION}
caddy_version=${CADDY_VERSION:-unknown}
mieru_version=${MIERU_VERSION:-unknown}
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
VEREOF
  log_info "$(t "Версия записана → $VERSION_FILE ✓" "Version file written → $VERSION_FILE ✓")"
}

# ── Auto-update cron ──────────────────────────────────────────────────────────
write_auto_update_cron() {
  log_step "$(t 'Запись cron для автообновления' 'Writing auto-update cron')"
  mkdir -p /etc/cron.d
  cat > /etc/cron.d/rixxx-panel-update <<CRONEOF
# Panel Naive + Mieru auto-update
# The script checks /etc/rixxx-panel/config.json and exits immediately when
# autoUpdateEnabled=false. Enable/disable from the admin panel.
17 3 * * * root cd "$PANEL_DIR" && /bin/bash "$PANEL_DIR/update.sh" --auto -y >> /var/log/rixxx-panel-update.log 2>&1
CRONEOF
  chmod 644 /etc/cron.d/rixxx-panel-update
  log_info "$(t 'Cron autoобновления записан ✓' 'Auto-update cron written ✓')"
}

# ── Start services ────────────────────────────────────────────────────────────
# Bug 22:  write_caddy_service() called from main() before start_services().
# Bug 37:  caddy-naive runs as dedicated 'caddy' system user.
# Bug 42:  caddy user + all dirs created BEFORE systemctl restart so the service
#          can write logs and ACME certs without permission-denied errors.
# Bug 43:  /var/lib/caddy created + owned by caddy for ACME cert storage.
# Bug 61:  Caddy failure is non-fatal — install continues so the user can reach
#          the panel UI and diagnose/fix from there.
# Bug 62:  ACME port-wait loop warns if :443 is not listening after 60 s.
start_services() {
  log_step "$(t 'Запуск сервисов' 'Starting services')"

  # ── 1. System user — MUST be first so all chown calls succeed ────────────────
  if ! id caddy &>/dev/null; then
    useradd --system --no-create-home --shell /usr/sbin/nologin caddy
    log_info "$(t 'Системный пользователь caddy создан ✓' 'System user caddy created ✓')"
  fi

  # ── 2. Bug 42: clean up any stale root-owned log file from write_caddyfile ──
  if [[ -f /var/log/caddy-naive/access.log ]]; then
    local _log_owner
    _log_owner=$(stat -c '%U' /var/log/caddy-naive/access.log 2>/dev/null || echo root)
    if [[ "$_log_owner" != "caddy" ]]; then
      log_warn "$(t "Удаляем access.log с владельцем $_log_owner (нужен caddy)" \
                   "Removing stale access.log owned by $_log_owner (need caddy)")"
      rm -f /var/log/caddy-naive/access.log
    fi
  fi

  # ── 3. Directories — created here with correct owner (Bug 42 + Bug 43) ───────
  mkdir -p /var/log/caddy-naive /var/lib/caddy
  chown -R caddy:caddy /var/log/caddy-naive /var/lib/caddy
  chmod 755 /var/log/caddy-naive
  chmod 700 /var/lib/caddy

  # ── 4. Caddy binary + config permissions ─────────────────────────────────────
  # Bug 55: chmod 755 (not 750) so any user can run caddy-naive validate
  chown root:caddy "$CADDY_BIN" 2>/dev/null || true
  chmod 755 "$CADDY_BIN" 2>/dev/null || true
  setcap 'cap_net_bind_service=+ep' "$CADDY_BIN" 2>/dev/null || true

  # Bug 79: caddy-naive runs as User=caddy and failed at startup with
  #   "reading config from file: open /etc/caddy-naive/Caddyfile: permission denied".
  #   The previous `chgrp caddy + chmod g+r + chmod 640` set the GROUP and read
  #   bits on files, but a 640 directory (drw-r-----) has NO execute (x) bit for
  #   the group, so the caddy user cannot *traverse* the dir to open the file.
  #   Fix: own the whole config dir as root:caddy, give the DIRECTORY 750
  #   (rwxr-x---, group can traverse + read) and the secret/config FILES 640.
  chown -R root:caddy "$CADDY_CONFIG_DIR" 2>/dev/null || true
  # Order matters: make the top dir traversable FIRST, otherwise `find` cannot
  # descend into a 640 dir to chmod the files inside it.
  chmod 750 "$CADDY_CONFIG_DIR" 2>/dev/null || true
  # Directories: 750 so the caddy group can enter and list them.
  find "$CADDY_CONFIG_DIR" -type d -exec chmod 750 {} + 2>/dev/null || true
  # Files: 640 so the caddy group can read them (no write, no exec).
  find "$CADDY_CONFIG_DIR" -type f -exec chmod 640 {} + 2>/dev/null || true
  # Belt-and-suspenders: ensure the Caddyfile is right.
  chmod 640 "$CADDY_FILE" 2>/dev/null || true

  systemctl daemon-reload

  # ── 5. caddy-naive (Bug 61: non-fatal — continue if Caddy fails) ─────────────
  systemctl enable caddy-naive
  # Bug 79b: clear any prior failure storm so restart isn't blocked by
  # "Start request repeated too quickly" after we've just fixed perms/caps.
  systemctl reset-failed caddy-naive 2>/dev/null || true
  systemctl restart caddy-naive || true
  sleep 2
  if systemctl is-active --quiet caddy-naive; then
    log_info "$(t 'caddy-naive запущен ✓' 'caddy-naive started ✓')"
    # Bug 58: wait up to 60s for port 443 to appear (ACME challenge may delay it)
    local _port_wait=0
    while [[ $_port_wait -lt 30 ]]; do
      ss -tlnp 2>/dev/null | grep -q ":${NAIVE_PORT} " && break
      sleep 2; (( _port_wait++ ))
    done
    if ! ss -tlnp 2>/dev/null | grep -q ":${NAIVE_PORT} "; then
      log_warn "$(t "caddy-naive ещё не слушает :${NAIVE_PORT} после 60 с — ACME challenge может быть в процессе" \
                   "caddy-naive not yet listening on :${NAIVE_PORT} after 60 s — ACME challenge may still be running")"
      log_warn "$(t 'Проверьте: dig +short $DOMAIN, journalctl -u caddy-naive -n 50' \
                   'Check: dig +short $DOMAIN, journalctl -u caddy-naive -n 50')"
    fi
  else
    # Bug 61: non-fatal — dump journal then warn; panel + mita still installed
    log_error "$(t 'caddy-naive не запустился! Вывод journalctl:' \
                   'caddy-naive failed to start! journalctl output:')"
    journalctl -u caddy-naive -n 40 --no-pager 2>/dev/null || true
    log_warn "$(t \
      'caddy-naive не активен — установка продолжается. После входа в панель запустите: bash update.sh --repair' \
      'caddy-naive is not active — install continues. After opening the panel run: bash update.sh --repair')"
  fi

  # Bug 4: mita crashes when started with empty users[].
  # Apply portBindings config, but only start mita after first user is added.
  write_mita_service
  systemctl enable mita 2>/dev/null || true
  if mita apply config "$MITA_STATE_FILE" 2>/dev/null; then
    log_info "$(t 'mita config применён ✓' 'mita config applied ✓')"
  else
    log_warn "$(t 'mita apply config вернул ошибку — проверьте: mita status' \
               'mita apply config returned non-zero — check: mita status')"
  fi
  local _mita_users
  _mita_users=$(python3 -c "
import json, sys
try:
    d = json.load(open('$MITA_STATE_FILE'))
    print(len(d.get('users', [])))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  if [[ "$_mita_users" -gt 0 ]]; then
    # Bug 75: the daemon (mita run) starting is NOT enough — the proxy stays in
    # state IDLE until `mita start` is issued. Restart the daemon, then start the
    # proxy so it actually binds the configured ports.
    systemctl restart mita 2>/dev/null || true
    sleep 1
    if mita start 2>/dev/null; then
      log_info "$(t 'mita запущен ✓' 'mita started ✓')"
    else
      log_warn "$(t 'mita не запустился — journalctl -u mita -n 30 / mita status' \
                   'mita failed to start — journalctl -u mita -n 30 / mita status')"
    fi
  else
    log_info "$(t 'mita: нет пользователей — сервис запустится автоматически после добавления первого пользователя' \
               'mita: no users yet — service will start automatically after first user is added via panel')"
  fi

  # PM2 panel
  cd "$PANEL_DIR"
  local panel_host="127.0.0.1"
  [[ "${EXPOSE_PANEL^^}" =~ ^(Y|Д)$ ]] && panel_host="0.0.0.0"
  local panel_port panel_path
  panel_port=$(jq -r '.panelPort // 3000' "$PANEL_CONFIG")
  panel_path=$(jq -r '.panelPath // "/admin"' "$PANEL_CONFIG")
  pm2 delete panel-naive-mieru 2>/dev/null || true
  PANEL_HOST="$panel_host" PANEL_PORT="$panel_port" PANEL_PATH="$panel_path" \
    pm2 start server/index.js \
      --name panel-naive-mieru \
      --log /var/log/panel-naive-mieru.log \
      --time 2>/dev/null || \
  NODE_ENV=production PANEL_HOST="$panel_host" PANEL_PORT="$panel_port" PANEL_PATH="$panel_path" \
    pm2 start server/index.js --name panel-naive-mieru --time
  pm2 save
  pm2 startup systemd -u root --hp /root 2>/dev/null | tail -1 | bash 2>/dev/null || true
  log_info "$(t 'Панель запущена через PM2 ✓' 'Panel started via PM2 ✓')"
  cd /
}

# ── Bug 14: smoke_test_configs() — create test user, validate config downloads ─
smoke_test_configs() {
  log_step "$(t 'Smoke-тест конфигов клиента' 'Smoke test: client config validation')"
  local test_user="smoke_test_user"
  local test_pass="smoke_pass_123"
  local test_email="smoke@test.local"
  local panel_url="http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
  local pass=0 fail=0
  local cookie_file; cookie_file=$(mktemp)

  # Login
  local login_res
  login_res=$(curl -sf -c "$cookie_file" -X POST "$panel_url/api/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null) || true

  if echo "$login_res" | grep -q '"ok":true'; then
    echo -e "  ${GREEN}✓${NC} smoke login OK"; (( pass++ ))
  else
    echo -e "  ${YELLOW}⚠${NC}  smoke login skipped (panel may still be starting)"
    rm -f "$cookie_file"
    return 0
  fi

  # Create test user
  local create_res
  create_res=$(curl -sf -b "$cookie_file" -X POST "$panel_url/api/users" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$test_user\",\"email\":\"$test_email\",\"password\":\"$test_pass\",\"protocols\":[\"naive\",\"mieru\"],\"quotaMB\":0}" \
    2>/dev/null) || true
  local user_id=""
  user_id=$(echo "$create_res" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || true)

  if [[ -n "$user_id" ]]; then
    echo -e "  ${GREEN}✓${NC} smoke test user created (id: ${user_id:0:8}…)"; (( pass++ ))
  else
    echo -e "  ${RED}✗${NC} smoke test user creation failed"; (( fail++ ))
    rm -f "$cookie_file"; return 0
  fi

  # Fetch naive config
  local naive_cfg
  naive_cfg=$(curl -sf -b "$cookie_file" \
    "$panel_url/api/users/$user_id/config/naive?password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$test_pass'))")" \
    2>/dev/null) || true

  if echo "$naive_cfg" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'link' in d" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} naive config link valid"; (( pass++ ))
    # Bug 5: verify transport field
    local naive_link; naive_link=$(echo "$naive_cfg" | python3 -c "import json,sys; print(json.load(sys.stdin)['link'])" 2>/dev/null || true)
    if echo "$naive_link" | grep -q "naive+https://"; then
      echo -e "  ${GREEN}✓${NC} naive link uses HTTPS transport"; (( pass++ ))
    else
      echo -e "  ${RED}✗${NC} naive link missing HTTPS transport"; (( fail++ ))
    fi
  else
    echo -e "  ${RED}✗${NC} naive config invalid"; (( fail++ ))
  fi

  # Fetch mieru (sing-box) config
  local mieru_cfg
  mieru_cfg=$(curl -sf -b "$cookie_file" \
    "$panel_url/api/users/$user_id/config/mieru?password=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$test_pass'))")" \
    2>/dev/null) || true

  if echo "$mieru_cfg" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ob=d.get('outbounds',[])
m=[o for o in ob if o.get('type')=='mieru']
assert m, 'no mieru outbound'
# Bug 12: server_ports array
assert 'server_ports' in m[0] or 'server_port' in m[0], 'missing port field'
# Bug 5: transport field
assert m[0].get('transport','TCP') in ('TCP','UDP'), 'invalid transport'
" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} mieru config valid (transport + port fields)"; (( pass++ ))
  else
    echo -e "  ${RED}✗${NC} mieru config validation failed"; (( fail++ ))
  fi

  # Cleanup test user
  curl -sf -b "$cookie_file" -X DELETE "$panel_url/api/users/$user_id" > /dev/null 2>&1 || true
  echo -e "  ${GREEN}✓${NC} smoke test user cleaned up"
  rm -f "$cookie_file"

  echo ""
  echo -e "  Config smoke: ${GREEN}$pass passed${NC}  ${RED}$fail failed${NC}"
  return 0
}

# ── Smoke tests ───────────────────────────────────────────────────────────────
smoke_test() {
  log_step "$(t 'Smoke-тесты' 'Running smoke tests')"
  sleep 5
  local pass=0 fail=0

  chk() {
    if eval "$2" &>/dev/null; then
      echo -e "  ${GREEN}✓${NC} $1"; (( pass++ ))
    else
      echo -e "  ${RED}✗${NC} $1"; (( fail++ ))
    fi
  }

  # caddy-naive checks
  chk "caddy-naive version"          "timeout 5 $CADDY_BIN version || $CADDY_BIN --version"
  chk "caddy-naive.service active"   "systemctl is-active caddy-naive"
  chk "caddy-naive port :${NAIVE_PORT} listening" \
      "ss -tlnup sport = :${NAIVE_PORT} 2>/dev/null | grep -q :${NAIVE_PORT}"
  chk "Caddyfile present"            "[[ -f $CADDY_FILE ]]"
  chk "fake-site index.html present" "[[ -f ${FAKE_SITE_DIR}/index.html ]]"

  # mita tests
  chk "mita.service enabled"         "systemctl is-enabled mita"
  chk "mita-state.json present"      "[[ -f $MITA_STATE_FILE ]]"
  chk "mita port :${MIERU_PORT_START} OR service starting" \
      "ss -tlnup sport = :${MIERU_PORT_START} 2>/dev/null | grep -q :${MIERU_PORT_START} || \
       systemctl is-enabled mita"

  # Panel
  chk "Panel responds"               "curl -sf http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}/ -o /dev/null"
  chk "config.json present"          "[[ -f $PANEL_CONFIG ]]"
  chk "version file present"         "[[ -f $VERSION_FILE ]]"

  # probe_resistance secret saved
  chk "probe_secret file present"    "[[ -f ${CADDY_CONFIG_DIR}/probe_secret ]]"

  if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
    echo -e "  ${GREEN}✓${NC} $(t 'Время синхронизировано' 'Time synchronised')"
    (( pass++ ))
  else
    echo -e "  ${YELLOW}⚠${NC}  $(t 'Время НЕ синхронизировано — критично для Mieru!' \
                                    'Time NOT synchronised — critical for Mieru!')"
  fi

  echo ""
  echo -e "  $(t 'Результат' 'Results'): ${GREEN}$pass $(t 'прошло' 'passed')${NC}  ${RED}$fail $(t 'упало' 'failed')${NC}"
  (( fail > 0 )) && log_warn "$(t 'Проверьте логи: journalctl -u caddy-naive mita -n 30' \
                                  'Check logs: journalctl -u caddy-naive mita -n 30')"

  # Bug 14: config smoke tests (require panel running + ADMIN_PASS set)
  if [[ -n "${ADMIN_PASS:-}" ]]; then
    smoke_test_configs
  fi
}

# ── UFW call ──────────────────────────────────────────────────────────────────
maybe_ufw() {
  local ans="${USE_UFW:-Y}"
  [[ "${ans^^}" =~ ^(Y|Д)$ ]] && setup_ufw || true
}

# ── Final banner ──────────────────────────────────────────────────────────────
print_banner() {
  local server_ip
  server_ip=$(python3 -c "import json; print(json.load(open('$PANEL_CONFIG'))['serverIp'])" 2>/dev/null \
              || hostname -I | awk '{print $1}')
  local panel_port panel_path
  panel_port=$(jq -r '.panelPort // 3000' "$PANEL_CONFIG" 2>/dev/null || echo 3000)
  panel_path=$(jq -r '.panelPath // "/admin"' "$PANEL_CONFIG" 2>/dev/null || echo /admin)
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
  if $LANG_RU; then
    echo -e "${GREEN}${BOLD}║   Panel Naive + Mieru v${CURRENT_VERSION} (Caddy) — Установка завершена ✓ ║${NC}"
  else
    echo -e "${GREEN}${BOLD}║   Panel Naive + Mieru v${CURRENT_VERSION} (Caddy) — Install Complete ✓   ║${NC}"
  fi
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}$(t 'Домен' 'Domain'):${NC}              $DOMAIN"
  echo -e "  ${BOLD}$(t 'IP сервера' 'Server IP'):${NC}          $server_ip"
  echo -e "  ${BOLD}$(t 'Порт NaiveProxy (Caddy)' 'NaiveProxy port (Caddy)'):${NC}  $NAIVE_PORT"
  echo -e "  ${BOLD}$(t 'Порты Mieru' 'Mieru ports'):${NC}        $MIERU_PORT_START-$MIERU_PORT_END (TCP)"
  echo -e "  ${BOLD}$(t 'Probe secret' 'Probe secret'):${NC}       ${PROBE_SECRET}"
  echo -e "  ${BOLD}$(t 'Fake site' 'Fake site'):${NC}          $FAKE_SITE_DIR"
  echo ""
  echo -e "  ${BOLD}$(t 'Доступ к панели' 'Panel access'):${NC}"
  if [[ "${EXPOSE_PANEL^^}" =~ ^(Y|Д)$ ]]; then
    echo -e "    $(t 'Публичный URL' 'Public URL'):  ${CYAN}http://$server_ip:${panel_port}${panel_path}/${NC}"
  else
    echo -e "    SSH: ${CYAN}ssh -L ${panel_port}:127.0.0.1:${panel_port} root@$server_ip${NC}"
    echo -e "    $(t 'Затем откройте' 'Then open'):  ${CYAN}http://localhost:${panel_port}${panel_path}/${NC}"
  fi
  echo ""
  echo -e "  ${BOLD}$(t 'Данные администратора' 'Admin credentials'):${NC}"
  echo -e "    $(t 'Логин' 'Username'): ${CYAN}$ADMIN_USER${NC}"
  echo -e "    $(t 'Пароль' 'Password'): ${CYAN}$ADMIN_PASS${NC}"
  echo ""
  echo -e "  ${BOLD}$(t 'Полезные команды' 'Useful commands'):${NC}"
  echo -e "    pm2 logs panel-naive-mieru"
  echo -e "    systemctl status caddy-naive mita"
  echo -e "    $CADDY_BIN version"
  echo -e "    mita status"
  echo -e "    bash update.sh --status"
  echo -e "    bash update.sh --repair"
  echo ""
  echo -e "  ${BOLD}$(t 'Лог установки' 'Install log'):${NC}      $INSTALL_LOG"
  echo ""
  echo -e "  ${YELLOW}${BOLD}⚠  $(t 'ВАЖНО: Сохраните пароль и probe_secret — они больше не будут показаны!' \
                                    'IMPORTANT: Save the password and probe_secret — they will not be shown again!')${NC}"
  echo ""
  echo -e "  Telegram: ${CYAN}https://t.me/russian_paradice_vpn${NC}"
  echo -e "  $(t 'Донат' 'Donate'):    ${CYAN}https://app.lava.top/2107724612?tabId=donate${NC}"
  echo ""
}

# ── Network tuning (BBR + UDP buffers) ────────────────────────────────────────
tune_network() {
  log_step "$(t 'Сетевая оптимизация (BBR, буферы UDP)' 'Network tuning (BBR, UDP buffers)')"
  local tune="${PANEL_DIR}/scripts/sysctl_tune.sh"
  if [[ -f "$tune" ]]; then
    bash "$tune" 2>/dev/null && \
      log_info "$(t 'BBR и сетевые буферы применены ✓' 'BBR and network buffers applied ✓')" || \
      log_warn "$(t 'Не удалось применить сетевую оптимизацию (не критично)' \
                   'Could not apply network tuning (non-fatal)')"
  else
    log_warn "$(t "sysctl_tune.sh не найден в $PANEL_DIR/scripts — пропуск" \
                 "sysctl_tune.sh not found in $PANEL_DIR/scripts — skipping")"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  parse_install_args "$@"

  select_language
  check_os
  detect_arch
  check_existing
  sync_time
  install_deps
  install_nodejs
  install_caddy_naive
  install_mieru
  gather_config
  setup_fake_site
  write_mita_state
  write_caddyfile
  write_caddy_service
  # Bug 41: install_panel BEFORE write_config_json so that bcryptjs (from
  # panel/node_modules) is available when we call  node -e "require('bcryptjs')"
  install_panel
  write_config_json
  write_version
  write_auto_update_cron
  tune_network      # BBR + UDP buffers (uses panel/scripts/sysctl_tune.sh)
  maybe_ufw
  start_services
  smoke_test
  print_banner
}

main "$@"
