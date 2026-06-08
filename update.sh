#!/usr/bin/env bash
# ==============================================================================
# Panel Naive + Mieru by RIXXX — update.sh  v1.2.6
# Usage: bash update.sh [--dry-run] [--force] [--check-update] [--auto]
#                       [--expose <domain>] [--ssh-only] [--status]
#                       [--repair] [--help] [-y]
#
# v1.2.4: Fixed Caddyfile template (bugs 23-40); uses caddyTemplate.js.
#   - --repair calls /api/services/rebuild-all to regenerate Caddyfile
#   - update_caddy_naive() replaces update_naiveproxy()
#   - rebuild_caddyfile_direct() now uses caddyTemplate.js (Bug 26)
# v1.2.6: Hotfixes 41-64 — /var/lib/caddy perms, atomic saveConfig(),
#   plaintext-password guard (Bug 44), reloadCaddy() simplified (Bug 50),
#   mieruPort safe defaults (Bug 51), naive-port active check (Bug 52),
#   caddy fmt (Bug 60), caddyTemplate indentation (Bug 63), README security
#   notice (Bug 45).
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()  { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
log_dry()   { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }
die()       { log_error "$*"; exit 1; }

# Bug 76: never fail silently. With `set -e`, any un-handled non-zero command
# aborted the script with no message (the user saw an empty prompt). This trap
# prints the failing line + command so problems are always visible.
on_error() {
  local exit_code=$?
  local line_no=${1:-?}
  log_error "update.sh aborted at line ${line_no} (exit ${exit_code})."
  log_error "Re-run with: sudo bash update.sh --force -y   (or check the message above)"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ── Constants ─────────────────────────────────────────────────────────────────
TARGET_VERSION="1.2.6"
PANEL_DIR="/opt/panel-naive-mieru"
PANEL_CONFIG="/etc/rixxx-panel/config.json"
VERSION_FILE="/etc/rixxx-panel/version"
BACKUP_DIR="/etc/rixxx-panel/backups"
DB_PATH="/var/lib/rixxx-panel/db.sqlite"
MITA_STATE_FILE="/var/lib/rixxx-panel/mita-state.json"
LOCK_FILE="/var/lock/rixxx-panel-update.lock"

# v1.2.3: Caddy-forwardproxy-naive paths (replaces standalone naive binary)
CADDY_BIN="/usr/local/bin/caddy-naive"
CADDY_CONFIG_DIR="/etc/caddy-naive"
CADDY_FILE="${CADDY_CONFIG_DIR}/Caddyfile"
FAKE_SITE_DIR="/var/www/fake-site"

# Legacy paths — kept only for migration cleanup
LEGACY_NAIVE_BIN="/usr/local/bin/naive"
LEGACY_NAIVE_CONFIG_DIR="/etc/naive"

CADDY_NAIVE_RELEASES="https://api.github.com/repos/klzgrad/forwardproxy/releases/latest"
CADDY_NAIVE_FALLBACK_URL="https://github.com/klzgrad/forwardproxy/releases/download/v2.10.0-naive/caddy-forwardproxy-naive.tar.xz"
MIERU_RELEASES="https://api.github.com/repos/enfein/mieru/releases/latest"
REPO_URL="https://github.com/InWithLost/Panel-Naive-Mieru-by-RIXXX"

# ── Flags ─────────────────────────────────────────────────────────────────────
DRY_RUN=false
FORCE=false
YES=false
MODE=""
EXPOSE_DOMAIN=""
CHECK_ONLY=false
AUTO_MODE=false

# ── Parse args ────────────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   DRY_RUN=true ;;
      --force)     FORCE=true ;;
      -y|--yes)    YES=true ;;
      --check-update) MODE="check-update" ;;
      --auto)      MODE="auto" ;;
      --expose)    MODE="expose"; EXPOSE_DOMAIN="${2:-}"; shift ;;
      --ssh-only)  MODE="ssh-only" ;;
      --status)    MODE="status" ;;
      --repair)    MODE="repair" ;;
      --help|-h)   print_help; exit 0 ;;
      *) die "Unknown argument: $1  (use --help)" ;;
    esac
    shift
  done
  # Bug 85: under `set -e`, this `[[ ]] && ...` was the LAST statement in
  # parse_args. When a MODE flag was given (e.g. --repair), the test
  # `[[ -z "repair" ]]` is FALSE, so parse_args RETURNED 1 → the caller in
  # main() (`parse_args "$@"`) is a plain command that exits non-zero →
  # `set -e` aborted the whole script with NO output, and the ERR trap on a
  # function return is skipped (exactly the Bug 77 failure mode). This is why
  # `--repair` exited 1 silently while `--force -y` (MODE empty → test TRUE →
  # return 0) worked. Use an explicit `if` + trailing `return 0`.
  if [[ -z "$MODE" ]]; then MODE="update"; fi
  return 0
}

print_help() {
  cat <<EOF
${BOLD}Panel Naive + Mieru — update.sh  v${TARGET_VERSION}${NC}

USAGE:
  bash update.sh [options]

OPTIONS:
  (no flag)              Update all components to latest versions
  --dry-run              Show what would be done without making changes
  --force                Force update even if already on latest version
  -y / --yes             Non-interactive (auto-confirm all prompts)
  --check-update         Check whether the bundled target version is newer
  --auto                 Run careful update only when auto-update is enabled
  --expose <domain>      Switch panel to public mode on its configured port/path
  --ssh-only             Switch panel back to SSH-tunnel-only (127.0.0.1)
  --status               Print full health report
  --repair               Rebuild Caddyfile + mita config from SQLite DB; restart services
  --help                 Show this help

EXAMPLES:
  bash update.sh                   # Interactive update
  bash update.sh --dry-run         # Preview changes
  bash update.sh --force -y        # Force update, non-interactive
  bash update.sh --status          # Health check
  bash update.sh --repair          # Fix broken installation
  bash update.sh --expose vpn.example.com
  bash update.sh --ssh-only        # Revert to SSH-only
EOF
}

# ── Prerequisite checks ───────────────────────────────────────────────────────
# Bug 77: under `set -e`, a function whose LAST statement is `[[ cond ]] && die`
# returns the exit status of the `[[ ]]` test. On the happy path the test is
# FALSE → the function returns 1 → the *caller* (e.g. `check_root` in main) is a
# plain command that exits non-zero → `set -e` aborts the whole script with NO
# output and the ERR trap on a function return is skipped. This is exactly why
# `sudo bash update.sh --force -y` printed nothing and returned to the prompt
# (traced: it died right after `check_root` → `[[ 0 -ne 0 ]]`). Use explicit
# `if` blocks with a trailing `return 0`.
check_root() {
  if [[ $EUID -ne 0 ]]; then die "Run as root"; fi
  return 0
}
check_install() {
  if [[ ! -f "$PANEL_CONFIG" ]]; then
    die "Panel not installed. Run install.sh first."
  fi
  return 0
}

load_config() {
  DOMAIN=$(jq -r '.domain'              "$PANEL_CONFIG")
  NAIVE_PORT=$(jq -r '.naivePort'       "$PANEL_CONFIG")
  MIERU_START=$(jq -r '.mieruPortStart' "$PANEL_CONFIG")
  MIERU_END=$(jq -r '.mieruPortEnd'     "$PANEL_CONFIG")
  PANEL_PORT=$(jq -r '.panelPort // 3000' "$PANEL_CONFIG")
  PANEL_PATH=$(jq -r '.panelPath // "/admin"' "$PANEL_CONFIG")
  EXPOSE=$(jq -r '.exposePanel'         "$PANEL_CONFIG")
  AUTO_UPDATE_ENABLED=$(jq -r '.autoUpdateEnabled // false' "$PANEL_CONFIG")
  ADMIN_EMAIL=$(jq -r '.adminEmail // ""' "$PANEL_CONFIG")
  # v1.2.3: read Caddy paths from config if present
  CADDY_BIN=$(jq -r '.caddyBin     // "/usr/local/bin/caddy-naive"' "$PANEL_CONFIG")
  CADDY_FILE=$(jq -r '.caddyFile   // "/etc/caddy-naive/Caddyfile"' "$PANEL_CONFIG")
  CADDY_CONFIG_DIR=$(jq -r '.caddyConfigDir // "/etc/caddy-naive"'  "$PANEL_CONFIG")
  FAKE_SITE_DIR=$(jq -r '.fakeSiteDir   // "/var/www/fake-site"'    "$PANEL_CONFIG")
}

panel_url() {
  echo "http://127.0.0.1:${PANEL_PORT}${PANEL_PATH}"
}

# ── Bug 81: config migration ──────────────────────────────────────────────────
# Existing installs (pre-Bug 81) have a probeSecret set but no probeMode field.
# The panel's back-compat would treat that as 'secret' mode (probe_resistance
# <secret>), which differs from the known-good reference server's BARE
# probe_resistance. On update we set probeMode='bare' when it is missing so the
# generated Caddyfile matches the reference. The stored probeSecret is kept so
# the user can switch back to 'secret' mode from the panel at any time.
migrate_config() {
  [[ -f "$PANEL_CONFIG" ]] || return 0
  command -v jq &>/dev/null || return 0
  local has_mode; has_mode=$(jq -r 'has("probeMode")' "$PANEL_CONFIG" 2>/dev/null)
  if [[ "$has_mode" != "true" ]]; then
    local tmp; tmp=$(mktemp)
    if jq '.probeMode = "bare"' "$PANEL_CONFIG" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
      cat "$tmp" > "$PANEL_CONFIG"
      log_info "Config migrated: probeMode='bare' (matches reference server) ✓"
    fi
    rm -f "$tmp"
  fi
}

# ── Backup ────────────────────────────────────────────────────────────────────
auto_backup() {
  local ts; ts=$(date +%Y-%m-%d-%H%M%S)
  local bdir="$BACKUP_DIR/$ts"

  $DRY_RUN && { log_dry "Would create backup at $bdir"; echo "$bdir"; return; }

  mkdir -p "$bdir"
  [[ -f "$CADDY_FILE"      ]] && cp "$CADDY_FILE"       "$bdir/Caddyfile"      || true
  [[ -f "$MITA_STATE_FILE" ]] && cp "$MITA_STATE_FILE"  "$bdir/mita-state.json" || true
  [[ -f "$PANEL_CONFIG"    ]] && cp "$PANEL_CONFIG"     "$bdir/config.json"    || true
  [[ -f /etc/systemd/system/caddy-naive.service ]] && \
    cp /etc/systemd/system/caddy-naive.service "$bdir/" || true
  [[ -f /etc/systemd/system/mita.service ]] && \
    cp /etc/systemd/system/mita.service "$bdir/" || true

  log_info "Backup created: $bdir"

  local count; count=$(ls -1d "$BACKUP_DIR"/*/ 2>/dev/null | wc -l)
  if (( count > 10 )); then
    ls -1dt "$BACKUP_DIR"/*/ | tail -n +11 | xargs rm -rf
    log_info "Old backups pruned (kept 10 most recent)"
  fi
  echo "$bdir"
}

# ── Architecture detection ────────────────────────────────────────────────────
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64"; DEB_ARCH="amd64" ;;
    # caddy-naive is amd64-only; Mieru still supports all arches
    aarch64|arm64) ARCH="arm64"; DEB_ARCH="arm64" ;;
    armv7l)        ARCH="armv7"; DEB_ARCH="armhf"  ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
}

# ── Version comparison ────────────────────────────────────────────────────────
version_gt() {
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" && "$1" != "$2" ]]
}

get_current_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    grep '^panel_version=' "$VERSION_FILE" 2>/dev/null | cut -d= -f2 || cat "$VERSION_FILE"
  else
    echo "0.0.0"
  fi
}

get_caddy_version_file() {
  if [[ -f "$VERSION_FILE" ]]; then
    grep '^caddy_version=' "$VERSION_FILE" 2>/dev/null | cut -d= -f2 || echo "unknown"
  else
    echo "unknown"
  fi
}

check_update_available() {
  local current; current=$(get_current_version)
  if version_gt "$TARGET_VERSION" "$current"; then
    echo "update"
  else
    echo "current"
  fi
}

# ── v1.2.3: Rebuild Caddyfile via panel API (rebuild-all endpoint) ────────────
# Used by --repair. Avoids duplicating build logic from index.js.
rebuild_via_api() {
  log_step "Rebuilding Caddyfile + mita config via panel API (/api/services/rebuild-all)"
  local panel_url; panel_url=$(panel_url)

  # We need a session cookie; read admin credentials from config
  local admin_user; admin_user=$(jq -r '.adminUser // "admin"' "$PANEL_CONFIG")

  # Try to get admin password hash and call API with session auth
  # The panel must be running for this to work
  if ! curl -sf "$panel_url/" -o /dev/null 2>/dev/null; then
    log_warn "Panel not responding at $panel_url — rebuilding configs directly"
    rebuild_caddyfile_direct
    rebuild_mita_state_direct
    return
  fi

  log_info "Panel is running — calling /api/services/rebuild-all"
  # We can't use credentials here without the plaintext password, so fall back to direct rebuild
  # The panel itself will reload Caddy after next user interaction.
  # For repair we rebuild directly from DB to be safe.
  rebuild_caddyfile_direct
  rebuild_mita_state_direct
}

# ── v1.2.4: Rebuild Caddyfile directly from SQLite DB ────────────────────────
# Bug 23/26/38/39: uses caddyTemplate.js (single source of truth) so directive
# syntax and log-rotation settings are always consistent with install.sh.
rebuild_caddyfile_direct() {
  log_step "Rebuilding Caddyfile from SQLite database"
  [[ ! -f "$DB_PATH" ]] && { log_warn "DB not found at $DB_PATH — skipping Caddyfile rebuild"; return; }
  [[ ! -f "$PANEL_CONFIG" ]] && { log_warn "Panel config not found — skipping Caddyfile rebuild"; return; }

  mkdir -p "$CADDY_CONFIG_DIR" /var/log/caddy-naive /var/lib/caddy
  # Bug 66: --repair must restore correct ownership on log and data dirs
  # (root is wrong — caddy-naive.service runs as User=caddy)
  id caddy &>/dev/null && chown caddy:caddy /var/log/caddy-naive /var/lib/caddy || true

  # Bug 86: build the Caddyfile via a TEMP .js FILE rather than an inline
  # `node -e "<huge double-quoted blob>"`.
  #
  # The previous inline form embedded the whole rebuild script inside a
  # double-quoted bash string, so bash pre-processed it: `$DB_PATH` /
  # `$PANEL_CONFIG` / `$CADDY_FILE` were string-substituted, and any stray `$`,
  # backtick or `\` in the JS was at the mercy of bash quoting. On the live
  # server this silently produced a node program that exited 0 *without* writing
  # the new Caddyfile (the `[Caddyfile] rebuilt with N user(s)` line never
  # appeared in --repair output), yet the subsequent `caddy validate` happily
  # validated the STALE file → false "Caddyfile rebuilt ✓". Running the exact
  # same logic from a real .js file (paths passed via process.env, no bash
  # interpolation) wrote the correct Bug 83 Caddyfile immediately.
  #
  # Fix: write the script with a QUOTED heredoc (<<'NODE_EOF' — no expansion),
  # pass every path through the environment, and `node "$rebuild_js"`. This
  # removes all bash-quoting hazards and makes a real failure exit non-zero
  # (caught below) instead of silently no-op'ing.
  # Bug 86b: node resolves `require('better-sqlite3')` relative to the SCRIPT
  # FILE's directory, not the cwd. A /tmp/*.js would look in /tmp/node_modules
  # and fail (reintroducing the Bug 82 "Cannot find module" problem). Write the
  # temp script INTO $PANEL_DIR so the panel's node_modules are on the lookup path.
  local rebuild_js; rebuild_js=$(mktemp "${PANEL_DIR}/.rebuild-caddy.XXXXXX.js")
  cat > "$rebuild_js" <<'NODE_EOF'
const Database = require('better-sqlite3');
const fs       = require('fs');

const DB_PATH      = process.env.RB_DB_PATH;
const PANEL_CONFIG = process.env.RB_PANEL_CONFIG;
const CADDY_FILE   = process.env.RB_CADDY_FILE;
const CADDY_CFGDIR = process.env.RB_CADDY_CFGDIR;
const TEMPLATE_JS  = process.env.RB_TEMPLATE_JS;
const FAKE_SITE    = process.env.RB_FAKE_SITE;

const db  = new Database(DB_PATH, { readonly: true });
const cfg = JSON.parse(fs.readFileSync(PANEL_CONFIG, 'utf8'));

// Bug 34: filter to naive-protocol users; placeholder emitted by template when empty
const naiveUsers = db.prepare('SELECT username, password, protocols FROM users').all()
  .filter(u => {
    try { return JSON.parse(u.protocols || '["naive","mieru"]').includes('naive'); }
    catch { return true; }
  })
  .map(u => ({ username: u.username, password: u.password || '' }))
  // Bug 67: skip users with no plaintext password — empty password produces
  // "basic_auth user " (trailing space) which Caddy rejects as invalid syntax
  .filter(u => u.password.trim() !== '');

const probeSecret = cfg.probeSecret ||
  (() => { try { return fs.readFileSync(CADDY_CFGDIR + '/probe_secret', 'utf8').trim(); } catch { return ''; } })();
// Bug 81: probe_resistance mode — derive from probeSecret when unset.
let probeMode = (cfg.probeMode || '').trim().toLowerCase();
if (!probeMode) probeMode = probeSecret ? 'secret' : 'bare';

// Bug 26: use shared template for consistency with install.sh
let content;
if (fs.existsSync(TEMPLATE_JS)) {
  const tpl = require(TEMPLATE_JS);
  content = tpl.render({
    adminEmail:  cfg.adminEmail  || '',
    domain:      cfg.domain      || 'localhost',
    naivePort:   cfg.naivePort   || 443,
    panelPort:   cfg.panelPort   || 3000,
    panelPath:   cfg.panelPath   || '/admin',
    exposePanel: cfg.exposePanel === true,
    fakeSiteDir: cfg.fakeSiteDir || FAKE_SITE,
    probeSecret,
    probeMode,
    logFile:     '/var/log/caddy-naive/access.log',
    upstream:    (cfg.cascadeEnabled && cfg.cascadeNaiveUpstream) ? cfg.cascadeNaiveUpstream : ''
  }, naiveUsers);
} else {
  // Fallback (template not available): emit correct Bug 83 syntax directly
  const crypto = require('crypto');
  let authLines;
  if (naiveUsers.length > 0) {
    authLines = naiveUsers.map(u => '    basic_auth ' + u.username + ' ' + u.password).join('\n');
  } else {
    const rnd = crypto.randomBytes(20).toString('hex');
    authLines = '    basic_auth _placeholder_' + rnd.slice(0, 16) + ' _disabled_' + rnd.slice(16);
  }
  const panelPath = String(cfg.panelPath || '/admin').trim() || '/admin';
  const exposePanel = cfg.exposePanel === true;
  const panelBlock = exposePanel
    ? '\n\n  handle_path ' + panelPath + '* {\n    reverse_proxy 127.0.0.1:' + (cfg.panelPort || 3000) + '\n  }'
    : '';
  let probeLine;
  if (probeMode === 'off') probeLine = '';
  else if (probeMode === 'secret' && probeSecret) probeLine = '\n    probe_resistance ' + probeSecret;
  else probeLine = '\n    probe_resistance';
  content = [
    '{',
    '  order handle_path before forward_proxy',
    '  order handle_path before file_server',
    '  order forward_proxy before file_server',
    '  servers {',
    '    protocols h1 h2',
    '  }',
    '  email ' + (cfg.adminEmail || ''),
    '  admin off',
    '  log {',
    '    output file /var/log/caddy-naive/access.log {',
    '      roll_size     50mb',
    '      roll_keep_for 720h',
    '    }',
    '    format json',
    '  }',
    '}',
    '',
    ':80 {',
    '  redir https://{host}{uri} permanent',
    '}',
    '',
    // Bug 83: host-based HTTPS site; Caddy automates TLS for the domain.
    (cfg.domain || 'localhost') + ' {',
    '  route {',
    panelBlock,
    '    forward_proxy {',
    authLines,
    '      hide_ip',
    '      hide_via' + probeLine,
    '    }',
    '',
    '    file_server {',
    '      root ' + (cfg.fakeSiteDir || FAKE_SITE),
    '    }',
    '  }',
    '}'
  ].join('\n');
}

const tmp = CADDY_FILE + '.new';
fs.writeFileSync(tmp, content, { mode: 0o640 });
fs.renameSync(tmp, CADDY_FILE);
console.log('[Caddyfile] rebuilt with ' + naiveUsers.length + ' user(s) → ' + CADDY_FILE);
db.close();
NODE_EOF

  # Bug 82: run node from the panel dir so it can resolve better-sqlite3 and the
  # other node_modules (they live under $PANEL_DIR, not the script's cwd).
  if ! ( cd "$PANEL_DIR" && \
         RB_DB_PATH="$DB_PATH" \
         RB_PANEL_CONFIG="$PANEL_CONFIG" \
         RB_CADDY_FILE="$CADDY_FILE" \
         RB_CADDY_CFGDIR="$CADDY_CONFIG_DIR" \
         RB_TEMPLATE_JS="${PANEL_DIR}/server/caddyTemplate.js" \
         RB_FAKE_SITE="$FAKE_SITE_DIR" \
         node "$rebuild_js" ); then
    rm -f "$rebuild_js"
    log_warn "Node Caddyfile rebuild failed — Caddyfile will be rebuilt on next panel operation"
    return 1
  fi
  rm -f "$rebuild_js"

  # Bug 39: validate after rebuild so --repair fails loudly if template is wrong
  local caddy_bin; caddy_bin=$(jq -r '.caddyBin // "/usr/local/bin/caddy-naive"' "$PANEL_CONFIG" 2>/dev/null || echo '/usr/local/bin/caddy-naive')
  if [[ -x "$caddy_bin" ]]; then
    if "$caddy_bin" validate --config "$CADDY_FILE" --adapter caddyfile &>/dev/null; then
      log_info "Caddyfile validated ✓"
    else
      log_error "Caddyfile validation FAILED after rebuild:"
      "$caddy_bin" validate --config "$CADDY_FILE" --adapter caddyfile 2>&1 | head -20 || true
      return 1
    fi
  fi
  # Bug 79: ensure the caddy user can actually read the freshly-written file
  fix_caddy_perms
  log_info "Caddyfile rebuilt ✓"
}

# ── v1.2.3: Rebuild mita-state.json from SQLite DB ───────────────────────────
rebuild_mita_state_direct() {
  log_step "Rebuilding mita-state.json from database"
  [[ ! -f "$DB_PATH" ]] && { log_warn "DB not found — skipping mita state rebuild"; return; }

  # Bug 82: run node from the panel dir so better-sqlite3 resolves correctly.
  ( cd "$PANEL_DIR" && node -e "
    const Database = require('better-sqlite3');
    const fs       = require('fs');
    const db       = new Database('$DB_PATH', { readonly: true });
    const cfg      = JSON.parse(fs.readFileSync('$PANEL_CONFIG', 'utf8'));
    const users    = db.prepare('SELECT username, password, protocols FROM users').all()
      .filter(u => { try { return JSON.parse(u.protocols || '[]').includes('mieru'); } catch { return true; } })
      .map(u => ({ name: u.username, password: u.password || '' }));

    const portBindings = [];
    // Bug 69: mieruPortStart/End may be strings or undefined in old configs;
    // parseInt with fallback prevents an infinite loop (NaN comparisons are false)
    const portStart = parseInt(cfg.mieruPortStart, 10) || 2000;
    const portEnd   = parseInt(cfg.mieruPortEnd,   10) || 2010;
    for (let p = portStart; p <= portEnd; p++) {
      portBindings.push({ port: p, protocol: 'TCP' });
      if (cfg.udpEnabled) portBindings.push({ port: p, protocol: 'UDP' });
    }

    const state = { portBindings, users, loggingLevel: 'INFO', mtu: cfg.mtu || 1400 };
    const pat = cfg.trafficPattern || 'NOOP';
    if (pat !== 'NOOP') {
      const patMap = {
        RANDOM_PADDING:            { seed: true, tcpFragment: false, nonce: false },
        RANDOM_PADDING_AGGRESSIVE: { seed: true, tcpFragment: true,  nonce: true  },
        CUSTOM:                    { seed: true, tcpFragment: true,  nonce: true  }
      };
      if (patMap[pat]) state.trafficPattern = patMap[pat];
    }

    const tmp = '$MITA_STATE_FILE' + '.new';
    fs.writeFileSync(tmp, JSON.stringify(state, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, '$MITA_STATE_FILE');
    console.log('[mita-state] wrote', users.length, 'user(s)');
    db.close();
  " ) 2>/dev/null || {
    log_warn "Node mita state rebuild failed"
    return 1
  }
  log_info "mita-state.json rebuilt ✓"
}

# ── v1.2.3: Ensure caddy-naive.service exists ────────────────────────────────
ensure_caddy_service() {
  if [[ ! -f /etc/systemd/system/caddy-naive.service ]]; then
    log_step "Creating caddy-naive.service"
    # Bug 37: run as unprivileged caddy user
    id caddy &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin caddy 2>/dev/null || true
    cat > /etc/systemd/system/caddy-naive.service <<SVCCADDY
[Unit]
Description=Caddy forwardproxy-naive Server
Documentation=https://github.com/klzgrad/forwardproxy
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${CADDY_BIN} run --config ${CADDY_FILE} --adapter caddyfile
ExecReload=/bin/kill -USR1 \$MAINPID
TimeoutStopSec=5
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576
PrivateTmp=true
# Bug 65: ProtectSystem=strict (not full) required with ReadWritePaths /etc paths
ProtectSystem=strict
Environment=XDG_DATA_HOME=/var/lib/caddy
Environment=XDG_CONFIG_HOME=/var/lib/caddy
ReadWritePaths=/var/log/caddy-naive /etc/caddy-naive /var/lib/caddy
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SVCCADDY
    systemctl daemon-reload
    systemctl enable caddy-naive 2>/dev/null || true
    log_info "caddy-naive.service created ✓"
  fi

  # Remove legacy naive.service if present (migration from v1.2.x)
  if [[ -f /etc/systemd/system/naive.service ]]; then
    systemctl stop    naive 2>/dev/null || true
    systemctl disable naive 2>/dev/null || true
    rm -f /etc/systemd/system/naive.service
    log_info "Legacy naive.service removed (replaced by caddy-naive.service)"
  fi
}

# ── Bug 79: fix caddy-naive config permissions ───────────────────────────────
#   caddy-naive runs as User=caddy and fails to start with
#     "reading config from file: open /etc/caddy-naive/Caddyfile: permission denied"
#   when the config dir lacks group-execute (traverse) for the caddy group.
#   The Caddyfile is written by root (mode 640, owner root:root); the caddy user
#   then cannot enter the dir / read the file. Own dir as root:caddy, set dirs
#   750 (group can traverse) and files 640 (group can read).
fix_caddy_perms() {
  id caddy &>/dev/null || return 0
  [[ -d "$CADDY_CONFIG_DIR" ]] || return 0
  chown -R root:caddy "$CADDY_CONFIG_DIR" 2>/dev/null || true
  # Order matters: make the top dir traversable FIRST, otherwise `find` cannot
  # descend into a 640 dir to chmod the files inside it.
  chmod 750 "$CADDY_CONFIG_DIR" 2>/dev/null || true
  find "$CADDY_CONFIG_DIR" -type d -exec chmod 750 {} + 2>/dev/null || true
  find "$CADDY_CONFIG_DIR" -type f -exec chmod 640 {} + 2>/dev/null || true
  [[ -f "$CADDY_FILE" ]] && chmod 640 "$CADDY_FILE" 2>/dev/null || true
  # caddy also needs its data/log dirs owned correctly
  mkdir -p /var/log/caddy-naive /var/lib/caddy 2>/dev/null || true
  chown -R caddy:caddy /var/log/caddy-naive /var/lib/caddy 2>/dev/null || true
  log_info "caddy-naive config permissions fixed (dir 750, files 640, owner root:caddy) ✓"
}

# ── v1.2.3: Update caddy-forwardproxy-naive (amd64 only) ─────────────────────
update_caddy_naive() {
  log_step "Checking caddy-forwardproxy-naive update"
  detect_arch

  if [[ "$ARCH" != "amd64" ]]; then
    log_warn "caddy-forwardproxy-naive is amd64-only (current arch: $ARCH) — skipping Caddy update"
    return
  fi

  local release_json=""
  release_json=$(curl -fsSL --connect-timeout 10 "$CADDY_NAIVE_RELEASES" 2>/dev/null) || true

  local remote_tag="unknown"
  local asset_url=""

  if [[ -n "$release_json" ]]; then
    remote_tag=$(echo "$release_json" | jq -r '.tag_name // "unknown"')

    asset_url=$(echo "$release_json" | jq -r \
      '.assets[] | select(.name | test("caddy.*forwardproxy.*naive.*\\.tar\\.xz$|caddy-forwardproxy-naive.*\\.tar\\.xz$"; "i")) | .browser_download_url' \
      | head -1)

    if [[ -z "$asset_url" ]]; then
      asset_url=$(echo "$release_json" | jq -r \
        '.assets[] | select(.name | endswith(".tar.xz")) | .browser_download_url' | head -1)
    fi
  fi

  if [[ -z "$asset_url" ]]; then
    log_warn "GitHub API unavailable — using fallback URL (v2.10.0)"
    asset_url="$CADDY_NAIVE_FALLBACK_URL"
    remote_tag="v2.10.0-naive"
  fi

  local current_ver; current_ver=$("$CADDY_BIN" version 2>/dev/null | head -1 || \
                                   "$CADDY_BIN" --version 2>/dev/null | head -1 || \
                                   get_caddy_version_file)
  log_info "Current: $current_ver  |  Latest: $remote_tag"

  if ! $FORCE && echo "$current_ver" | grep -qF "${remote_tag#v}"; then
    log_info "caddy-forwardproxy-naive already up-to-date ✓"
    return
  fi

  $DRY_RUN && { log_dry "Would update caddy-naive to $remote_tag from $asset_url"; return; }

  local tmp_dir; tmp_dir=$(mktemp -d)
  log_info "Downloading: $asset_url"
  wget -q --show-progress --connect-timeout 30 -O "$tmp_dir/caddy.tar.xz" "$asset_url" || \
    { log_warn "Download failed — skipping Caddy update"; rm -rf "$tmp_dir"; return; }

  cd "$tmp_dir"
  tar -xJf caddy.tar.xz 2>/dev/null || tar -xf caddy.tar.xz 2>/dev/null || \
    { log_warn "Extract failed — skipping"; rm -rf "$tmp_dir"; cd /; return; }

  local caddy_found
  caddy_found=$(find "$tmp_dir" -maxdepth 3 -type f \
    \( -name "caddy" -o -name "caddy-naive" -o -name "caddy-forwardproxy-naive" \) \
    ! -name "*.xz" ! -name "*.gz" ! -name "*.tar" | head -1)

  if [[ -n "$caddy_found" ]]; then
    systemctl stop caddy-naive 2>/dev/null || true
    install -m 755 "$caddy_found" "$CADDY_BIN"
    if command -v setcap &>/dev/null; then
      setcap 'cap_net_bind_service=+ep' "$CADDY_BIN" 2>/dev/null || true
    fi
    # Bug 79b: fix config perms BEFORE starting, and clear any prior failure
    # storm — otherwise a broken-perms install hits "Start request repeated too
    # quickly" and never recovers even after the perms are fixed later.
    fix_caddy_perms
    systemctl reset-failed caddy-naive 2>/dev/null || true
    systemctl start caddy-naive 2>/dev/null || true
    log_info "caddy-naive updated to $remote_tag ✓"
  else
    log_warn "caddy binary not found in archive — skipping"
  fi

  rm -rf "$tmp_dir"; cd /

  # Update version file
  local new_ver; new_ver=$("$CADDY_BIN" version 2>/dev/null | head -1 || echo "$remote_tag")
  if [[ -f "$VERSION_FILE" ]]; then
    sed -i "s|^caddy_version=.*|caddy_version=${new_ver}|" "$VERSION_FILE" 2>/dev/null || \
      echo "caddy_version=${new_ver}" >> "$VERSION_FILE"
  fi

  # Remove legacy naive binary if still present
  if [[ -f "$LEGACY_NAIVE_BIN" ]]; then
    rm -f "$LEGACY_NAIVE_BIN"
    log_info "Legacy naive binary removed ✓"
  fi
}

# ── Update Mieru ──────────────────────────────────────────────────────────────
update_mieru() {
  log_step "Checking Mieru update"
  detect_arch

  local release_json
  release_json=$(curl -fsSL "$MIERU_RELEASES") || { log_warn "Cannot reach GitHub API for Mieru"; return; }

  local remote_tag; remote_tag=$(echo "$release_json" | jq -r '.tag_name')
  local current_ver; current_ver=$(mita version 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "none")
  log_info "Current: $current_ver  |  Latest: $remote_tag"

  if ! $FORCE && [[ "$current_ver" == "$remote_tag" ]]; then
    log_info "Mieru already up-to-date ✓"
    return
  fi

  $DRY_RUN && { log_dry "Would update mita to $remote_tag"; return; }

  local asset_url
  asset_url=$(echo "$release_json" | jq -r \
    --arg arch "$DEB_ARCH" \
    '.assets[] | select(.name | test("mita.*" + $arch + "\\.deb")) | .browser_download_url' | head -1)
  [[ -z "$asset_url" ]] && { log_warn "No Mieru .deb for $DEB_ARCH"; return; }

  local deb; deb=$(mktemp /tmp/mieru-XXXXXX.deb)
  wget -q -O "$deb" "$asset_url"
  systemctl stop mita 2>/dev/null || true
  dpkg -i "$deb" 2>/dev/null || apt-get install -f -y
  rm -f "$deb"
  systemctl start mita 2>/dev/null || true
  log_info "Mieru updated to $remote_tag ✓"
}

# ── Update panel ──────────────────────────────────────────────────────────────
# Bug 76: this step previously could be skipped or die silently:
#   - under `set -e`, a failing `npm install` aborted the whole script with no
#     clear message and left a partial copy;
#   - the version bump happened even on a partial run, so the next `-y` run saw
#     "already up-to-date" and never re-copied the panel files.
# Now: clone (or fall back to the local checkout), copy ALL panel files, run
# npm install non-fatally, restart PM2, and verify a known sentinel landed.
update_panel() {
  log_step "Updating web panel"
  $DRY_RUN && { log_dry "Would pull latest panel from $REPO_URL"; return; }

  local tmp; tmp=$(mktemp -d)
  local src=""
  if git clone --depth 1 "${REPO_URL}.git" "$tmp" 2>/dev/null && [[ -d "$tmp/panel" ]]; then
    src="$tmp/panel"
    log_info "Fetched latest panel from $REPO_URL"
  elif [[ -d "$(pwd)/panel" ]]; then
    # Fallback: use the local checkout the operator already `git pull`-ed.
    src="$(pwd)/panel"
    log_warn "git clone failed — using local checkout at $src"
  else
    log_warn "No panel source available (clone failed, no local ./panel) — skipping"
    rm -rf "$tmp"; return
  fi

  pm2 stop panel-naive-mieru 2>/dev/null || true

  mkdir -p "$PANEL_DIR"
  # Copy everything including dotfiles; cp -a preserves structure.
  cp -a "$src/." "$PANEL_DIR/"
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  [[ -f "$script_dir/update.sh" ]] && cp "$script_dir/update.sh" "$PANEL_DIR/update.sh" 2>/dev/null || true
  [[ -f "$script_dir/install.sh" ]] && cp "$script_dir/install.sh" "$PANEL_DIR/install.sh" 2>/dev/null || true

  # npm install must NOT be fatal — keep going even on a transient failure.
  ( cd "$PANEL_DIR" && npm install --omit=dev --silent ) \
    || ( cd "$PANEL_DIR" && npm install --production --silent ) \
    || log_warn "npm install reported a problem — continuing (deps may already be present)"

  pm2 restart panel-naive-mieru --update-env 2>/dev/null \
    || pm2 start "$PANEL_DIR/server/index.js" --name panel-naive-mieru --time

  # Bug 76: verify the new code actually landed (sentinel added in v1.2.6 P3).
  if grep -q "downloadNote" "$PANEL_DIR/public/index.html" 2>/dev/null; then
    log_info "Panel updated ✓ (v1.2.6 markers present)"
  else
    log_warn "Panel files copied but v1.2.6 marker not found — check $PANEL_DIR"
  fi
  rm -rf "$tmp"
}

# ── Smoke tests ───────────────────────────────────────────────────────────────
smoke_test() {
  log_step "Running smoke tests"
  sleep 3

  local pass=0 fail=0

  check_svc() {
    if systemctl is-active --quiet "$1"; then
      echo -e "  ${GREEN}✓${NC} $1 active"; (( pass++ ))
    else
      echo -e "  ${RED}✗${NC} $1 INACTIVE"; (( fail++ ))
    fi
  }

  # v1.2.3: check caddy-naive (not legacy naive)
  check_svc caddy-naive
  check_svc mita

  # caddy-naive version check
  if timeout 5 "$CADDY_BIN" version &>/dev/null 2>&1 || \
     timeout 5 "$CADDY_BIN" --version &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} caddy-naive version OK"; (( pass++ ))
  else
    echo -e "  ${RED}✗${NC} caddy-naive version FAILED"; (( fail++ ))
  fi

  # Caddyfile present
  if [[ -f "$CADDY_FILE" ]]; then
    echo -e "  ${GREEN}✓${NC} Caddyfile present"; (( pass++ ))
  else
    echo -e "  ${RED}✗${NC} Caddyfile MISSING"; (( fail++ ))
  fi

  # Fake site present
  if [[ -f "${FAKE_SITE_DIR}/index.html" ]]; then
    echo -e "  ${GREEN}✓${NC} fake-site/index.html present"; (( pass++ ))
  else
    echo -e "  ${YELLOW}⚠${NC}  fake-site/index.html missing (non-critical)"; 
  fi

  # Panel HTTP
  local panel_url; panel_url=$(panel_url)
  if curl -sf "$panel_url/" -o /dev/null 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Panel HTTP OK (${panel_url})"; (( pass++ ))
  else
    echo -e "  ${YELLOW}⚠${NC}  Panel not responding (${panel_url})"
  fi

  # mita status
  if mita status 2>/dev/null | grep -qi "running\|active"; then
    echo -e "  ${GREEN}✓${NC} mita reports running"; (( pass++ ))
  else
    echo -e "  ${YELLOW}⚠${NC}  mita status unclear"
  fi

  echo ""
  echo -e "  Smoke: ${GREEN}$pass passed${NC}  ${RED}$fail failed${NC}"
  return $fail
}

# ── --status mode ─────────────────────────────────────────────────────────────
do_status() {
  echo -e "\n${BOLD}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}   Panel Naive + Mieru v${TARGET_VERSION} — Status Report${NC}"
  echo -e "${BOLD}══════════════════════════════════════════${NC}\n"

  # Versions
  echo -e "${BOLD}Versions:${NC}"
  echo "  Panel:          $(get_current_version) (target: $TARGET_VERSION)"
  echo "  caddy-naive:    $("$CADDY_BIN" version 2>/dev/null | head -1 || echo 'not installed')"
  echo "  mita:           $(mita version 2>/dev/null | head -1 || echo 'not installed')"
  echo "  Node.js:        $(node --version 2>/dev/null || echo 'not installed')"
  echo "  PM2:            $(pm2 --version 2>/dev/null || echo 'not installed')"
  echo ""

  # Version file
  if [[ -f "$VERSION_FILE" ]]; then
    echo -e "${BOLD}Version file ($VERSION_FILE):${NC}"
    sed 's/^/  /' "$VERSION_FILE"
    echo ""
  fi

  # Services
  echo -e "${BOLD}Services:${NC}"
  for svc in caddy-naive mita; do
    local status; status=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    if [[ "$status" == "active" ]]; then
      echo -e "  ${GREEN}●${NC} $svc — active"
    else
      echo -e "  ${RED}●${NC} $svc — $status"
    fi
  done
  # Legacy naive check
  if systemctl is-active naive &>/dev/null 2>&1; then
    echo -e "  ${YELLOW}●${NC} naive — active (LEGACY — should have been removed in v1.2.3 migration)"
  fi
  local pm2_status; pm2_status=$(pm2 status panel-naive-mieru --no-color 2>/dev/null \
    | grep panel-naive-mieru | awk '{print $10}' || echo "unknown")
  echo "  ● PM2 panel     — $pm2_status"
  echo ""

  # Configuration
  echo -e "${BOLD}Configuration:${NC}"
  if [[ -f "$PANEL_CONFIG" ]]; then
    jq '{ domain, serverIp, naivePort, mieruPortStart, mieruPortEnd,
          panelHost, panelPort, panelPath, exposePanel, autoUpdateEnabled,
          trafficPattern, mtu, udpEnabled, fakeSiteUrl, probeSecret }' \
      "$PANEL_CONFIG" 2>/dev/null | sed 's/^/  /'
  else
    echo "  config.json NOT FOUND"
  fi
  echo ""

  # Caddyfile
  echo -e "${BOLD}Caddyfile (${CADDY_FILE}):${NC}"
  if [[ -f "$CADDY_FILE" ]]; then
    # Bug 23: directive is now "basic_auth" (underscore), not "basicauth"
    local user_count; user_count=$(grep -cE '^\s*basic_auth\s+\S+\s+\S+' "$CADDY_FILE" 2>/dev/null || echo 0)
    echo "  Present — $user_count basic_auth user(s)"
    grep -E 'probe_resistance|tls\s' "$CADDY_FILE" 2>/dev/null | head -5 | sed 's/^/  /' || true
  else
    echo "  Caddyfile NOT FOUND"
  fi
  echo ""

  # Fake site
  echo -e "${BOLD}Fake site ($FAKE_SITE_DIR):${NC}"
  if [[ -f "${FAKE_SITE_DIR}/index.html" ]]; then
    echo "  index.html present ✓"
  else
    echo "  MISSING"
  fi
  echo ""

  # Ports
  echo -e "${BOLD}Listening ports:${NC}"
  ss -tlnup 2>/dev/null | grep -E ":(443|80|8080|3000|20[0-9]{2})" | \
    awk '{print "  "$5}' || true
  echo ""

  # Backups
  echo -e "${BOLD}Recent backups:${NC}"
  if [[ -d "$BACKUP_DIR" ]]; then
    ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | head -5 | while read -r d; do
      echo "  $(basename "$d")"
    done || echo "  (none)"
  else
    echo "  (none)"
  fi
  echo ""

  # Time sync
  echo -e "${BOLD}Time:${NC}"
  timedatectl status 2>/dev/null | grep -E "Local time|synchronized" | sed 's/^/  /' || true
  echo ""
}

do_check_update() {
  local current; current=$(get_current_version)
  if version_gt "$TARGET_VERSION" "$current"; then
    log_info "Update available: $current -> $TARGET_VERSION"
  else
    log_info "Already up to date: $current"
  fi
}

do_auto() {
  if [[ "$AUTO_UPDATE_ENABLED" != "true" ]]; then
    log_info "Auto-update is disabled in config; nothing to do."
    return 0
  fi
  local current; current=$(get_current_version)
  if ! version_gt "$TARGET_VERSION" "$current"; then
    log_info "Auto-update check: already at $current."
    return 0
  fi
  YES=true
  do_update
}

# ── --expose mode ─────────────────────────────────────────────────────────────
do_expose() {
  log_step "Switching panel to public mode (expose)"
  [[ -z "$EXPOSE_DOMAIN" ]] && die "--expose requires a domain argument"

  $DRY_RUN && { log_dry "Would expose panel for domain $EXPOSE_DOMAIN"; return; }

  auto_backup >/dev/null

  jq --argjson v true --arg domain "$EXPOSE_DOMAIN" '.exposePanel = $v | .domain = $domain | .panelHost = "127.0.0.1"' "$PANEL_CONFIG" > /tmp/cfg.tmp && \
    mv /tmp/cfg.tmp "$PANEL_CONFIG"

  rebuild_caddyfile_direct || log_warn "Caddyfile rebuild failed during expose"
  systemctl restart caddy-naive 2>/dev/null || true
  PANEL_HOST="127.0.0.1" PANEL_PORT="$PANEL_PORT" PANEL_PATH="$PANEL_PATH" \
    pm2 restart panel-naive-mieru --update-env 2>/dev/null || \
    pm2 restart panel-naive-mieru 2>/dev/null || true
  log_info "Panel accessible at https://$EXPOSE_DOMAIN${PANEL_PATH}/ ✓"
}

# ── --ssh-only mode ───────────────────────────────────────────────────────────
do_ssh_only() {
  log_step "Switching panel to SSH-only mode"

  $DRY_RUN && { log_dry "Would switch panel to 127.0.0.1:${PANEL_PORT}${PANEL_PATH} (SSH-only)"; return; }

  auto_backup >/dev/null

  jq --argjson v false '.exposePanel = $v | .panelHost = "127.0.0.1"' "$PANEL_CONFIG" > /tmp/cfg.tmp && \
    mv /tmp/cfg.tmp "$PANEL_CONFIG"

  rebuild_caddyfile_direct || log_warn "Caddyfile rebuild failed during ssh-only switch"
  systemctl restart caddy-naive 2>/dev/null || true
  PANEL_HOST="127.0.0.1" PANEL_PORT="$PANEL_PORT" PANEL_PATH="$PANEL_PATH" \
    pm2 restart panel-naive-mieru --update-env 2>/dev/null || \
    pm2 restart panel-naive-mieru 2>/dev/null || true
  log_info "Panel now SSH-only (127.0.0.1:${PANEL_PORT}${PANEL_PATH}) ✓"

  local server_ip; server_ip=$(jq -r '.serverIp' "$PANEL_CONFIG")
  echo ""
  echo -e "  SSH tunnel:  ${CYAN}ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@$server_ip${NC}"
  echo -e "  Then open:   ${CYAN}http://localhost:${PANEL_PORT}${PANEL_PATH}/${NC}"
}

# ── --repair mode ─────────────────────────────────────────────────────────────
# Rebuild Caddyfile + mita config from SQLite DB; no data loss.
# v1.2.3: Calls /api/services/rebuild-all (falls back to direct DB rebuild).
do_repair() {
  log_step "Repair mode — rebuilding configs from SQLite database"

  if ! $YES; then
    read -rp "Rebuild Caddyfile and mita state from DB? [y/N]: " confirm
    [[ "${confirm^^}" != "Y" ]] && { log_info "Aborted."; exit 0; }
  fi

  $DRY_RUN && { log_dry "Would rebuild all configs from $DB_PATH"; return; }

  auto_backup >/dev/null

  # Bug 81: migrate config (set probeMode='bare' for pre-Bug 81 installs) so the
  # rebuilt Caddyfile matches the reference server's bare probe_resistance.
  migrate_config

  # Step 1: ensure fake site exists
  if [[ ! -f "${FAKE_SITE_DIR}/index.html" ]]; then
    log_info "Recreating fake site..."
    mkdir -p "$FAKE_SITE_DIR"
    cat > "${FAKE_SITE_DIR}/index.html" <<'FAKEHTML'
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Welcome</title></head>
<body><h1>Welcome</h1><p>This service is currently unavailable.</p></body>
</html>
FAKEHTML
    chmod 644 "${FAKE_SITE_DIR}/index.html"
    log_info "Fake site recreated ✓"
  fi

  # Step 2: ensure caddy-naive.service exists
  ensure_caddy_service

  # Step 3: rebuild Caddyfile + mita state from DB
  # Bug 84: ALWAYS rebuild directly from the on-disk caddyTemplate.js (the single
  # source of truth that --update freshly copied into $PANEL_DIR). Previously
  # --repair POSTed to /api/services/rebuild-all FIRST, which is rendered by the
  # *running* PM2 panel process. If that process had not reloaded the new
  # index.js yet (e.g. update_panel copied the files but the panel was still
  # serving old in-memory code), the API regenerated the STALE Caddyfile format
  # (route{} wrapper, domain-only listener) even though the on-disk template was
  # already the new Bug 83 layout — and the direct fallback never ran because the
  # API "succeeded". Going direct guarantees the rebuilt Caddyfile reflects the
  # template on disk, independent of whatever code the panel happens to be running.
  rebuild_caddyfile_direct
  rebuild_mita_state_direct

  # Step 4: apply mita config
  if [[ -f "$MITA_STATE_FILE" ]]; then
    mita apply config "$MITA_STATE_FILE" 2>/dev/null && \
      log_info "mita config applied ✓" || \
      log_warn "mita apply returned non-zero — check: mita status"
  fi

  # Step 5: reload/restart services
  systemctl daemon-reload
  # Bug 79: make sure the caddy user can read its config before (re)starting
  fix_caddy_perms
  # Bug 91: a graceful `reload` silently keeps the OLD in-memory config when the
  # new config can't be read (e.g. a permission error) — validate/status/logs all
  # look healthy while the cascade is NOT actually loaded. Always do a full
  # restart and verify is-active so a real failure surfaces.
  systemctl reset-failed caddy-naive 2>/dev/null || true
  systemctl restart caddy-naive 2>/dev/null || true
  if [[ "$(systemctl is-active caddy-naive 2>/dev/null)" == "active" ]]; then
    log_info "caddy-naive restarted ✓"
  else
    log_warn "caddy-naive restart failed — journalctl -u caddy-naive -n 20:"
    journalctl -u caddy-naive -n 20 --no-pager 2>/dev/null || true
  fi
  systemctl restart mita 2>/dev/null && log_info "mita restarted ✓" || \
    log_warn "mita restart failed — journalctl -u mita -n 20"
  pm2 restart panel-naive-mieru 2>/dev/null || true

  smoke_test || log_warn "Some smoke tests failed — check above"
  log_info "Repair complete ✓"
}

# ── Main update flow ──────────────────────────────────────────────────────────
do_update() {
  log_step "Updating Panel Naive + Mieru to v${TARGET_VERSION}"
  detect_arch

  local current; current=$(get_current_version)
  log_info "Installed version: $current  |  Target: $TARGET_VERSION"

  if ! $FORCE && ! version_gt "$TARGET_VERSION" "$current"; then
    log_info "Version file already reports $current (target $TARGET_VERSION)."
    if $YES; then
      # Bug 76: in non-interactive mode, re-sync the panel files anyway. The
      # version file may have been bumped by an earlier *partial* run that never
      # copied the new code, so "up-to-date" can be a lie. Re-copying is cheap
      # and idempotent.
      log_info "Non-interactive (-y): re-syncing panel files to be safe."
    else
      read -rp "Re-sync / force update anyway? [y/N]: " confirm
      [[ "${confirm^^}" != "Y" ]] && { log_info "Nothing to do."; exit 0; }
    fi
  fi

  if ! $YES && ! $DRY_RUN; then
    read -rp "Proceed with update? [Y/n]: " confirm
    [[ "${confirm^^}" == "N" ]] && { log_info "Aborted."; exit 0; }
  fi

  auto_backup >/dev/null

  # Bug 81: migrate config (set probeMode='bare' for pre-Bug 81 installs).
  migrate_config

  # Update components
  update_caddy_naive     # replaces update_naiveproxy() from v1.2.x
  update_mieru
  update_panel

  # Ensure service is present and legacy naive is gone
  ensure_caddy_service

  $DRY_RUN && { log_info "[DRY-RUN] No changes were made."; return; }

  # Bug 80/81: regenerate the Caddyfile from the (now-migrated) config + DB so the
  # new `servers { protocols h1 h2 }` block and probeMode take effect on update.
  # Older `do_update` only restarted caddy without re-rendering the config, so the
  # stale Caddyfile kept the old probe_resistance secret and lacked the protocols
  # block. rebuild_caddyfile_direct uses caddyTemplate.js (single source of truth).
  rebuild_caddyfile_direct || log_warn "Caddyfile rebuild returned non-zero — check above"

  # Bug 79: fix caddy-naive config permissions and (re)start it. Older installs
  # left the Caddyfile owned root:root (group caddy couldn't read it), so
  # caddy-naive failed with "Caddyfile: permission denied". Fix perms, clear any
  # failure storm (reset-failed), then restart so the fix actually takes hold.
  fix_caddy_perms
  systemctl reset-failed caddy-naive 2>/dev/null || true
  systemctl restart caddy-naive 2>/dev/null && log_info "caddy-naive restarted ✓" || \
    log_warn "caddy-naive restart failed — journalctl -u caddy-naive -n 20"

  # Update version file
  if [[ -f "$VERSION_FILE" ]]; then
    sed -i "s|^panel_version=.*|panel_version=${TARGET_VERSION}|" "$VERSION_FILE" 2>/dev/null || \
      echo "panel_version=${TARGET_VERSION}" >> "$VERSION_FILE"
  else
    echo "panel_version=${TARGET_VERSION}" > "$VERSION_FILE"
  fi
  log_info "Version file updated to $TARGET_VERSION ✓"

  # Remove legacy naive paths if present (migration cleanup)
  if [[ -f "$LEGACY_NAIVE_BIN" ]]; then
    rm -f "$LEGACY_NAIVE_BIN"
    log_info "Legacy naive binary removed ✓"
  fi
  if [[ -d "$LEGACY_NAIVE_CONFIG_DIR" ]]; then
    rm -rf "$LEGACY_NAIVE_CONFIG_DIR"
    log_info "Legacy /etc/naive directory removed ✓"
  fi

  smoke_test && log_info "Update completed successfully ✓" || \
    log_warn "Update completed with warnings — check services"
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  check_root

  if [[ "$MODE" == "update" || "$MODE" == "auto" ]]; then
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
      log_warn "Another update process is already running."
      exit 0
    fi
  fi

  case "$MODE" in
    check-update) check_install; load_config; do_check_update ;;
    status)   check_install; load_config; do_status ;;
    expose)   check_install; load_config; do_expose ;;
    ssh-only) check_install; load_config; do_ssh_only ;;
    repair)   check_install; load_config; do_repair ;;
    auto)     check_install; load_config; do_auto ;;
    update)   check_install; load_config; do_update ;;
  esac
}

main "$@"
