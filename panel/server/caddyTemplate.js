'use strict';
/**
 * caddyTemplate.js - canonical Caddyfile renderer v1.2.6
 *
 * Single source of truth used by:
 *   - panel/server/index.js -> buildCaddyfile()
 *   - update.sh             -> node -e "require('./caddyTemplate').render(cfg, users)"
 *   - install.sh            -> node -e "require('./caddyTemplate').render(cfg, [])"
 *
 * Bug 23: forward_proxy uses basic_auth (underscore) as the per-user directive.
 * Bug 28: TLS is handled by Caddy's automatic HTTPS.
 * Bug 29: forward_proxy directive order is enforced.
 * Bug 30: forward_proxy is evaluated before file_server.
 * Bug 34: placeholder auth is emitted only when no real users exist.
 * Bug 38: log rotation keeps logs for 720h.
 * Bug 21: global log block only.
 */

const crypto = require('crypto');

function normalizePanelPath(raw) {
  let s = String(raw || '').trim();
  if (!s || s === '/') return '/admin';
  if (!s.startsWith('/')) s = '/' + s;
  s = s.replace(/\/+$/g, '');
  s = s.replace(/[^a-zA-Z0-9/_-]/g, '');
  if (!s || s === '/') return '/admin';
  return s;
}

function normalizeUpstream(raw) {
  let s = String(raw || '').trim();
  if (!s) return '';
  s = s.replace(/^[a-z][a-z0-9.+-]*\+(?=https?:\/\/)/i, '');
  s = s.replace(/^http:\/\//i, 'https://');
  if (!/^https:\/\//i.test(s)) s = 'https://' + s;
  return s;
}

function render(cfg, naiveUsers) {
  const email = (cfg.adminEmail || '').trim();
  const domain = (cfg.domain || 'localhost').trim();
  const port = cfg.naivePort || 443;
  const panelPort = cfg.panelPort || 3000;
  const panelPath = normalizePanelPath(cfg.panelPath || '/admin');
  const exposePanel = cfg.exposePanel === true || cfg.exposePanel === 'true';
  const fakeSite = (cfg.fakeSiteDir || '/var/www/fake-site').trim();
  const probeSecret = (cfg.probeSecret || '').trim();
  const logFile = (cfg.logFile || '/var/log/caddy-naive/access.log').trim();

  let authLines;
  if (naiveUsers && naiveUsers.length > 0) {
    authLines = naiveUsers.map(u => `    basic_auth ${u.username} ${u.password}`).join('\n');
  } else {
    const rnd = crypto.randomBytes(20).toString('hex');
    authLines = `    basic_auth _placeholder_${rnd.slice(0, 16)} _disabled_${rnd.slice(16)}`;
  }

  let probeMode = String(cfg.probeMode || '').trim().toLowerCase();
  if (!probeMode) probeMode = probeSecret ? 'secret' : 'bare';

  let probeLine;
  if (probeMode === 'off') {
    probeLine = '';
  } else if (probeMode === 'secret' && probeSecret) {
    probeLine = `\n    probe_resistance ${probeSecret}`;
  } else {
    probeLine = '\n    probe_resistance';
  }

  const upstreamUrl = normalizeUpstream(cfg.upstream || '');
  const upstreamLine = upstreamUrl ? `\n    upstream ${upstreamUrl}` : '';
  const panelBlock = exposePanel
    ? `\n\n  handle ${panelPath}* {\n    reverse_proxy 127.0.0.1:${panelPort}\n  }`
    : '';

return `{
  order handle before forward_proxy
  order forward_proxy before file_server
  servers {
    protocols h1 h2
  }
  email ${email}
  admin off
  log {
    output file ${logFile} {
      roll_size 50mb
      roll_keep_for 720h
    }
    format json
  }
}

:80 {
  redir https://{host}{uri} permanent
}

${domain} {
  ${panelBlock}
  forward_proxy {
${authLines}
    hide_ip
    hide_via${probeLine}${upstreamLine}
  }
  file_server {
    root ${fakeSite}
  }
}
`;
}

module.exports = { render };
