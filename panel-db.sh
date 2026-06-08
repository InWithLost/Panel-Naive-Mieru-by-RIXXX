#!/usr/bin/env bash
set -euo pipefail

PANEL_CONFIG="${PANEL_CONFIG:-/etc/rixxx-panel/config.json}"
PANEL_DIR="${PANEL_DIR:-/opt/panel-naive-mieru}"
DEFAULT_DB="/var/lib/rixxx-panel/db.sqlite"

usage() {
  cat <<'EOF'
Usage:
  sudo bash panel-db.sh path
  sudo bash panel-db.sh users
  sudo bash panel-db.sh user <username>
  sudo bash panel-db.sh duplicates
  sudo bash panel-db.sh cleanup-empty-email

Reads dbPath from /etc/rixxx-panel/config.json and falls back to:
  /var/lib/rixxx-panel/db.sqlite
EOF
}

db_path() {
  if [[ -f "$PANEL_CONFIG" ]] && command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      const cfg = process.argv[1];
      const fallback = process.argv[2];
      try {
        const data = JSON.parse(fs.readFileSync(cfg, "utf8"));
        console.log(data.dbPath || fallback);
      } catch {
        console.log(fallback);
      }
    ' "$PANEL_CONFIG" "$DEFAULT_DB"
  else
    printf '%s\n' "$DEFAULT_DB"
  fi
}

run_sql() {
  local db="$1"
  local sql="$2"

  if [[ ! -f "$db" ]]; then
    echo "[ERROR] DB not found: $db" >&2
    exit 1
  fi

  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -header -column "$db" "$sql"
    return
  fi

  if [[ ! -d "$PANEL_DIR/node_modules/better-sqlite3" ]]; then
    echo "[ERROR] sqlite3 is not installed and better-sqlite3 was not found in $PANEL_DIR" >&2
    echo "Install sqlite3 or run this after panel installation." >&2
    exit 1
  fi

  ( cd "$PANEL_DIR" && DB_FILE="$db" SQL_QUERY="$sql" node <<'NODE'
const Database = require('better-sqlite3');
const db = new Database(process.env.DB_FILE, { readonly: !/^\s*(update|insert|delete|replace|create|drop|alter)\b/i.test(process.env.SQL_QUERY) });
const sql = process.env.SQL_QUERY;
if (/^\s*select\b/i.test(sql)) {
  const rows = db.prepare(sql).all();
  if (!rows.length) process.exit(0);
  const keys = Object.keys(rows[0]);
  console.log(keys.join('\t'));
  for (const row of rows) console.log(keys.map(k => row[k] ?? '').join('\t'));
} else {
  const info = db.prepare(sql).run();
  console.log(JSON.stringify(info));
}
NODE
  )
}

cmd="${1:-}"
db="$(db_path)"

case "$cmd" in
  path)
    printf '%s\n' "$db"
    ;;
  users)
    run_sql "$db" "SELECT id, username, COALESCE(email, '') AS email, createdAt FROM users ORDER BY createdAt DESC;"
    ;;
  user)
    username="${2:-}"
    [[ -n "$username" ]] || { usage; exit 2; }
    safe_username="${username//\'/\'\'}"
    run_sql "$db" "SELECT id, username, COALESCE(email, '') AS email, expiry, protocols, quotaMB, usedMB, createdAt, updatedAt FROM users WHERE username='$safe_username';"
    ;;
  duplicates)
    echo "Duplicate usernames:"
    run_sql "$db" "SELECT username, COUNT(*) AS count FROM users GROUP BY username HAVING COUNT(*) > 1;"
    echo "Duplicate emails:"
    run_sql "$db" "SELECT email, COUNT(*) AS count FROM users WHERE email IS NOT NULL AND email <> '' GROUP BY email HAVING COUNT(*) > 1;"
    ;;
  cleanup-empty-email)
    run_sql "$db" "UPDATE users SET email = NULL WHERE email = '';"
    ;;
  ""|-h|--help|help)
    usage
    ;;
  *)
    echo "[ERROR] Unknown command: $cmd" >&2
    usage
    exit 2
    ;;
esac
