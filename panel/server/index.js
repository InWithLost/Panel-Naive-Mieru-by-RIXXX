/**
 * Panel Naive + Mieru by RIXXX — Express backend  v1.2.6
 * Node.js 20 LTS + Express + better-sqlite3 + WebSocket + node-cron
 *
 * v1.2.3: Migrated from standalone naive binary to caddy-forwardproxy-naive.
 *   buildCaddyfile(cfg, users) — rebuilds /etc/caddy-naive/Caddyfile atomically
 *   reloadCaddy()              — systemctl reload caddy-naive (graceful, zero downtime)
 *   applyAllConfigs()          — rebuilds Caddyfile + applies Mita config in one call
 *   /api/services/rebuild-all  — endpoint used by update.sh --repair
 *
 * v1.2.6 hardening:
 *   Bug 44: buildCaddyfile() skips users without plaintext password (logs warning)
 *   Bug 50: reloadCaddy() uses only systemctl reload — pgrep fallback removed
 *   Bug 51: buildMitaStateFile() uses safe defaults for mieruPortStart/End
 *   Bug 52: /api/settings/naive-port verifies caddy-naive is active after restart
 *   Bug 53: saveConfig() performs atomic write via .new tmp file then rename
 *
 * Bug 5:  Sing-Box outbound uses `transport` field (not `protocol`)
 * Bug 7:  UFW single-port vs range helper (ufwMieruRule)
 * Bug 12: server_ports array in Mieru Sing-Box config
 * Bug 13: version synced via scripts/sync-version.sh
 */
'use strict';

const express        = require('express');
const session        = require('express-session');
const helmet         = require('helmet');
const morgan         = require('morgan');
const rateLimit      = require('express-rate-limit');
const bcrypt         = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const cron           = require('node-cron');
const http           = require('http');
const { WebSocketServer } = require('ws');
const fs             = require('fs');
const path           = require('path');
const { execSync, execFileSync } = require('child_process');
const crypto         = require('crypto');
const si             = require('systeminformation');

// ── Paths ─────────────────────────────────────────────────────────────────────
const PANEL_CONFIG    = '/etc/rixxx-panel/config.json';
const DB_PATH         = '/var/lib/rixxx-panel/db.sqlite';
const MITA_STATE_FILE = '/var/lib/rixxx-panel/mita-state.json';

// v1.2.3: Caddy-forwardproxy-naive paths (replaces standalone naive binary)
const CADDY_BIN         = '/usr/local/bin/caddy-naive';
const CADDY_CONFIG_DIR  = '/etc/caddy-naive';
const CADDY_FILE        = '/etc/caddy-naive/Caddyfile';
const FAKE_SITE_DIR     = '/var/www/fake-site';
const LOG_CADDY         = '/var/log/caddy-naive/access.log';
const LOG_PANEL         = '/var/log/panel-naive-mieru.log';
const VERSION_FILE      = '/etc/rixxx-panel/version';
const UPDATE_SH         = fs.existsSync(path.join(__dirname, '..', '..', 'update.sh'))
  ? path.join(__dirname, '..', '..', 'update.sh')
  : path.join(__dirname, '..', 'update.sh');

// Legacy path kept for migration detection only
const LEGACY_NAIVE_BIN = '/usr/local/bin/naive';

// ── Load system config ────────────────────────────────────────────────────────
let cfg = {};
try {
  cfg = JSON.parse(fs.readFileSync(PANEL_CONFIG, 'utf8'));
} catch {
  cfg = {
    domain: 'localhost', serverIp: '127.0.0.1',
    adminUser: 'admin',
    adminPassHash: bcrypt.hashSync('admin', 12),
    naivePort: 443, mieruPortStart: 2012, mieruPortEnd: 2022,
    panelPort: 3000, panelHost: '127.0.0.1', panelPath: '/admin', exposePanel: false,
    dbPath:        DB_PATH,
    caddyBin:      CADDY_BIN,
    caddyFile:     CADDY_FILE,
    caddyConfigDir: CADDY_CONFIG_DIR,
    fakeSiteDir:   FAKE_SITE_DIR,
    fakeSiteUrl:   'https://www.example.com',
    probeSecret:   '',
    probeMode:     'bare',   // Bug 81: 'off' | 'bare' | 'secret' (matches known-good ref)
    mitaStateFile: MITA_STATE_FILE,
    trafficPattern: 'NOOP', mtu: 1400, udpEnabled: false,
    // Cascade (relay): Naive uses Caddyfile upstream; Mieru uses Variant B
    // (redsocks+iptables+mieru-client) orchestrated by scripts/cascade_mieru.sh.
    cascadeEnabled: false, cascadeNaiveUpstream: '',
    cascadeMieru: { host: '', portStart: 2012, portEnd: 2022, user: '', pass: '', mtu: 1400 },
    cascadeMieruEgress: {},   // legacy (Variant A native egress) — kept for back-compat
    language: 'ru', version: '1.2.6'
  };
}

// Resolved paths (prefer config values, fall back to constants)
function clampInt(value, min, max, fallback) {
  const n = parseInt(value, 10);
  if (Number.isNaN(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function normalizePanelPath(value) {
  let s = String(value || '').trim();
  if (!s || s === '/') return '/admin';
  if (!s.startsWith('/')) s = '/' + s;
  s = s.replace(/\/+$/g, '');
  s = s.replace(/[^a-zA-Z0-9/_-]/g, '');
  if (!s || s === '/') return '/admin';
  return s;
}

function normalizeConfig(input = {}) {
  const base = {
    domain: 'localhost',
    serverIp: '127.0.0.1',
    adminUser: 'admin',
    adminPassHash: bcrypt.hashSync('admin', 12),
    naivePort: 443,
    mieruPortStart: 2012,
    mieruPortEnd: 2022,
    panelPort: 3000,
    panelHost: '127.0.0.1',
    panelPath: '/admin',
    exposePanel: false,
    dbPath: DB_PATH,
    caddyBin: CADDY_BIN,
    caddyFile: CADDY_FILE,
    caddyConfigDir: CADDY_CONFIG_DIR,
    fakeSiteDir: FAKE_SITE_DIR,
    fakeSiteUrl: 'https://www.example.com',
    adminEmail: '',
    probeSecret: '',
    probeMode: 'bare',
    mitaStateFile: MITA_STATE_FILE,
    trafficPattern: 'NOOP',
    mtu: 1400,
    udpEnabled: false,
    cascadeEnabled: false,
    cascadeNaiveUpstream: '',
    cascadeMieru: { host: '', portStart: 2012, portEnd: 2022, user: '', pass: '', mtu: 1400 },
    cascadeMieruEgress: {},
    language: 'ru',
    version: '1.2.6'
  };
  const cfg2 = {
    ...base,
    ...input,
    cascadeMieru: {
      ...base.cascadeMieru,
      ...(input.cascadeMieru && typeof input.cascadeMieru === 'object' ? input.cascadeMieru : {})
    },
    cascadeMieruEgress: {
      ...base.cascadeMieruEgress,
      ...(input.cascadeMieruEgress && typeof input.cascadeMieruEgress === 'object' ? input.cascadeMieruEgress : {})
    }
  };
  cfg2.domain = String(cfg2.domain || base.domain).trim() || base.domain;
  cfg2.serverIp = String(cfg2.serverIp || base.serverIp).trim() || base.serverIp;
  cfg2.panelHost = String(cfg2.panelHost || base.panelHost).trim() || base.panelHost;
  cfg2.panelPath = normalizePanelPath(cfg2.panelPath || base.panelPath);
  cfg2.fakeSiteUrl = String(cfg2.fakeSiteUrl || base.fakeSiteUrl).trim() || base.fakeSiteUrl;
  cfg2.adminEmail = String(cfg2.adminEmail || '').trim();
  cfg2.adminUser = String(cfg2.adminUser || base.adminUser).trim() || base.adminUser;
  cfg2.naivePort = clampInt(cfg2.naivePort, 1, 65535, base.naivePort);
  cfg2.mieruPortStart = clampInt(cfg2.mieruPortStart, 1, 65535, base.mieruPortStart);
  cfg2.mieruPortEnd = clampInt(cfg2.mieruPortEnd, 1, 65535, base.mieruPortEnd);
  if (cfg2.mieruPortEnd < cfg2.mieruPortStart) cfg2.mieruPortEnd = cfg2.mieruPortStart;
  cfg2.panelPort = clampInt(cfg2.panelPort, 1, 65535, base.panelPort);
  cfg2.trafficPattern = ['NOOP', 'RANDOM_PADDING', 'RANDOM_PADDING_AGGRESSIVE', 'CUSTOM'].includes(cfg2.trafficPattern)
    ? cfg2.trafficPattern
    : base.trafficPattern;
  cfg2.mtu = clampInt(cfg2.mtu, 1280, 1400, base.mtu);
  cfg2.udpEnabled = cfg2.udpEnabled === true || cfg2.udpEnabled === 'true';
  cfg2.exposePanel = cfg2.exposePanel === true || cfg2.exposePanel === 'true';
  cfg2.cascadeEnabled = cfg2.cascadeEnabled === true || cfg2.cascadeEnabled === 'true';
  cfg2.cascadeNaiveUpstream = String(cfg2.cascadeNaiveUpstream || '').trim();
  cfg2.language = ['ru', 'en'].includes(cfg2.language) ? cfg2.language : base.language;
  cfg2.version = String(cfg2.version || base.version).trim() || base.version;
  cfg2.probeSecret = String(cfg2.probeSecret || '').trim();
  cfg2.probeMode = ['off', 'bare', 'secret'].includes(String(cfg2.probeMode || '').trim().toLowerCase())
    ? String(cfg2.probeMode).trim().toLowerCase()
    : (cfg2.probeSecret ? 'secret' : 'bare');
  cfg2.dbPath = String(cfg2.dbPath || DB_PATH).trim() || DB_PATH;
  cfg2.caddyBin = String(cfg2.caddyBin || CADDY_BIN).trim() || CADDY_BIN;
  cfg2.caddyFile = String(cfg2.caddyFile || CADDY_FILE).trim() || CADDY_FILE;
  cfg2.caddyConfigDir = String(cfg2.caddyConfigDir || CADDY_CONFIG_DIR).trim() || CADDY_CONFIG_DIR;
  cfg2.fakeSiteDir = String(cfg2.fakeSiteDir || FAKE_SITE_DIR).trim() || FAKE_SITE_DIR;
  cfg2.mitaStateFile = String(cfg2.mitaStateFile || MITA_STATE_FILE).trim() || MITA_STATE_FILE;
  cfg2.cascadeMieru.host = String(cfg2.cascadeMieru.host || '').trim();
  cfg2.cascadeMieru.portStart = clampInt(cfg2.cascadeMieru.portStart, 1, 65535, base.cascadeMieru.portStart);
  cfg2.cascadeMieru.portEnd = clampInt(cfg2.cascadeMieru.portEnd, 1, 65535, base.cascadeMieru.portEnd);
  if (cfg2.cascadeMieru.portEnd < cfg2.cascadeMieru.portStart) cfg2.cascadeMieru.portEnd = cfg2.cascadeMieru.portStart;
  cfg2.cascadeMieru.user = String(cfg2.cascadeMieru.user || '').trim();
  cfg2.cascadeMieru.pass = typeof cfg2.cascadeMieru.pass === 'string' ? cfg2.cascadeMieru.pass : '';
  cfg2.cascadeMieru.mtu = clampInt(cfg2.cascadeMieru.mtu, 1280, 1400, base.cascadeMieru.mtu);
  return cfg2;
}

cfg = normalizeConfig(cfg);
const PANEL_BASE_PATH = normalizePanelPath(cfg.panelPath);
cfg.panelPath = PANEL_BASE_PATH;

const resolvedDb        = cfg.dbPath        || DB_PATH;
const resolvedMitaFile  = cfg.mitaStateFile || MITA_STATE_FILE;
const resolvedCaddyFile = cfg.caddyFile     || CADDY_FILE;
const resolvedCaddyBin  = cfg.caddyBin      || CADDY_BIN;
const resolvedCaddyCfgDir = cfg.caddyConfigDir || CADDY_CONFIG_DIR;
const resolvedFakeSiteDir = cfg.fakeSiteDir  || FAKE_SITE_DIR;

// ── SQLite (better-sqlite3) ───────────────────────────────────────────────────
let db = null;
try {
  const Database = require('better-sqlite3');
  fs.mkdirSync(path.dirname(resolvedDb), { recursive: true });
  db = new Database(resolvedDb);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id        TEXT PRIMARY KEY,
      email     TEXT UNIQUE,
      username  TEXT NOT NULL UNIQUE,
      passHash  TEXT NOT NULL,
      password  TEXT NOT NULL DEFAULT '',
      expiry    TEXT,
      protocols TEXT DEFAULT '["naive","mieru"]',
      quotaMB   INTEGER DEFAULT 0,
      usedMB    REAL    DEFAULT 0,
      createdAt TEXT NOT NULL,
      updatedAt TEXT NOT NULL,
      lastSeen  TEXT
    );
    CREATE TABLE IF NOT EXISTS traffic_snapshots (
      id         INTEGER PRIMARY KEY AUTOINCREMENT,
      username   TEXT NOT NULL,
      uploadMB   REAL DEFAULT 0,
      downloadMB REAL DEFAULT 0,
      ts         TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS panel_settings (
      key   TEXT PRIMARY KEY,
      value TEXT
    );
    CREATE TABLE IF NOT EXISTS audit_log (
      id      INTEGER PRIMARY KEY AUTOINCREMENT,
      ts      TEXT NOT NULL,
      actor   TEXT NOT NULL,
      action  TEXT NOT NULL,
      details TEXT NOT NULL DEFAULT '{}'
    );
  `);
  // Migrate: add password column if missing (upgrade from v1.0.x)
  try { db.exec(`ALTER TABLE users ADD COLUMN password TEXT NOT NULL DEFAULT ''`); } catch {}

  // Migrate: make `email` nullable so it can be optional (TLS cert is set at
  // install time via Caddy ACME, not per-user). Old schema had `email TEXT
  // NOT NULL UNIQUE`, which rejects empty/absent emails and collides on ''.
  // Rebuild the table only if the column is still NOT NULL.
  try {
    const cols = db.prepare(`PRAGMA table_info(users)`).all();
    const emailCol = cols.find(c => c.name === 'email');
    if (emailCol && emailCol.notnull === 1) {
      db.exec(`
        BEGIN TRANSACTION;
        ALTER TABLE users RENAME TO users_legacy;
        CREATE TABLE users (
          id        TEXT PRIMARY KEY,
          email     TEXT UNIQUE,
          username  TEXT NOT NULL UNIQUE,
          passHash  TEXT NOT NULL,
          password  TEXT NOT NULL DEFAULT '',
          expiry    TEXT,
          protocols TEXT DEFAULT '["naive","mieru"]',
          quotaMB   INTEGER DEFAULT 0,
          usedMB    REAL    DEFAULT 0,
          createdAt TEXT NOT NULL,
          updatedAt TEXT NOT NULL,
          lastSeen  TEXT
        );
        INSERT INTO users
          (id,email,username,passHash,password,expiry,protocols,quotaMB,usedMB,createdAt,updatedAt,lastSeen)
        SELECT
          id,
          CASE WHEN email='' THEN NULL ELSE email END,
          username,passHash,password,expiry,protocols,quotaMB,usedMB,createdAt,updatedAt,lastSeen
        FROM users_legacy;
        DROP TABLE users_legacy;
        COMMIT;
      `);
      console.log('[DB] migrated users.email -> nullable (email is now optional)');
    }
  } catch (e) {
    try { db.exec('ROLLBACK'); } catch {}
    console.error('[DB] email-nullable migration skipped:', e.message);
  }
  try {
    db.prepare(`UPDATE users SET email = NULL WHERE email = ''`).run();
  } catch (e) {
    console.error('[DB] empty-email cleanup skipped:', e.message);
  }
} catch (err) {
  console.error('[DB] SQLite unavailable:', err.message, '— using in-memory store');
}

// In-memory fallback
const memUsers = new Map();

function audit(action, details = {}, actor = 'system') {
  if (!db) return;
  try {
    db.prepare('INSERT INTO audit_log (ts, actor, action, details) VALUES (?, ?, ?, ?)')
      .run(new Date().toISOString(), actor, action, JSON.stringify(details));
  } catch {}
}

// ── User DB helpers ───────────────────────────────────────────────────────────
function getAllUsers() {
  if (db) return db.prepare('SELECT * FROM users ORDER BY createdAt DESC').all();
  return [...memUsers.values()];
}
function getUserByUsername(username) {
  if (db) return db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  return [...memUsers.values()].find(u => u.username === username);
}
function normalizeUserEmail(email) {
  if (email === undefined || email === null) return null;
  const value = String(email).trim();
  return value ? value : null;
}
function getUserByEmail(email) {
  const normalized = normalizeUserEmail(email);
  if (!normalized) return null;
  if (db) return db.prepare('SELECT * FROM users WHERE email = ?').get(normalized);
  return [...memUsers.values()].find(u => normalizeUserEmail(u.email) === normalized);
}
function getUserById(id) {
  if (db) return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
  return memUsers.get(id);
}
function isUniqueConstraintError(err, column) {
  return err && err.code === 'SQLITE_CONSTRAINT_UNIQUE'
    && String(err.message || '').includes(`users.${column}`);
}
function sendUserConflict(res, field, existingUser) {
  return res.status(409).json({
    error: field === 'email' ? 'Email already exists' : 'Username already exists',
    code: 'USER_CONFLICT',
    field,
    existing: existingUser
      ? {
          id: existingUser.id,
          username: existingUser.username,
          email: normalizeUserEmail(existingUser.email)
        }
      : null
  });
}
function upsertUser(u) {
  const row = { ...u, email: normalizeUserEmail(u.email), password: u.password || '' };
  if (db) {
    db.prepare(`
      INSERT INTO users
        (id,email,username,passHash,password,expiry,protocols,quotaMB,usedMB,createdAt,updatedAt,lastSeen)
      VALUES
        (@id,@email,@username,@passHash,@password,@expiry,@protocols,@quotaMB,@usedMB,@createdAt,@updatedAt,@lastSeen)
      ON CONFLICT(id) DO UPDATE SET
        email=excluded.email, username=excluded.username,
        passHash=excluded.passHash, password=excluded.password,
        expiry=excluded.expiry, protocols=excluded.protocols,
        quotaMB=excluded.quotaMB, usedMB=excluded.usedMB,
        updatedAt=excluded.updatedAt, lastSeen=excluded.lastSeen
    `).run(row);
  } else {
    memUsers.set(row.id, row);
  }
}
function deleteUser(id) {
  if (db) db.prepare('DELETE FROM users WHERE id = ?').run(id);
  else memUsers.delete(id);
}

function scheduleConfigApply(reason) {
  const timer = setTimeout(() => {
    try {
      const status = applyAllConfigs();
      console.log('[CFG] async apply complete:', reason, JSON.stringify(status));
    } catch (e) {
      console.error('[CFG] async apply failed:', reason, e.message);
    }
  }, 250);
  if (typeof timer.unref === 'function') timer.unref();
}

// ── Persist config ────────────────────────────────────────────────────────────
// Bug 53: atomic write via .new temp file then rename — prevents partial reads
//         if the process is interrupted during the write.
function saveConfig() {
  try {
    cfg = normalizeConfig(cfg);
    const dir = path.dirname(PANEL_CONFIG);
    fs.mkdirSync(dir, { recursive: true });
    const tmp = PANEL_CONFIG + '.new';
    fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2), { mode: 0o600 });
    fs.renameSync(tmp, PANEL_CONFIG);   // atomic replace
  } catch (e) { console.error('[CFG]', e.message); }
}

function getCurrentVersion() {
  try {
    const raw = fs.readFileSync(VERSION_FILE, 'utf8');
    const m = raw.match(/^panel_version=(.+)$/m);
    return (m?.[1] || cfg.version || '0.0.0').trim();
  } catch {
    return cfg.version || '0.0.0';
  }
}

function versionGt(a, b) {
  const pa = String(a || '0').split('.').map(n => parseInt(n, 10) || 0);
  const pb = String(b || '0').split('.').map(n => parseInt(n, 10) || 0);
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const da = pa[i] || 0;
    const db = pb[i] || 0;
    if (da > db) return true;
    if (da < db) return false;
  }
  return false;
}

function runUpdateScript(args = [], timeout = 30 * 60 * 1000) {
  const script = fs.existsSync(UPDATE_SH) ? UPDATE_SH : null;
  if (!script) throw new Error('update.sh not found on server');
  return execFileSync('bash', [script, ...args], {
    timeout,
    maxBuffer: 10 * 1024 * 1024,
    env: process.env,
  }).toString();
}

function syncAutoUpdateCron(enabled) {
  const script = fs.existsSync(UPDATE_SH) ? UPDATE_SH : null;
  if (!script) throw new Error('update.sh not found on server');
  const cronPath = '/etc/cron.d/rixxx-panel-update';
  const content = [
    '# Panel Naive + Mieru auto-update',
    '# Managed by the admin panel. The script exits immediately when disabled.',
    `17 3 * * * root cd "${path.dirname(script)}" && /bin/bash "${script}" --auto -y >> /var/log/rixxx-panel-update.log 2>&1`,
    ''
  ].join('\n');
  fs.mkdirSync(path.dirname(cronPath), { recursive: true });
  fs.writeFileSync(cronPath, content, { mode: 0o644 });
  return { enabled, cronPath };
}

// ── buildCaddyfile() ─────────────────────────────────────────────────────────
// Rebuilds the Caddyfile from current cfg and user list.
//
// Bug 23 (P0): the old code emitted a bare "basic_auth" keyword with no
//   arguments (invalid in caddy-forwardproxy-naive → parse error) and used
//   the wrong spelling "basicauth" for per-user lines.  Both are now fixed
//   by delegating to caddyTemplate.js which is the single source of truth.
//
// Bug 26 (P1): delegate to caddyTemplate.js so install.sh, update.sh, and
//   this file all produce byte-for-byte identical Caddyfiles.
//
// Bug 28 (P1): removed redundant "tls <email>" inside the site block —
//   Caddy's automatic HTTPS handles TLS; the global email directive is enough.
//
// Bug 29 (P1): directive order inside forward_proxy is now enforced by the
//   template: basic_auth lines → hide_ip → hide_via → probe_resistance.
//
// Bug 30 (P1): "order forward_proxy before file_server" now appears in the
//   global block via the template.
//
// Bug 34: placeholder emitted when naiveUsers is empty so the forward_proxy
//   block always has at least one credential (prevents unauthenticated access
//   and Caddy validation failure).
//
// Bug 38 (P2): log rotation uses roll_keep_for 720h (30 days) not roll_keep 5.
//
// Bug 21: no site-level log block — global block covers all traffic.
// ── normalizeUpstream() — Bug 92 ─────────────────────────────────────────────
// Caddy's forward_proxy `upstream` directive only accepts a clean https:// URL.
// Users paste the subscription-format key as-is (e.g. "naive+https://u:p@h:443"),
// which makes caddy validate fail with:
//   "forward_proxy: insecure schemes are only allowed to localhost upstreams".
// Strip a leading "naive+" (and any other "<scheme>+" wrapper) so we end up with
// a bare https:// URL. If the input has no scheme at all, assume https://.
function normalizeUpstream(raw) {
  let s = String(raw || '').trim();
  if (!s) return '';
  // Drop a leading "xxx+" wrapper such as "naive+https://..." → "https://..."
  s = s.replace(/^[a-z][a-z0-9.+-]*\+(?=https?:\/\/)/i, '');
  // If a non-https scheme slipped through (e.g. "http://"), upgrade to https.
  s = s.replace(/^http:\/\//i, 'https://');
  // No scheme at all → assume https.
  if (!/^https:\/\//i.test(s)) s = 'https://' + s;
  return s;
}

function buildCaddyfile(config, users) {
  // Filter to naive-protocol users only
  // Bug 44: skip users without a plaintext password — caddy-forwardproxy-naive
  //         hashes the password internally; we cannot feed it a bcrypt hash.
  //         Log a warning so operators know which users are missing.
  const naiveUsers = users.filter(u => {
    try { return JSON.parse(u.protocols || '["naive","mieru"]').includes('naive'); }
    catch { return true; }
  }).map(u => {
    const pass = (u.password || '').trim();
    if (!pass) {
      console.warn(`[CADDY] Bug 44: user '${u.username}' has no plaintext password — skipped from Caddyfile`);
      return null;
    }
    return { username: u.username, password: pass };
  }).filter(Boolean);

  // Read probe secret from config or from the file written by install.sh
  const probeSecret = (config.probeSecret || '').trim() ||
    (fs.existsSync(path.join(resolvedCaddyCfgDir, 'probe_secret'))
      ? fs.readFileSync(path.join(resolvedCaddyCfgDir, 'probe_secret'), 'utf8').trim()
      : '');

  // Bug 81: probe_resistance mode ('off' | 'bare' | 'secret').
  // Back-compat: derive from probeSecret when unset.
  let probeMode = (config.probeMode || '').trim().toLowerCase();
  if (!probeMode) probeMode = probeSecret ? 'secret' : 'bare';

  // Bug 26: delegate to the shared template module (single source of truth).
  // Falls back to an inline render if the template file is not yet deployed.
  const tplPath = path.join(__dirname, 'caddyTemplate.js');
  if (fs.existsSync(tplPath)) {
    const tpl = require(tplPath);
    return tpl.render({
      adminEmail:  config.adminEmail  || '',
      domain:      config.domain      || 'localhost',
      naivePort:   config.naivePort   || 443,
      panelPort:   config.panelPort   || 3000,
      panelPath:   config.panelPath   || '/admin',
      exposePanel: config.exposePanel === true,
      fakeSiteDir: resolvedFakeSiteDir,
      probeSecret,
      probeMode,
      logFile:     LOG_CADDY,
      // Bug 92: normalize (strip "naive+" etc.) before it reaches the template.
      upstream:    (config.cascadeEnabled && config.cascadeNaiveUpstream) ? normalizeUpstream(config.cascadeNaiveUpstream) : '',
    }, naiveUsers);
  }

  // ── Inline fallback (identical rules to caddyTemplate.js) ─────────────────
  // Used only when caddyTemplate.js is not yet on disk (e.g. very first boot
  // before install_panel() has run).  Kept in sync with the template manually.
  const crypto = require('crypto');
  let authLines;
  if (naiveUsers.length > 0) {
    // Bug 23: each credential line is "basic_auth <user> <pass>" — no bare keyword
    authLines = naiveUsers
      .map(u => `    basic_auth ${u.username} ${u.password}`)
      .join('\n');
  } else {
    // Bug 34: unreachable placeholder keeps the block non-empty
    const rnd = crypto.randomBytes(20).toString('hex');
    authLines = `    basic_auth _placeholder_${rnd.slice(0, 16)} _disabled_${rnd.slice(16)}`;
  }

  // Bug 29 + Bug 81: probe_resistance comes after hide_ip + hide_via.
  // 'off' → none; 'secret' → with token; 'bare' → keyword only.
  let probeLine;
  if (probeMode === 'off') {
    probeLine = '';
  } else if (probeMode === 'secret' && probeSecret) {
    probeLine = `\n    probe_resistance ${probeSecret}`;
  } else {
    probeLine = `\n    probe_resistance`;
  }

  // v1.2.6: cascade — upstream proxy support (inline fallback)
  // Bug 92: normalize the upstream so forward_proxy gets a clean https:// URL.
  const upstreamUrl = (config.cascadeEnabled && config.cascadeNaiveUpstream) ? normalizeUpstream(config.cascadeNaiveUpstream) : '';
  const upstreamLine = upstreamUrl ? `\n    upstream ${upstreamUrl}` : '';
  const panelPath = normalizePanelPath(config.panelPath || '/admin');
  const panelBlock = (config.exposePanel === true)
    ? `\n    @panel path ${panelPath} ${panelPath}/*\n    reverse_proxy @panel 127.0.0.1:${config.panelPort || 3000}`
    : '';

  // Bug 28: no "tls <email>" inside site block
  // Bug 30: order directive in global block
  // Bug 38: roll_keep_for 720h
  return `{
  # Bug 30: evaluate forwardproxy before file_server
  order forward_proxy before file_server
  # Bug 80: HTTP/1.1 + HTTP/2 only (disable HTTP/3 / QUIC)
  servers {
    protocols h1 h2
  }
  email ${config.adminEmail || ''}
  admin off
  log {
    # Bug 38: 30-day retention by age
    output file ${LOG_CADDY} {
      roll_size     50mb
      roll_keep_for 720h
    }
    format json
  }
}

# HTTP → HTTPS redirect (also needed for ACME HTTP-01 fallback)
:80 {
  redir https://{host}{uri} permanent
}

${config.domain || 'localhost'} {
  # Bug 83: host-based HTTPS site; Caddy will automate TLS for the domain.

  route {
${panelBlock}
    forward_proxy {
      # Bug 23: no bare "basic_auth" token; each line IS the credential directive
      # Bug 29: order — credentials → hide_ip → hide_via → probe_resistance
${authLines}
      hide_ip
      hide_via${probeLine}${upstreamLine}
    }

    file_server {
      root ${resolvedFakeSiteDir}
    }
  }
}
`;
}

// ── writeCaddyfileAtomic() ────────────────────────────────────────────────────
// Bug 90: caddy-naive.service runs as User=caddy/Group=caddy. If the Caddyfile
// (and its parent dir) are root:root 640, the caddy user cannot read it and the
// service crash-loops with "permission denied" → "Start request repeated too
// quickly". Every write MUST leave the file as root:caddy 640 and the config dir
// as root:caddy 750 (the group needs the dir's execute/traverse bit to open the
// file inside it). chown is best-effort: it only works when the panel runs as
// root, which it does in production.
function fixCaddyPerms() {
  try {
    // Dir: root:caddy 750 so the caddy group can traverse + list.
    try { execFileSync('chown', ['root:caddy', resolvedCaddyCfgDir], { timeout: 5000 }); } catch {}
    try { execFileSync('chmod', ['750', resolvedCaddyCfgDir], { timeout: 5000 }); } catch {}
    // Caddyfile: root:caddy 640 so the caddy group can read it.
    if (fs.existsSync(resolvedCaddyFile)) {
      try { execFileSync('chown', ['root:caddy', resolvedCaddyFile], { timeout: 5000 }); } catch {}
      try { execFileSync('chmod', ['640', resolvedCaddyFile], { timeout: 5000 }); } catch {}
    }
    // probe_secret: root:caddy 640 so caddy can read it for probe_resistance.
    const probeFile = path.join(resolvedCaddyCfgDir, 'probe_secret');
    if (fs.existsSync(probeFile)) {
      try { execFileSync('chown', ['root:caddy', probeFile], { timeout: 5000 }); } catch {}
      try { execFileSync('chmod', ['640', probeFile], { timeout: 5000 }); } catch {}
    }
  } catch (e) {
    console.warn('[CADDY] fixCaddyPerms (non-fatal):', e.message);
  }
}

function writeCaddyfileAtomic(content) {
  fs.mkdirSync(resolvedCaddyCfgDir, { recursive: true });
  const tmp = resolvedCaddyFile + '.new';
  fs.writeFileSync(tmp, content, { mode: 0o640 });
  fs.renameSync(tmp, resolvedCaddyFile);   // atomic replace
  // Bug 90: hand ownership to root:caddy so the service can read it.
  fixCaddyPerms();
}

// Bug 91: last caddy apply error, surfaced to the UI when an apply fails.
let lastCaddyError = '';
function getLastCaddyError() { return lastCaddyError; }

// ── applyCaddyConfig() — Bug 91 ──────────────────────────────────────────────
// Previously the panel applied config via `systemctl reload` (kill -USR1). A
// graceful reload SILENTLY KEEPS the old in-memory config when the new config
// cannot be read (e.g. Bug 90 permission error): `validate` says Valid, status
// is active, logs say "Reloaded", a direct curl works — yet the running process
// never loaded the new upstream, so the client exits from the Entry node and the
// cascade is effectively NOT applied. The failure only surfaced on a full
// restart. Therefore we now ALWAYS do a full `systemctl restart` and then verify
// `systemctl is-active`; on failure we capture the real journal error so the UI
// can show it instead of a misleading "success".
function applyCaddyConfig() {
  lastCaddyError = '';
  try {
    // Clear any prior failure storm so the restart isn't blocked by
    // "Start request repeated too quickly".
    try { execFileSync('systemctl', ['reset-failed', 'caddy-naive'], { timeout: 5000 }); } catch {}
    execFileSync('systemctl', ['restart', 'caddy-naive'], { timeout: 20000 });
  } catch (e) {
    lastCaddyError = collectCaddyError(e);
    return { ok: false, error: lastCaddyError };
  }
  // Verify the service actually came up and stayed up.
  let active = '';
  try { active = execFileSync('systemctl', ['is-active', 'caddy-naive'], { timeout: 5000 }).toString().trim(); }
  catch (e) { active = (e.stdout ? e.stdout.toString().trim() : '') || 'inactive'; }
  if (active !== 'active') {
    lastCaddyError = collectCaddyError(null) || `caddy-naive is ${active || 'inactive'}`;
    return { ok: false, error: lastCaddyError };
  }
  return { ok: true, error: '' };
}

// Pull the real reason a (re)start failed: prefer the most recent journal lines,
// fall back to the exception's stderr/stdout.
function collectCaddyError(err) {
  let msg = '';
  try {
    const j = execFileSync('journalctl', ['-u', 'caddy-naive', '-n', '20', '--no-pager'], { timeout: 5000 }).toString();
    // Surface the lines that actually explain the failure.
    const hot = j.split('\n').filter(l =>
      /permission denied|error|insecure schemes|repeated too quickly|invalid|adapt|loading/i.test(l));
    msg = (hot.length ? hot.slice(-6) : j.trim().split('\n').slice(-6)).join('\n').trim();
  } catch {}
  if (!msg && err) {
    msg = ((err.stderr && err.stderr.toString()) || (err.stdout && err.stdout.toString()) || err.message || '').trim();
  }
  return msg;
}

// ── reloadCaddy() — Bug 91: now a FULL restart + verify (no more silent reload).
// Kept as a thin boolean wrapper so existing callers don't change behaviour.
function reloadCaddy() {
  const r = applyCaddyConfig();
  return r.ok;
}

// ── restartCaddy() — full restart (needed for port/domain changes) ───────────
function restartCaddy() {
  return applyCaddyConfig().ok;
}

// ── Bug 7: UFW single-port helper ────────────────────────────────────────────
function ufwMieruRule(action, start, end, proto, comment) {
  const args = action === 'delete'
    ? ['delete', 'allow', start === end ? `${start}/${proto}` : `${start}:${end}/${proto}`]
    : ['allow', start === end ? `${start}/${proto}` : `${start}:${end}/${proto}`];
  if (comment) args.push('comment', comment);
  try { execFileSync('ufw', args, { timeout: 5000 }); } catch {}
}

// ── Mieru state JSON builder ──────────────────────────────────────────────────
// Bug 51: use safe defaults for mieruPortStart/End in case config values absent
function buildMitaStateFile() {
  const allUsers = getAllUsers();
  const mieruUsers = allUsers.filter(u => {
    try { return JSON.parse(u.protocols || '["naive","mieru"]').includes('mieru'); }
    catch { return true; }
  });

  // Bug 51: parseInt guards against undefined/NaN causing infinite loops
  const portStart = parseInt(cfg.mieruPortStart, 10) || 2000;
  const portEnd   = parseInt(cfg.mieruPortEnd,   10) || 2010;

  // TCP-only by default; UDP is opt-in via cfg.udpEnabled
  const portBindings = [];
  for (let p = portStart; p <= portEnd; p++) {
    portBindings.push({ port: p, protocol: 'TCP' });
    if (cfg.udpEnabled) portBindings.push({ port: p, protocol: 'UDP' });
  }

  const mieruCfg = {
    portBindings,
    users: mieruUsers.map(u => ({
      name:     u.username,
      password: u.password || ''   // plain string — mita hashes on apply
    })),
    loggingLevel: 'INFO',
    mtu: cfg.mtu || 1400
  };

  const pat = cfg.trafficPattern || 'NOOP';
  if (pat !== 'NOOP') {
    const patMap = {
      'RANDOM_PADDING':            { seed: true,  tcpFragment: false, nonce: false },
      'RANDOM_PADDING_AGGRESSIVE': { seed: true,  tcpFragment: true,  nonce: true  },
      'CUSTOM':                    { seed: true,  tcpFragment: true,  nonce: true  }
    };
    if (patMap[pat]) mieruCfg.trafficPattern = patMap[pat];
  }

  // v1.2.6 cascade (Mieru): Variant B is used instead of mita native egress.
  // The entry mita stays a plain server; the RU->EU relay is handled externally
  // by scripts/cascade_mieru.sh (mieru-client + redsocks + iptables). We
  // therefore intentionally do NOT inject `mieruCfg.egress` here.
  // Legacy Variant A native egress is only applied if an operator explicitly
  // sets cascadeMieruEgress.proxies AND no Variant B host is configured.
  if (cfg.cascadeEnabled
      && (!cfg.cascadeMieru || !cfg.cascadeMieru.host)
      && cfg.cascadeMieruEgress && Array.isArray(cfg.cascadeMieruEgress.proxies)
      && cfg.cascadeMieruEgress.proxies.length > 0) {
    mieruCfg.egress = {
      proxies: cfg.cascadeMieruEgress.proxies,
      rules: cfg.cascadeMieruEgress.rules || [{ ipRanges: ['*'], domainNames: ['*'], action: 'DIRECT' }]
    };
  }

  fs.mkdirSync(path.dirname(resolvedMitaFile), { recursive: true });
  const tmp = resolvedMitaFile + '.new';
  fs.writeFileSync(tmp, JSON.stringify(mieruCfg, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, resolvedMitaFile);

  shredFile(resolvedMitaFile + '.last');
  try { fs.copyFileSync(resolvedMitaFile, resolvedMitaFile + '.last'); } catch {}

  return resolvedMitaFile;
}

function applyMitaConfig() {
  const file = buildMitaStateFile();
  try {
    execFileSync('mita', ['apply', 'config', file], { timeout: 15000 });

    // Bug 75: a fresh mita install sits in state IDLE (the installer does NOT
    // start it while users[] is empty — Bug 4). `mita reload` only re-reads the
    // config of an already-RUNNING server; it will NOT lift IDLE -> RUNNING, so
    // the proxy never starts listening and mieru clients can't connect.
    // Therefore: detect status and `mita start` when IDLE, otherwise `reload`.
    let status = '';
    try { status = execFileSync('mita', ['status'], { timeout: 10000 }).toString(); }
    catch { status = ''; }

    if (/RUNNING/i.test(status)) {
      execFileSync('mita', ['reload'], { timeout: 15000 });
    } else {
      // IDLE (or unknown): start the service so it binds the configured ports.
      // Fall back to systemctl restart if `mita start` is unavailable.
      try { execFileSync('mita', ['start'], { timeout: 15000 }); }
      catch { try { execFileSync('systemctl', ['restart', 'mita'], { timeout: 15000 }); } catch {} }
    }

    shredFile(file + '.last');
    return true;
  } catch { return false; }
}

function restartMieru() {
  try {
    try { execFileSync('mita', ['stop'], { timeout: 10000 }); } catch {}
    const file = buildMitaStateFile();
    execFileSync('mita', ['apply', 'config', file], { timeout: 10000 });
    try { execFileSync('mita', ['start'], { timeout: 15000 }); }
    catch { execFileSync('systemctl', ['start', 'mita'], { timeout: 15000 }); }
    shredFile(file + '.last');
    return true;
  } catch { return false; }
}

// ── Mieru cascade (Variant B) — scripts/cascade_mieru.sh orchestrator ─────────
const CASCADE_SCRIPT = path.join(__dirname, '../scripts/cascade_mieru.sh');

// Run cascade_mieru.sh {setup|teardown|status}. Returns { ok, output }.
// Uses execFileSync (no shell) so the exit credentials are passed as argv and
// never interpolated into a shell string.
function runCascadeMieru(action, opts = {}) {
  try {
    const args = [CASCADE_SCRIPT, action];
    if (action === 'setup') {
      args.push(
        '--exit-host',       String(opts.host || ''),
        '--exit-port-start', String(opts.portStart || ''),
        '--exit-port-end',   String(opts.portEnd || ''),
        '--exit-user',       String(opts.user || ''),
        '--exit-pass',       String(opts.pass || ''),
        // Bug 95: mtu MUST match the exit (mita) mtu. Operators normally keep the
        // panel default (1400) on both nodes; allow an override via cascadeMieru.mtu.
        '--exit-mtu',        String(opts.mtu || cfg.mtu || 1400),
        '--exit-mux',        String(opts.mux || 'MULTIPLEXING_LOW')
      );
    }
    const out = execFileSync('bash', args, { timeout: 120000 }).toString();
    return { ok: true, output: out };
  } catch (e) {
    return { ok: false, output: (e.stdout ? e.stdout.toString() : '') + (e.stderr ? e.stderr.toString() : e.message) };
  }
}

function shredFile(fp) {
  if (!fp || !fs.existsSync(fp)) return;
  try { execFileSync('shred', ['-u', fp], { timeout: 5000 }); }
  catch { try { fs.unlinkSync(fp); } catch {} }
}

// ── naiveCascadeStatusText() — Bug 93 ────────────────────────────────────────
// The "Проверить статус" button used to only diagnose the Mieru cascade (Variant
// B), so a Naive-only cascade always showed "configured: 0 / inactive" — wildly
// misleading. This block diagnoses the Naive leg:
//   • whether an `upstream` line is present in the live Caddyfile
//   • `caddy-naive validate` result
//   • `systemctl is-active caddy-naive`
//   • egress IP measured THROUGH the naive upstream (curl -x https://u:p@exit:443)
// Credentials are redacted in the printed output.
function naiveCascadeStatusText() {
  const lines = [];
  lines.push('=== NAIVE CASCADE ===');

  const enabled = !!cfg.cascadeEnabled;
  const upstreamRaw = (cfg.cascadeNaiveUpstream || '').trim();
  const upstream = upstreamRaw ? normalizeUpstream(upstreamRaw) : '';
  const redact = (u) => u.replace(/\/\/([^:@/]+):([^@/]+)@/, '//$1:***@');

  lines.push(`cascadeEnabled : ${enabled}`);
  lines.push(`upstream (cfg) : ${upstream ? redact(upstream) : '(none)'}`);

  // 1) upstream present in the live Caddyfile?
  let inFile = false;
  try {
    if (fs.existsSync(resolvedCaddyFile)) {
      const c = fs.readFileSync(resolvedCaddyFile, 'utf8');
      inFile = /^\s*upstream\s+https:\/\//mi.test(c);
    }
  } catch {}
  lines.push(`upstream in Caddyfile : ${inFile ? 'yes' : 'no'}`);

  // 2) caddy-naive validate
  let validate = 'unknown';
  try {
    execFileSync(CADDY_BIN, ['validate', '--config', resolvedCaddyFile, '--adapter', 'caddyfile'], { timeout: 15000 });
    validate = 'Valid';
  } catch (e) {
    const out = ((e.stdout && e.stdout.toString()) || (e.stderr && e.stderr.toString()) || e.message || '').trim();
    validate = 'INVALID: ' + out.split('\n').slice(-3).join(' ');
  }
  lines.push(`caddy validate : ${validate}`);

  // 3) systemctl is-active caddy-naive
  let active = 'unknown';
  try { active = execFileSync('systemctl', ['is-active', 'caddy-naive'], { timeout: 5000 }).toString().trim(); }
  catch (e) { active = (e.stdout ? e.stdout.toString().trim() : '') || 'inactive'; }
  lines.push(`caddy-naive    : ${active}`);
  if (active !== 'active') {
    const err = collectCaddyError(null);
    if (err) lines.push('  ↳ ' + err.split('\n').join('\n  ↳ '));
  }

  // 4) egress IP through the naive upstream itself.
  if (enabled && upstream) {
    let egress = '';
    try {
      // -x routes through the exit's forward proxy; api.ipify.org returns the
      // public IP the request egressed from (= exit node IP when cascade works).
      egress = execFileSync('curl', [
        '-fsS',
        '--max-time', '12',
        '-x', upstream,
        'https://api.ipify.org'
      ], { timeout: 15000 }).toString().trim();
    } catch (e) {
      egress = 'FAILED (' + ((e.stderr && e.stderr.toString().trim()) || e.message || 'no response') + ')';
    }
    lines.push(`egress via upstream : ${egress || '(empty)'}`);
  } else {
    lines.push('egress via upstream : (cascade not enabled / no upstream)');
  }

  return lines.join('\n');
}

// ── applyAllConfigs() — unified pipeline ─────────────────────────────────────
// Rebuilds Caddyfile, (re)starts Caddy, rebuilds mita state, applies mita config.
// Called after every user CRUD operation.
// Bug 89: creating a naive key used to "not work" until `update.sh --force`,
// because writeCaddyfileAtomic left the file root:root (Bug 90) and reloadCaddy
// silently failed/kept the old config (Bug 91). With the chown in
// writeCaddyfileAtomic and the full restart+verify in applyCaddyConfig, a new
// key now activates immediately. We also surface the real caddy error.
function applyAllConfigs() {
  let caddyOk = false, mitaOk = false, caddyError = '';
  try {
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);          // Bug 90: chown root:caddy inside
    const r = applyCaddyConfig();           // Bug 91: full restart + verify
    caddyOk = r.ok;
    if (!r.ok) {
      caddyError = r.error;
      console.error('[CADDY] apply failed:', r.error);
    }
  } catch (e) { caddyError = e.message; console.error('[CADDY]', e.message); }
  try { mitaOk = applyMitaConfig(); }
  catch (e) { console.error('[MITA]', e.message); }
  return { caddyOk, mitaOk, caddyError, servicesReloaded: caddyOk && mitaOk };
}

// ── Express app ───────────────────────────────────────────────────────────────
const app    = express();
const server = http.createServer(app);
app.disable('x-powered-by');
if (process.env.PANEL_TRUST_PROXY === '1') {
  app.set('trust proxy', 1);
}

app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc:      ["'self'"],
      scriptSrc:       ["'self'",
                        'https://cdn.jsdelivr.net'],
      // Bug CSP: script-src-attr 'none' prevents inline event handlers
      scriptSrcAttr:   ["'none'"],
      styleSrc:        ["'self'", "'unsafe-inline'",
                        'https://fonts.googleapis.com',
                        'https://fonts.gstatic.com'],
      fontSrc:         ["'self'", 'https://fonts.gstatic.com'],
      connectSrc:      ["'self'", 'ws:', 'wss:', 'https://fonts.googleapis.com'],
      imgSrc:          ["'self'", 'data:', 'blob:'],
      mediaSrc:        ["'none'"],
      objectSrc:       ["'none'"],
      frameAncestors:  ["'none'"]
    }
  },
  crossOriginEmbedderPolicy: false
}));

app.use(morgan('combined', {
  stream: { write: m => { try { fs.appendFileSync(LOG_PANEL, m); } catch {} } }
}));
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

// Session
let sessionSecret;
const secretFile = path.join(path.dirname(resolvedDb), '.session_secret');
try { sessionSecret = fs.readFileSync(secretFile, 'utf8').trim(); }
catch {
  sessionSecret = require('crypto').randomBytes(64).toString('hex');
  try {
    fs.mkdirSync(path.dirname(secretFile), { recursive: true });
    fs.writeFileSync(secretFile, sessionSecret, { mode: 0o600 });
  } catch {}
}

app.use(session({
  secret: sessionSecret,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: 'auto', httpOnly: true, sameSite: 'lax', maxAge: 86400000 }
}));

function ensureCsrfToken(req) {
  if (!req.session) return '';
  if (!req.session.csrfToken) req.session.csrfToken = crypto.randomBytes(32).toString('hex');
  return req.session.csrfToken;
}

function requireCsrf(req, res, next) {
  const expected = req.session?.csrfToken;
  const actual = req.get('x-csrf-token');
  if (!expected || !actual || actual !== expected) {
    return res.status(403).json({ error: 'CSRF token missing or invalid' });
  }
  return next();
}

// Rate limits
const loginLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 20,  message: { error: 'Too many attempts' } });
const apiLimiter   = rateLimit({ windowMs:      60 * 1000, max: 300, message: { error: 'Rate limit exceeded' } });
app.use('/api/', apiLimiter);
app.use('/api/', (req, res, next) => {
  if (['GET', 'HEAD', 'OPTIONS'].includes(req.method)) return next();
  if (req.path === '/login') return next();
  return requireCsrf(req, res, next);
});

app.use((req, res, next) => {
  if (PANEL_BASE_PATH === '/') return next();
  if (req.path === '/healthz' || req.path === '/favicon.ico') return next();
  const urlPath = req.path || '/';
  if (urlPath === PANEL_BASE_PATH || urlPath.startsWith(PANEL_BASE_PATH + '/')) {
    req.url = req.url.slice(PANEL_BASE_PATH.length) || '/';
    if (req.url === '') req.url = '/';
    return next();
  }
  if (urlPath === '/' || urlPath === '') {
    if (req.method === 'GET' || req.method === 'HEAD') {
      return res.redirect(302, `${PANEL_BASE_PATH}/`);
    }
    return res.status(404).json({ error: 'Not Found' });
  }
  return res.status(404).json({ error: 'Not Found' });
});

app.get('/healthz', (_req, res) => {
  res.json({ ok: true, uptime: Math.floor(process.uptime()), ts: new Date().toISOString() });
});

// Static files
app.use(express.static(path.join(__dirname, '../public')));

// ── Auth middleware ───────────────────────────────────────────────────────────
function requireAuth(req, res, next) {
  if (req.session?.authenticated) return next();
  if (req.path.startsWith('/api/')) return res.status(401).json({ error: 'Unauthorized' });
  res.redirect('/');
}

// ── Auth routes ───────────────────────────────────────────────────────────────
app.post('/api/login', loginLimiter, (req, res) => {
  const { username, password } = req.body;
  if (!username || !password)
    return res.status(400).json({ error: 'Missing credentials' });

  const isAdmin =
    username === cfg.adminUser &&
    cfg.adminPassHash &&
    bcrypt.compareSync(password, cfg.adminPassHash);

  if (!isAdmin) return res.status(401).json({ error: 'Invalid credentials' });
  req.session.authenticated = true;
  req.session.username = username;
  req.session.csrfToken = crypto.randomBytes(32).toString('hex');
  audit('login', { username }, username);
  res.json({ ok: true, username, csrfToken: req.session.csrfToken });
});

app.post('/api/logout', requireAuth, requireCsrf, (req, res) => {
  const username = req.session.username;
  audit('logout', {}, username);
  req.session.destroy(() => res.json({ ok: true }));
});

app.get('/api/me', requireAuth, (req, res) => {
  res.json({ username: req.session.username, authenticated: true, csrfToken: ensureCsrfToken(req) });
});

// ── Config API ────────────────────────────────────────────────────────────────
app.get('/api/config', requireAuth, (req, res) => {
  const { adminPassHash, ...safe } = cfg;
  // Never expose secrets to the browser. Mask the cascade exit password and the
  // legacy native-egress proxy passwords; expose a boolean "set" flag instead.
  if (safe.cascadeMieru && typeof safe.cascadeMieru === 'object') {
    const { pass, ...cm } = safe.cascadeMieru;
    safe.cascadeMieru = { ...cm, pass: !!pass };   // pass becomes true/false
  }
  if (safe.cascadeMieruEgress && Array.isArray(safe.cascadeMieruEgress.proxies)) {
    safe.cascadeMieruEgress = {
      ...safe.cascadeMieruEgress,
      proxies: safe.cascadeMieruEgress.proxies.map(p => {
        if (p && p.socks5Authentication) {
          const { password, ...auth } = p.socks5Authentication;
          return { ...p, socks5Authentication: { ...auth, password: !!password } };
        }
        return p;
      })
    };
  }
  res.json(safe);
});

app.post('/api/config', requireAuth, (req, res) => {
  ['domain','naivePort','mieruPortStart','mieruPortEnd',
   'trafficPattern','mtu','udpEnabled','adminEmail','language',
   'probeSecret','fakeSiteUrl'].forEach(k => {
    if (req.body[k] !== undefined) cfg[k] = req.body[k];
  });
  saveConfig();
  audit('config:update', {
    fields: Object.keys(req.body || {}).filter(k => [
      'domain','naivePort','mieruPortStart','mieruPortEnd',
      'trafficPattern','mtu','udpEnabled','adminEmail','language',
      'probeSecret','fakeSiteUrl'
    ].includes(k))
  }, req.session.username);
  const { adminPassHash, ...safe } = cfg;
  res.json({ ok: true, cfg: safe });
});

app.post('/api/config/password', requireAuth, (req, res) => {
  const { current, newPass } = req.body;
  if (!current || !newPass) return res.status(400).json({ error: 'Missing fields' });
  if (newPass.length < 8) return res.status(400).json({ error: 'New password must be at least 8 characters' });
  const valid = cfg.adminPassHash && bcrypt.compareSync(current, cfg.adminPassHash);
  if (!valid) return res.status(401).json({ error: 'Current password incorrect' });
  cfg.adminPassHash = bcrypt.hashSync(newPass, 12);
  saveConfig();
  audit('admin:password_change', {}, req.session.username);
  res.json({ ok: true });
});

app.get('/api/update/status', requireAuth, (req, res) => {
  const currentVersion = getCurrentVersion();
  const targetVersion = cfg.version || '1.2.6';
  const panelHost = cfg.panelHost || '127.0.0.1';
  const panelPath = normalizePanelPath(cfg.panelPath || '/admin');
  const panelUrl = cfg.exposePanel === true
    ? `https://${cfg.domain || cfg.serverIp || 'localhost'}${panelPath}/`
    : `http://${panelHost}:${cfg.panelPort}${panelPath}/`;
  res.json({
    ok: true,
    currentVersion,
    targetVersion,
    updateAvailable: versionGt(targetVersion, currentVersion),
    autoUpdateEnabled: cfg.autoUpdateEnabled === true,
    panel: { host: panelHost, port: cfg.panelPort, path: panelPath, url: panelUrl }
  });
});

app.post('/api/update/check', requireAuth, (req, res) => {
  try {
    const output = runUpdateScript(['--check-update']);
    audit('update:check', {}, req.session.username);
    res.json({ ok: true, output });
  } catch (e) {
    res.status(500).json({ error: e.stdout?.toString() || e.stderr?.toString() || e.message });
  }
});

app.post('/api/update/apply', requireAuth, (req, res) => {
  try {
    const output = runUpdateScript(['--force', '-y']);
    audit('update:apply', {}, req.session.username);
    res.json({ ok: true, output });
  } catch (e) {
    res.status(500).json({ error: e.stdout?.toString() || e.stderr?.toString() || e.message });
  }
});

app.post('/api/update/auto', requireAuth, (req, res) => {
  const enabled = req.body?.enabled === true || req.body?.enabled === 'true';
  cfg.autoUpdateEnabled = enabled;
  saveConfig();
  try { syncAutoUpdateCron(enabled); } catch (e) { return res.status(500).json({ error: e.message }); }
  audit('update:auto_toggle', { enabled }, req.session.username);
  res.json({ ok: true, autoUpdateEnabled: enabled });
});

// ── Validation helpers ────────────────────────────────────────────────────────
const VALID_PROTOCOLS = ['naive', 'mieru'];
const USERNAME_RE     = /^[a-zA-Z0-9_.-]{1,64}$/;
const EMAIL_RE        = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * Bug 8: normalise quota — accept quotaMB or quotaGb (gb * 1024 → MB).
 * Bug 9: validate all user input fields.
 */
function validateUserInput({ email, username, password, protocols, quotaMB, quotaGb }, requirePassword) {
  if (!username || !USERNAME_RE.test(username))
    return { error: 'username required and must match [a-zA-Z0-9_.-] (max 64 chars)' };
  // Email is optional (TLS cert is configured at install time via Caddy ACME,
  // not per-user). If provided, it must still be a valid address.
  if (email !== undefined && email !== null && email !== '' && !EMAIL_RE.test(email))
    return { error: 'email is invalid' };
  if (requirePassword) {
    if (!password) return { error: 'password is required for new users' };
    if (password.length < 8) return { error: 'password must be at least 8 characters' };
  } else if (password !== undefined && password !== null && password !== '' && password.length < 8) {
    return { error: 'new password must be at least 8 characters' };
  }
  // Bug 8: accept quotaGb; convert to quotaMB
  let resolvedQuotaMB = 0;
  if (quotaMB !== undefined && quotaMB !== null) {
    resolvedQuotaMB = parseInt(quotaMB, 10);
    if (isNaN(resolvedQuotaMB) || resolvedQuotaMB < 0)
      return { error: 'quotaMB must be a non-negative integer' };
  } else if (quotaGb !== undefined && quotaGb !== null) {
    const gb = parseFloat(quotaGb);
    if (isNaN(gb) || gb < 0) return { error: 'quotaGb must be a non-negative number' };
    resolvedQuotaMB = Math.round(gb * 1024);
  }
  // Bug 9: protocols allowlist
  let resolvedProtocols = ['naive', 'mieru'];
  if (protocols !== undefined) {
    if (!Array.isArray(protocols))
      return { error: 'protocols must be an array' };
    const invalid = protocols.filter(p => !VALID_PROTOCOLS.includes(p));
    if (invalid.length)
      return { error: `unknown protocol(s): ${invalid.join(', ')}. Allowed: ${VALID_PROTOCOLS.join(', ')}` };
    if (!protocols.length)
      return { error: 'at least one protocol is required (naive, mieru)' };
    resolvedProtocols = protocols;
  }
  return { quotaMB: resolvedQuotaMB, protocols: resolvedProtocols };
}

/**
 * Bug 7: parse all TEXT JSON columns back to JS types when returning user rows.
 */
function parseUserRow(u) {
  return {
    ...u,
    protocols: typeof u.protocols === 'string'
      ? (() => { try { return JSON.parse(u.protocols); } catch { return []; } })()
      : (u.protocols || []),
  };
}

// ── Users API ─────────────────────────────────────────────────────────────────
app.get('/api/users', requireAuth, (req, res) => {
  const users = getAllUsers().map(u => {
    const { passHash, password, ...rest } = u;
    return parseUserRow(rest);
  });
  res.json(users);
});

app.post('/api/users', requireAuth, (req, res) => {
  const { email, username, password, expiry, protocols, quotaMB, quotaGb } = req.body;
  const validation = validateUserInput(
    { email, username, password, protocols, quotaMB, quotaGb }, true);
  if (validation.error)
    return res.status(400).json({ error: validation.error });

  const normalizedUsername = String(username).trim();
  const normalizedEmail = normalizeUserEmail(email);
  const existingUsername = getUserByUsername(normalizedUsername);
  const existingEmail = getUserByEmail(normalizedEmail);
  if (existingUsername && existingEmail && existingUsername.id !== existingEmail.id) {
    return res.status(409).json({
      error: 'Username and email belong to different users',
      code: 'USER_CONFLICT_SPLIT',
      usernameOwner: {
        id: existingUsername.id,
        username: existingUsername.username,
        email: normalizeUserEmail(existingUsername.email)
      },
      emailOwner: {
        id: existingEmail.id,
        username: existingEmail.username,
        email: normalizeUserEmail(existingEmail.email)
      }
    });
  }

  if (expiry && isNaN(Date.parse(expiry)))
    return res.status(400).json({ error: 'expiry must be a valid ISO date string' });

  const now  = new Date().toISOString();
  const existingUser = existingUsername || existingEmail || null;
  const updatedExisting = Boolean(existingUser);
  const user = {
    ...(existingUser || {}),
    id:        existingUser?.id || uuidv4(),
    // Email is optional: store NULL (not '') so the UNIQUE constraint allows
    // multiple users without an email.
    email:     normalizedEmail,
    username:  normalizedUsername,
    passHash:  bcrypt.hashSync(password, 12),
    password,
    expiry:    expiry || null,
    protocols: JSON.stringify(validation.protocols),
    quotaMB:   validation.quotaMB,
    usedMB:    existingUser?.usedMB || 0,
    createdAt: existingUser?.createdAt || now,
    updatedAt: now,
    lastSeen:  existingUser?.lastSeen || null
  };
  try {
    upsertUser(user);
  } catch (e) {
    if (isUniqueConstraintError(e, 'username'))
      return sendUserConflict(res, 'username', getUserByUsername(normalizedUsername));
    if (isUniqueConstraintError(e, 'email'))
      return sendUserConflict(res, 'email', getUserByEmail(normalizedEmail));
    throw e;
  }

  audit(updatedExisting ? 'user:upsert' : 'user:create',
    { id: user.id, username: user.username, protocols: validation.protocols, updatedExisting },
    req.session.username);
  scheduleConfigApply(updatedExisting ? 'user:upsert' : 'user:create');

  const { passHash, password: _p, ...safe } = user;
  res.status(updatedExisting ? 200 : 201).json({
    ok: true,
    updatedExisting,
    configsApplyQueued: true,
    servicesReloaded: 'pending',
    ...parseUserRow(safe),
  });
});

app.put('/api/users/:id', requireAuth, (req, res) => {
  const user = getUserById(req.params.id);
  if (!user) return res.status(404).json({ error: 'User not found' });

  const { email, username, password, expiry, protocols, quotaMB, quotaGb } = req.body;
  const validation = validateUserInput(
    { email: email ?? user.email,
      username: username ?? user.username,
      password,
      protocols,
      quotaMB: quotaMB !== undefined ? quotaMB : undefined,
      quotaGb: quotaGb !== undefined ? quotaGb : undefined }, false);
  if (validation.error)
    return res.status(400).json({ error: validation.error });

  if (expiry !== undefined && expiry !== null && isNaN(Date.parse(expiry)))
    return res.status(400).json({ error: 'expiry must be a valid ISO date string' });

  const normalizedUsername = username ?? user.username;
  const existingUsername = getUserByUsername(normalizedUsername);
  if (existingUsername && existingUsername.id !== user.id)
    return sendUserConflict(res, 'username', existingUsername);

  const normalizedEmail = email !== undefined ? normalizeUserEmail(email) : normalizeUserEmail(user.email);
  const existingEmail = getUserByEmail(normalizedEmail);
  if (existingEmail && existingEmail.id !== user.id)
    return sendUserConflict(res, 'email', existingEmail);

  const updated = {
    ...user,
    email:     normalizedEmail,
    username:  normalizedUsername,
    expiry:    expiry    !== undefined ? (expiry || null) : user.expiry,
    protocols: protocols
      ? JSON.stringify(validation.protocols)
      : user.protocols,
    quotaMB:   (quotaMB !== undefined || quotaGb !== undefined)
      ? validation.quotaMB
      : user.quotaMB,
    updatedAt: new Date().toISOString()
  };
  if (password) {
    updated.passHash = bcrypt.hashSync(password, 12);
    updated.password = password;
  }
  try {
    upsertUser(updated);
  } catch (e) {
    if (isUniqueConstraintError(e, 'username'))
      return sendUserConflict(res, 'username', getUserByUsername(normalizedUsername));
    if (isUniqueConstraintError(e, 'email'))
      return sendUserConflict(res, 'email', getUserByEmail(normalizedEmail));
    throw e;
  }

  audit('user:update', { id: updated.id, username: updated.username, protocols: validation.protocols || updated.protocols }, req.session.username);
  scheduleConfigApply('user:update');

  const { passHash, password: _p, ...safe } = updated;
  res.json({ ok: true, configsApplyQueued: true, servicesReloaded: 'pending', ...parseUserRow(safe) });
});

app.delete('/api/users/:id', requireAuth, (req, res) => {
  let user = getUserById(req.params.id);
  let matchedBy = 'id';
  const fallbackUsername = String(req.query.username || '').trim();
  if (!user && fallbackUsername) {
    user = getUserByUsername(fallbackUsername);
    matchedBy = 'username';
  }
  if (!user) return res.json({ ok: true, alreadyDeleted: true, servicesReloaded: true });
  deleteUser(user.id);
  audit('user:delete', { id: user.id, username: user.username, matchedBy }, req.session.username);
  scheduleConfigApply('user:delete');
  res.json({
    ok: true,
    configsApplyQueued: true,
    servicesReloaded: 'pending',
    deleted: { id: user.id, username: user.username, matchedBy }
  });
});

// ── Server settings ───────────────────────────────────────────────────────────

// Caddy port: rebuild Caddyfile + full restart (port binding change)
// Bug 52: verify caddy-naive is active after restart; return HTTP 500 if not
app.post('/api/settings/naive-port', requireAuth, (req, res) => {
  const p = parseInt(req.body.port, 10);
  if (!p || p < 1 || p > 65535)
    return res.status(400).json({ error: 'Invalid port (1–65535)' });
  cfg.naivePort = p; saveConfig();
  try {
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);
    restartCaddy();
    // Bug 52: confirm the service is actually running after restart
    let active = false;
    try { execFileSync('systemctl', ['is-active', 'caddy-naive'], { timeout: 8000 }); active = true; } catch {}
    if (!active) {
      return res.status(500).json({
        ok: false,
        error: 'caddy-naive failed to start after port change — run: journalctl -u caddy-naive -n 30'
      });
    }
    audit('settings:naive_port', { port: p }, req.session.username);
    res.json({ ok: true, message: `NaiveProxy port changed to ${p}. Clients must download new configs.` });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Mieru ports: UFW update + full restart
app.post('/api/settings/mieru-ports', requireAuth, (req, res) => {
  const s = parseInt(req.body.portStart, 10);
  const e = parseInt(req.body.portEnd,   10);
  if (!s || !e || s < 1025 || e > 65535 || e < s)
    return res.status(400).json({ error: 'Invalid port range (1025–65535, end ≥ start)' });

  const oldS = cfg.mieruPortStart, oldE = cfg.mieruPortEnd;
  cfg.mieruPortStart = s; cfg.mieruPortEnd = e; saveConfig();

  try {
    // Bug 7: use single-port helper to avoid UFW crash when start===end
    ufwMieruRule('delete', oldS, oldE, 'tcp', '');
    ufwMieruRule('delete', oldS, oldE, 'udp', '');
    ufwMieruRule('',       s,    e,    'tcp', 'Mieru TCP');
    if (cfg.udpEnabled) ufwMieruRule('', s, e, 'udp', 'Mieru UDP');
  } catch {}

  try {
    const ok = restartMieru();
    audit('settings:mieru_ports', { start: s, end: e, ok }, req.session.username);
    res.json({ ok, message: `Mieru ports changed to ${s}–${e}. Service restarted. Clients must download new configs.` });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// Traffic pattern + MTU: mita reload
app.post('/api/settings/traffic-pattern', requireAuth, (req, res) => {
  const validPatterns = ['NOOP', 'RANDOM_PADDING', 'RANDOM_PADDING_AGGRESSIVE'];
  const { pattern, mtu } = req.body;
  if (!validPatterns.includes(pattern))
    return res.status(400).json({ error: `Invalid pattern. Valid: ${validPatterns.join(', ')}` });
  if (mtu !== undefined) {
    const m = parseInt(mtu, 10);
    if (m < 1280 || m > 1400) return res.status(400).json({ error: 'MTU must be 1280–1400' });
    cfg.mtu = m;
  }
  cfg.trafficPattern = pattern; saveConfig();
  try {
    const ok = applyMitaConfig();
    audit('settings:traffic_pattern', { pattern, mtu: cfg.mtu, ok }, req.session.username);
    res.json({ ok, pattern, mtu: cfg.mtu });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// UDP toggle: requires full Mieru restart (port bindings change)
app.post('/api/settings/udp-toggle', requireAuth, (req, res) => {
  const enable = req.body.enabled === true || req.body.enabled === 'true';
  cfg.udpEnabled = enable; saveConfig();
  try {
    const s = cfg.mieruPortStart, e = cfg.mieruPortEnd;
    // Bug 7: use single-port helper to avoid UFW crash when start===end
    if (enable) {
      ufwMieruRule('', s, e, 'udp', 'Mieru UDP');
    } else {
      ufwMieruRule('delete', s, e, 'udp', '');
    }
  } catch {}
  try {
    const ok = restartMieru();
    audit('settings:udp_toggle', { enabled: enable, ok }, req.session.username);
    res.json({ ok, udpEnabled: enable,
      message: `UDP ${enable ? 'enabled' : 'disabled'}. Mieru restarted.` });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

// Language setting
app.post('/api/settings/language', requireAuth, (req, res) => {
  const { language } = req.body;
  if (!['ru', 'en'].includes(language))
    return res.status(400).json({ error: 'Supported languages: ru, en' });
  cfg.language = language;
  saveConfig();
  audit('settings:language', { language }, req.session.username);
  res.json({ ok: true, language });
});

// Probe secret update — rebuilds Caddyfile and reloads Caddy.
// Setting a secret also switches probeMode to 'secret'.
app.post('/api/settings/probe-secret', requireAuth, (req, res) => {
  const { probeSecret } = req.body;
  if (!probeSecret || probeSecret.length < 8)
    return res.status(400).json({ error: 'probe_secret must be at least 8 characters' });
  cfg.probeSecret = probeSecret;
  cfg.probeMode = 'secret';          // Bug 81: setting a secret implies secret mode
  saveConfig();
  // Persist to file for install.sh smoke tests
  try {
    fs.writeFileSync(path.join(resolvedCaddyCfgDir, 'probe_secret'), probeSecret, { mode: 0o600 });
  } catch {}
  try {
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);
    const ok = reloadCaddy();
    audit('settings:probe_secret', { hasSecret: true, mode: cfg.probeMode, ok }, req.session.username);
    res.json({ ok, message: 'Probe secret updated. Caddy reloaded.' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Bug 81: probe_resistance mode toggle ('off' | 'bare' | 'secret').
//   'off'    → remove probe_resistance entirely
//   'bare'   → bare  probe_resistance  (no secret) — matches known-good ref server
//   'secret' → probe_resistance <secret>  (requires an existing/provided secret)
app.post('/api/settings/probe-mode', requireAuth, (req, res) => {
  const { probeMode, probeSecret } = req.body || {};
  const mode = String(probeMode || '').trim().toLowerCase();
  if (!['off', 'bare', 'secret'].includes(mode))
    return res.status(400).json({ error: "probeMode must be one of: off, bare, secret" });

  if (mode === 'secret') {
    // A secret is required — either provided now or already stored.
    const newSecret = (probeSecret || '').trim();
    if (newSecret) {
      if (newSecret.length < 8)
        return res.status(400).json({ error: 'probe_secret must be at least 8 characters' });
      cfg.probeSecret = newSecret;
      try {
        fs.writeFileSync(path.join(resolvedCaddyCfgDir, 'probe_secret'), newSecret, { mode: 0o600 });
      } catch {}
    } else if (!(cfg.probeSecret || '').trim()) {
      return res.status(400).json({ error: "secret mode requires a probe_secret (>= 8 chars)" });
    }
  }

  cfg.probeMode = mode;
  saveConfig();
  try {
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);
    const ok = reloadCaddy();
    audit('settings:probe_mode', { mode, hasSecret: !!cfg.probeSecret, ok }, req.session.username);
    res.json({ ok, probeMode: mode, message: `probe_resistance mode set to '${mode}'. Caddy reloaded.` });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// Bug 15: /api/services/rebuild-all — used by update.sh --repair
app.post('/api/services/rebuild-all', requireAuth, (req, res) => {
  try {
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);
    const caddyOk = reloadCaddy();
    const mitaOk  = applyMitaConfig();
    res.json({ ok: true, caddyOk, mitaOk,
      message: 'Caddyfile and mita-state.json rebuilt from database.' });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── v1.2.6: Cascade settings (Variant B) ──────────────────────────────────────
// Naive cascade  → Caddyfile `upstream` (handled by buildCaddyfile).
// Mieru cascade  → Variant B (mieru-client + redsocks + iptables) orchestrated
//                  by scripts/cascade_mieru.sh. The entry mita stays plain.
app.get('/api/settings/cascade', requireAuth, (req, res) => {
  const m = cfg.cascadeMieru || {};
  res.json({
    cascadeEnabled: !!cfg.cascadeEnabled,
    cascadeNaiveUpstream: cfg.cascadeNaiveUpstream || '',
    cascadeMieru: {
      host:      m.host || '',
      portStart: m.portStart || 2012,
      portEnd:   m.portEnd   || 2022,
      user:      m.user || '',
      mtu:       m.mtu || 1400,
      // never return the stored exit password; UI shows a placeholder
      hasPass:   !!m.pass
    }
  });
});

// Live cascade status — Bug 93: diagnose BOTH legs (Naive + Mieru).
app.get('/api/settings/cascade/status', requireAuth, (req, res) => {
  let naiveOut = '';
  try { naiveOut = naiveCascadeStatusText(); }
  catch (e) { naiveOut = '=== NAIVE CASCADE ===\n(error: ' + e.message + ')'; }

  const m = runCascadeMieru('status');
  const mieruOut = '=== MIERU CASCADE (Variant B) ===\n' + (m.output || '(no output)');

  const output = naiveOut + '\n\n' + mieruOut;
  res.json({ ok: m.ok, output });
});

app.post('/api/settings/cascade', requireAuth, (req, res) => {
  const { cascadeEnabled, cascadeNaiveUpstream, cascadeMieru } = req.body;
  const enabled = !!cascadeEnabled;
  cfg.cascadeEnabled = enabled;
  if (cascadeNaiveUpstream !== undefined) {
    // Bug 92: normalize on store too (defense in depth) — strip "naive+" etc. so
    // the saved config and the generated Caddyfile both carry a clean https:// URL.
    const raw = String(cascadeNaiveUpstream || '').trim();
    cfg.cascadeNaiveUpstream = raw ? normalizeUpstream(raw) : '';
  }

  // Merge Mieru exit settings. A blank password means "keep existing".
  const prev = cfg.cascadeMieru || {};
  if (cascadeMieru !== undefined) {
    const m = cascadeMieru || {};
    cfg.cascadeMieru = {
      host:      String(m.host ?? prev.host ?? '').trim(),
      portStart: parseInt(m.portStart ?? prev.portStart ?? 2012, 10) || 2012,
      portEnd:   parseInt(m.portEnd   ?? prev.portEnd   ?? 2022, 10) || 2022,
      user:      String(m.user ?? prev.user ?? '').trim(),
      pass:      (m.pass !== undefined && String(m.pass).length > 0)
                   ? String(m.pass)
                   : (prev.pass || ''),
      // Bug 95: mtu must match the exit (mita). Default 1400, clamp 1280-1400.
      mtu:       (() => {
                   const v = parseInt(m.mtu ?? prev.mtu ?? cfg.mtu ?? 1400, 10) || 1400;
                   return (v < 1280 || v > 1400) ? 1400 : v;
                 })()
    };
  }
  saveConfig();

  try {
    // 1) Naive leg — rebuild Caddyfile (upstream applied when enabled).
    // Bug 90: writeCaddyfileAtomic chowns root:caddy.
    // Bug 91: applyCaddyConfig does a full restart + is-active verify and
    //         returns the real error (no more silent reload masking failures).
    const content = buildCaddyfile(cfg, getAllUsers());
    writeCaddyfileAtomic(content);
    const caddyRes = applyCaddyConfig();
    const caddyOk = caddyRes.ok;

    // 2) Mieru leg — Variant B orchestration.
    let cascadeOk = true, cascadeOut = '';
    const m = cfg.cascadeMieru || {};
    const hasMieruExit = enabled && m.host && m.user && m.pass;
    if (hasMieruExit) {
      const r = runCascadeMieru('setup', {
        host: m.host, portStart: m.portStart, portEnd: m.portEnd,
        user: m.user, pass: m.pass, mtu: m.mtu
      });
      cascadeOk = r.ok; cascadeOut = r.output;
    } else {
      // Cascade disabled (or no Mieru exit configured) → ensure relay is down.
      const r = runCascadeMieru('teardown');
      cascadeOk = r.ok; cascadeOut = r.output;
    }

    // Entry mita stays a plain server in Variant B — just re-apply its config.
    const mitaOk = applyMitaConfig();

    const ok = caddyOk && cascadeOk && mitaOk;
    res.status(ok ? 200 : 500).json({
      ok,
      caddyOk, mitaOk, cascadeOk,
      // Bug 91: surface the real caddy-naive error to the UI on failure.
      caddyError: caddyOk ? '' : (caddyRes.error || ''),
      cascadeOutput: cascadeOut,
      message: enabled
        ? (hasMieruExit
            ? 'Cascade enabled. Naive upstream + Mieru relay (Variant B) applied.'
            : 'Cascade enabled for Naive only (no Mieru exit configured).')
        : 'Cascade disabled. Relay torn down.'
    });
    audit('settings:cascade', {
      enabled,
      naiveUpstream: !!cfg.cascadeNaiveUpstream,
      mieruExit: !!hasMieruExit,
      caddyOk,
      mitaOk,
      cascadeOk
    }, req.session.username);
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// ── Client configs ────────────────────────────────────────────────────────────

// Naive link (used with caddy-forwardproxy)
app.get('/api/users/:id/config/naive', requireAuth, (req, res) => {
  const user = getUserById(req.params.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const password = req.query.password || user.password || 'YOUR_PASSWORD';
  // naive+https:// link for caddy-forwardproxy-naive
  const link = `naive+https://${user.username}:${encodeURIComponent(password)}@${cfg.domain}:${cfg.naivePort}`;
  res.json({ link, username: user.username });
});

// Bug 5: transport field (not protocol); Bug 12: server_ports array
// P3 (selectable mieru port): validate a requested port against the configured
//   range. mita listens on the WHOLE range (portRange "start-end"), so any port
//   inside [start,end] is valid for the client to dial. Returns `start` when the
//   request is absent, non-numeric, or outside the range.
function pickMieruPort(requested, start, end) {
  const p = parseInt(requested, 10);
  if (Number.isInteger(p) && p >= start && p <= end) return p;
  return start;
}

app.get('/api/users/:id/config/mieru', requireAuth, (req, res) => {
  const user = getUserById(req.params.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const password = req.query.password || user.password || 'YOUR_PASSWORD';

  // Build server_ports array (Bug 12)
  // Bug 70: mieruPortStart/End may be strings or undefined; parseInt prevents
  // an infinite for-loop when NaN comparisons silently return false
  const _portStart70a = parseInt(cfg.mieruPortStart, 10) || 2000;
  const _portEnd70a   = parseInt(cfg.mieruPortEnd,   10) || 2010;
  const serverPorts = [];
  for (let p = _portStart70a; p <= _portEnd70a; p++) {
    serverPorts.push(p);
  }
  // P3 (selectable port): allow the client to pick which port from the
  //   configured mieru range is written into server_port. Falls back to the
  //   range start when ?port= is absent or out of range.
  const mieruPort = pickMieruPort(req.query.port, _portStart70a, _portEnd70a);

  // Bug 74: align mieru outbound with the field-tested working client format
  // (Karing / sing-box mieru):
  //   - use `multiplexing: "MULTIPLEXING_HIGH"` (string enum), NOT
  //     `multiplex: { enabled: false }` (that object form is for other
  //     protocols' stream multiplexing and silently breaks the mieru parser);
  //   - use a single `server_port` (the working config does NOT send a
  //     `server_ports` array — sending both confuses the client);
  //   - prefer the raw server IP (mieru is IP-based, no SNI/TLS).
  const singboxCfg = {
    log: { level: 'info' },
    dns: {
      servers: [
        { tag: 'google', address: '8.8.8.8' },
        { tag: 'local',  address: '1.1.1.1', detour: 'direct' }
      ]
    },
    outbounds: [
      {
        type: 'mieru', tag: 'mieru-out',
        server: cfg.serverIp || cfg.domain,
        server_port: mieruPort,
        // Bug 5: transport field (TCP/UDP) — not protocol
        transport: 'TCP',
        username: user.username, password,
        // Bug 74: string enum, not an object
        multiplexing: 'MULTIPLEXING_HIGH'
      },
      { type: 'direct', tag: 'direct' }
    ],
    route: { final: 'mieru-out' }
  };
  // Keep the full port range available for clients/tooling that want it.
  void serverPorts;
  const filename = `mieru-${user.username}-${cfg.domain}.json`;
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Content-Type', 'application/json');
  res.json(singboxCfg);
});

app.get('/api/users/:id/config/universal', requireAuth, (req, res) => {
  const user = getUserById(req.params.id);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const password = req.query.password || user.password || 'YOUR_PASSWORD';

  // Bug 70: parseInt guard prevents an infinite loop when values are strings/NaN
  const _portStart70b = parseInt(cfg.mieruPortStart, 10) || 2000;
  const _portEnd70b   = parseInt(cfg.mieruPortEnd,   10) || 2010;
  // P3 (selectable port): honour ?port= within the configured range.
  const mieruPortU = pickMieruPort(req.query.port, _portStart70b, _portEnd70b);

  const universalCfg = {
    log: { level: 'info', timestamp: true },
    dns: {
      servers: [
        { tag: 'remote', address: 'tls://8.8.8.8',               detour: 'select' },
        { tag: 'local',  address: 'https://223.5.5.5/dns-query',  detour: 'direct' }
      ],
      rules:  [{ outbound: 'any', server: 'local' }],
      final:  'remote'
    },
    outbounds: [
      {
        type: 'urltest', tag: 'select',
        outbounds: ['naive-out', 'mieru-out'],
        url: 'https://www.gstatic.com/generate_204',
        interval: '3m', tolerance: 50
      },
      {
        // Bug 87: NaiveProxy outbound MUST be type "naive", NOT "http".
        // A plain `type:http` is an ordinary HTTP-CONNECT proxy; it completes
        // TLS + CONNECT but lacks NaiveProxy's Cronet/Chromium traffic shaping
        // (HTTP/2 framing, padding, header order) that the caddy-forwardproxy
        // server expects — so the manual `naive+https://…` key worked while the
        // subscription's http outbound did not. Karing bundles the
        // with_naive_outbound build (libcronet), so type:naive works there.
        // `quic:false` matches the server's global `servers { protocols h1 h2 }`
        // (Bug 80 — HTTP/3 disabled); tls only carries server_name (the only
        // TLS field the naive outbound honours besides certificate/ech).
        type: 'naive', tag: 'naive-out',
        server: cfg.domain, server_port: cfg.naivePort,
        username: user.username, password,
        quic: false,
        tls: { enabled: true, server_name: cfg.domain }
      },
      {
        // Bug 74: working mieru format — string `multiplexing`, single port,
        // no `server_ports` array, no `multiplex` object.
        type: 'mieru', tag: 'mieru-out',
        server: cfg.serverIp || cfg.domain,
        server_port: mieruPortU,
        transport: 'TCP',
        username: user.username, password,
        multiplexing: 'MULTIPLEXING_HIGH'
      },
      { type: 'direct', tag: 'direct' },
      { type: 'dns',    tag: 'dns-out' }
    ],
    route: {
      rules: [
        { protocol: 'dns', outbound: 'dns-out' },
        { geoip: 'cn',     outbound: 'direct'  },
        { geosite: 'cn',   outbound: 'direct'  }
      ],
      final: 'select',
      auto_detect_interface: true
    }
  };
  const filename = `universal-${user.username}-${cfg.domain}.json`;
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.setHeader('Content-Type', 'application/json');
  res.json(universalCfg);
});

// Back-compat aliases
app.get('/api/users/:id/naive-link', requireAuth, (req, res) => {
  const query = req.url.includes('?') ? req.url.slice(req.url.indexOf('?')) : '';
  res.redirect(307, `${PANEL_BASE_PATH}/api/users/${req.params.id}/config/naive${query}`);
});
app.get('/api/users/:id/mieru-config', requireAuth, (req, res) => {
  const query = req.url.includes('?') ? req.url.slice(req.url.indexOf('?')) : '';
  res.redirect(307, `${PANEL_BASE_PATH}/api/users/${req.params.id}/config/mieru${query}`);
});
app.get('/api/users/:id/universal-config', requireAuth, (req, res) => {
  const query = req.url.includes('?') ? req.url.slice(req.url.indexOf('?')) : '';
  res.redirect(307, `${PANEL_BASE_PATH}/api/users/${req.params.id}/config/universal${query}`);
});

// ── Monitoring — /api/status ──────────────────────────────────────────────────
app.get('/api/status', requireAuth, async (req, res) => {
  try {
    const [cpu, mem, disk, osInfo] = await Promise.all([
      si.currentLoad(), si.mem(), si.fsSize(), si.osInfo()
    ]);
    const exec_ = (cmd, args) => { try { return execFileSync(cmd, args, { timeout: 3000 }).toString().trim(); } catch { return ''; } };

    // v1.2.3: check caddy-naive service (not legacy naive)
    const caddyActive  = exec_('systemctl', ['is-active', 'caddy-naive']) === 'active';
    const caddyVersion = exec_(resolvedCaddyBin, ['version']) ||
                         exec_(resolvedCaddyBin, ['--version']);

    res.json({
      services: {
        naive: {   // kept as 'naive' key for front-end compatibility
          active:  caddyActive,
          version: caddyVersion
        },
        mieru: {
        active:  exec_('systemctl', ['is-active', 'mita']) === 'active',
        version: exec_('mita', ['version'])
      },
        panel: { active: true }
      },
      system: {
        cpuPercent:  Math.round(cpu.currentLoad),
        ramUsedMB:   Math.round((mem.total - mem.available) / 1048576),
        ramTotalMB:  Math.round(mem.total / 1048576),
        diskUsedGB:  disk.length ? Math.round(disk[0].used / 1073741824) : 0,
        diskTotalGB: disk.length ? Math.round(disk[0].size / 1073741824) : 0,
        uptime: Math.floor(process.uptime()),
        os:   osInfo.distro + ' ' + osInfo.release,
        arch: osInfo.arch
      },
      panel:    { userCount: getAllUsers().length, version: cfg.version || '1.2.6' },
      domain:   cfg.domain,
      serverIp: cfg.serverIp,
      language: cfg.language || 'ru'
    });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

// User traffic stats
app.get('/api/stats/users', requireAuth, (req, res) => {
  const exec_ = (cmd, args) => { try { return execFileSync(cmd, args, { timeout: 8000 }).toString(); } catch { return ''; } };
  // Bug 78: the real mieru server command is `mita get users` (NOT the
  //   non-existent `mita describe users`, which always returned '' → traffic 0).
  //   Output is a table: User  LastActive  1DayDownload  1DayUpload  30DaysDownload  30DaysUpload
  const raw   = exec_('mita', ['get', 'users']);
  const live  = parseMitaUsers(raw);
  const users = getAllUsers().map(u => {
    const s = live.find(x => x.username === u.username) || {};
    return {
      username:   u.username,
      email:      u.email,
      expiry:     u.expiry,
      protocols:  JSON.parse(u.protocols || '[]'),
      quotaMB:    u.quotaMB,
      usedMB:     (s.usedMB != null ? s.usedMB : (u.usedMB || 0)),
      uploadMB:   s.uploadMB   || 0,
      downloadMB: s.downloadMB || 0,
      // Prefer the live LastActive reported by mita; fall back to stored value.
      lastSeen:   s.lastSeen || u.lastSeen
    };
  });
  res.json(users);
});

// Bug 78: parse the `mita get users` table.
//   User  LastActive            1DayDownload  1DayUpload  30DaysDownload  30DaysUpload
//   abcd  2025-04-23T01:02:03Z  938.1MiB      12.9MiB     4.0GiB          31.8MiB
//   "used" = 30-day download + 30-day upload (best per-key cumulative metric mita exposes).
//   Sizes use binary IEC units (B / KiB / MiB / GiB / TiB) and may also appear as KB/MB/GB.
function parseMitaUsers(raw) {
  const users = [];
  if (!raw) return users;
  const sizeRe = /^([\d.]+)\s*([KMGT]?i?B)$/i;
  for (const rawLine of raw.split('\n')) {
    const line = rawLine.trim();
    if (!line) continue;
    // skip header / separator rows
    if (/^user\b/i.test(line) || /^[-=\s]+$/.test(line)) continue;
    const cols = line.split(/\s+/);
    if (cols.length < 6) continue;
    const username = cols[0];
    const lastActive = cols[1];
    // last 4 columns are the size figures
    const sizeCols = cols.slice(-4);
    const vals = sizeCols.map(c => {
      const m = c.match(sizeRe);
      return m ? toMB(parseFloat(m[1]), m[2]) : null;
    });
    if (vals.some(v => v === null)) continue; // not a data row
    const [d1, u1, d30, u30] = vals;
    void d1; void u1;
    const downloadMB = d30;
    const uploadMB   = u30;
    users.push({
      username,
      uploadMB,
      downloadMB,
      usedMB:   uploadMB + downloadMB,
      lastSeen: /^\d{4}-\d{2}-\d{2}T/.test(lastActive) ? lastActive : null
    });
  }
  return users;
}
// Convert a size value to MB. Accepts both IEC (KiB/MiB/GiB/TiB) and
//   decimal-ish (KB/MB/GB/TB) unit spellings; bare "B" → bytes.
function toMB(v, unit) {
  switch ((unit || '').toUpperCase()) {
    case 'B':                return v / 1048576;
    case 'KB': case 'KIB':   return v / 1024;
    case 'GB': case 'GIB':   return v * 1024;
    case 'TB': case 'TIB':   return v * 1048576;
    default:                 return v; // MB / MiB
  }
}

// ── Logs API ──────────────────────────────────────────────────────────────────
app.get('/api/logs/:service', requireAuth, (req, res) => {
  const { service } = req.params;
  const lines = Math.min(parseInt(req.query.lines || '100', 10), 1000);
  try {
    let logs = '';
    switch (service) {
      // v1.2.3: caddy-naive logs (supports legacy 'naive' and 'caddy' aliases)
      case 'naive':
      case 'caddy':
        try {
          logs = execFileSync('journalctl', ['-u', 'caddy-naive', '-n', String(lines), '--no-pager'], { timeout: 6000 }).toString();
        } catch {
          logs = fs.existsSync(LOG_CADDY)
            ? execFileSync('tail', ['-n', String(lines), LOG_CADDY], { timeout: 6000 }).toString()
            : '';
        }
        break;
      case 'mieru':
        try {
          logs = execFileSync('journalctl', ['-u', 'mita', '-n', String(lines), '--no-pager'], { timeout: 6000 }).toString();
        } catch {
          logs = execFileSync('mita', ['describe', 'log'], { timeout: 6000 }).toString();
        }
        break;
      case 'panel':
        logs = fs.existsSync(LOG_PANEL)
          ? execFileSync('tail', ['-n', String(lines), LOG_PANEL], { timeout: 6000 }).toString()
          : '';
        break;
      default:
        return res.status(400).json({ error: 'Unknown service' });
    }
    res.json({ logs: logs || '(no logs available)' });
  } catch {
    res.json({ logs: '(no logs available)' });
  }
});

// ── Diagnostics ───────────────────────────────────────────────────────────────
app.get('/api/diagnostics', requireAuth, async (_req, res) => {
  const exec_ = (cmd, args, timeout = 4000) => {
    try { return execFileSync(cmd, args, { timeout }).toString().trim(); } catch { return ''; }
  };

  const chkPort = p => {
    try {
      return execFileSync('ss', ['-tlnup'], { timeout: 3000 }).toString().includes(`:${p}`);
    } catch { return false; }
  };

  // v1.2.3: caddy-naive version check (replaces naive --version)
  let caddyVersionOk = false, caddyVersionStr = '';
  try {
    caddyVersionStr = execFileSync(resolvedCaddyBin, ['version'], { timeout: 6000 }).toString().trim() ||
                     execFileSync(resolvedCaddyBin, ['--version'], { timeout: 6000 }).toString().trim();
    caddyVersionOk  = caddyVersionStr.length > 0;
  } catch (e) { caddyVersionStr = e.message; }

  const mieruPortsListening = [];
  for (const p of [cfg.mieruPortStart, cfg.mieruPortEnd]) {
    if (p && chkPort(p)) mieruPortsListening.push(p);
  }

  res.json({
    ports: {
      naive:       chkPort(cfg.naivePort),
      mieru:       chkPort(cfg.mieruPortStart),
      mieruPorts:  mieruPortsListening
    },
    naiveVersionOk:    caddyVersionOk,
    naiveVersion:      caddyVersionStr,    // kept as 'naiveVersion' for front-end compat
    naiveConfigExists: fs.existsSync(resolvedCaddyFile),
    htpasswdExists:    false,              // htpasswd removed in v1.2.3 (users in Caddyfile)
    htpasswdUsers:     0,
    caddyfileExists:   fs.existsSync(resolvedCaddyFile),
    caddyfileUsers:    (() => {
      if (!fs.existsSync(resolvedCaddyFile)) return 0;
      const content = fs.readFileSync(resolvedCaddyFile, 'utf8');
      // Bug 23: directive is now "basic_auth" (underscore), not "basicauth"
      return (content.match(/^\s*basic_auth\s+\S+\s+\S+/gm) || []).length;
    })(),
    mitaStatus:   exec_('mita', ['status']),
    mitaConfig:   exec_('mita', ['describe', 'config']),
    timeSynced:   exec_('timedatectl', ['status']).includes('synchronized: yes'),
    mitaStateFile: resolvedMitaFile,
    probeSecretSet: !!(cfg.probeSecret),
    probeMode: (cfg.probeMode || (cfg.probeSecret ? 'secret' : 'bare'))
  });
});

// ── Service control ───────────────────────────────────────────────────────────
app.get('/api/audit', requireAuth, (req, res) => {
  const limit = Math.min(Math.max(parseInt(req.query.limit || '100', 10) || 100, 1), 500);
  const rows = db
    ? db.prepare('SELECT id, ts, actor, action, details FROM audit_log ORDER BY id DESC LIMIT ?').all(limit).map(row => ({
        ...row,
        details: (() => { try { return JSON.parse(row.details || '{}'); } catch { return {}; } })()
      }))
    : [];
  res.json({ rows, limit });
});

app.post('/api/service/:name/:action', requireAuth, (req, res) => {
  const { name, action } = req.params;
  // Map legacy 'naive' name to 'caddy-naive'; keep 'mita' as-is
  const svcMap = { 'naive': 'caddy-naive', 'caddy-naive': 'caddy-naive', 'mita': 'mita' };
  const svcName = svcMap[name];
  if (!svcName)
    return res.status(400).json({ error: 'Unknown service (valid: naive/caddy-naive, mita)' });
  if (!['start','stop','restart','reload'].includes(action))
    return res.status(400).json({ error: 'Unknown action' });
  try {
    execFileSync('systemctl', [action, svcName], { timeout: 15000 });
    audit('service:control', { service: svcName, action }, req.session.username);
    res.json({ ok: true, service: svcName, action });
  } catch (e) { res.status(500).json({ error: e.stdout?.toString() || e.message }); }
});

// ── WebSocket — real-time metrics ─────────────────────────────────────────────
const wss = new WebSocketServer({ noServer: true });
server.on('upgrade', (req, socket, head) => {
  let pathname = '';
  try {
    pathname = new URL(req.url, 'http://127.0.0.1').pathname.replace(/\/+$/g, '') || '/';
  } catch {
    socket.destroy();
    return;
  }
  const panelWsPath = `${PANEL_BASE_PATH}/ws`;
  if (pathname !== '/ws' && pathname !== panelWsPath) {
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, ws => {
    wss.emit('connection', ws, req);
  });
});
wss.on('connection', ws => {
  const exec_ = (cmd, args) => { try { return execFileSync(cmd, args, { timeout: 2000 }).toString().trim(); } catch { return ''; } };
  let iv;
  const push = async () => {
    if (ws.readyState !== ws.OPEN) { clearInterval(iv); return; }
    try {
      const [cpu, mem] = await Promise.all([si.currentLoad(), si.mem()]);
      ws.send(JSON.stringify({
        type:       'metrics',
        ts:         Date.now(),
        cpu:        Math.round(cpu.currentLoad),
        ramUsedMB:  Math.round((mem.total - mem.available) / 1048576),
        ramTotalMB: Math.round(mem.total / 1048576),
        // v1.2.3: check caddy-naive service
        naive:      exec_('systemctl', ['is-active', 'caddy-naive']) === 'active',
        mieru:      exec_('systemctl', ['is-active', 'mita']) === 'active'
      }));
    } catch {}
  };
  iv = setInterval(push, 5000);
  push();
  ws.on('message', d => { try { const m = JSON.parse(d); if (m.type==='ping') ws.send(JSON.stringify({type:'pong'})); } catch {} });
  ws.on('close',  () => clearInterval(iv));
  ws.on('error',  () => clearInterval(iv));
});

// ── Expiry cron — every 5 min ─────────────────────────────────────────────────
cron.schedule('*/5 * * * *', () => {
  const now = new Date().toISOString();
  let changed = false;
  getAllUsers().forEach(u => {
    if (u.expiry && u.expiry < now) {
      console.log('[CRON] Removing expired user:', u.username);
      deleteUser(u.id); changed = true;
    }
  });
  if (changed) {
    try {
      const content = buildCaddyfile(cfg, getAllUsers());
      writeCaddyfileAtomic(content);
      reloadCaddy();
    } catch {}
    try { applyMitaConfig(); } catch {}
  }
});

// ── Traffic snapshot cron — every 60 s ───────────────────────────────────────
cron.schedule('* * * * *', () => {
  if (!db) return;
  try {
    // Bug 78: use `mita get users` (the real command); `mita describe users`
    //   does not exist and always produced empty output.
    const raw  = execFileSync('mita', ['get', 'users'], { timeout: 5000 }).toString();
    const live = parseMitaUsers(raw);
    if (!live.length) return;
    const ts   = new Date().toISOString();
    const ins  = db.prepare('INSERT INTO traffic_snapshots (username,uploadMB,downloadMB,ts) VALUES (?,?,?,?)');
    live.forEach(s => ins.run(s.username, s.uploadMB, s.downloadMB, ts));
    live.forEach(s => {
      const u = getUserByUsername(s.username);
      if (u) upsertUser({ ...u, usedMB: s.usedMB, lastSeen: s.lastSeen || ts, updatedAt: ts });
    });
  } catch {}
});

// ── SPA catch-all ─────────────────────────────────────────────────────────────
app.get('*', (_req, res) => res.sendFile(path.join(__dirname, '../public/index.html')));

app.use((err, req, res, next) => {
  console.error('[HTTP]', err);
  if (res.headersSent) return next(err);
  if (req.path.startsWith('/api/'))
    return res.status(500).json({ error: 'Internal server error' });
  res.status(500).type('text').send('Internal server error');
});

// ── Start ─────────────────────────────────────────────────────────────────────
const HOST = process.env.PANEL_HOST || cfg.panelHost || '127.0.0.1';
const PORT = parseInt(process.env.PANEL_PORT || String(cfg.panelPort || 3000), 10);

server.listen(PORT, HOST, () => {
  const lines = [
    '',
    '  ██████╗  ██╗ ██╗  ██╗ ██╗  ██╗ ██╗  ██╗',
    '  ██╔══██╗ ██║ ╚██╗██╔╝ ╚██╗██╔╝ ╚██╗██╔╝',
    '  ██████╔╝ ██║  ╚███╔╝   ╚███╔╝   ╚███╔╝ ',
    '  ██╔══██╗ ██║  ██╔██╗   ██╔██╗   ██╔██╗ ',
    '  ██║  ██║ ██║ ██╔╝ ██╗ ██╔╝ ██╗ ██╔╝ ██╗',
    '  ╚═╝  ╚═╝ ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝  ╚═╝',
    '',
    `  Panel Naive + Mieru v${cfg.version || '1.2.6'} by RIXXX  (Caddy-forwardproxy-naive)`,
    `  http://${HOST}:${PORT}/`,
    HOST === '127.0.0.1' ? `  ⚠  SSH-only: ssh -L 3000:127.0.0.1:3000 root@<server>` : '',
    ''
  ];
  lines.forEach(l => console.log(l));
});

module.exports = app;
