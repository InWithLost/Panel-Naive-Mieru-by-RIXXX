# Changelog — Panel Naive + Mieru by RIXXX

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).  
Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v1.2.6] — 2026-06-02

### Bug 94 (`cascade_mieru.sh`) — systemd restart-loop deadlock (mieru ↔ redsocks)

`redsocks.service.d/cascade.conf` had `Requires=mieru.service` while
`mieru.service` had `ExecStartPost=systemctl restart redsocks`. That is a
**circular start dependency**: starting mieru triggers a redsocks (re)start, but
redsocks hard-requires mieru to be fully up → `ExecStartPost` times out and both
units flap in a restart loop, so the relay never reaches a stable state and the
client handshake never completes. (Operators worked around it by deleting
`cascade.conf`.)

Fix:
- drop-in now uses a **soft** ordering: `After=mieru.service` + `Wants=mieru.service`
  (no hard `Requires=`).
- `ExecStartPost=-/bin/systemctl --no-block restart redsocks` — `-` makes a
  non-zero exit non-fatal and `--no-block` returns immediately, so the post-start
  hook can never time out or deadlock.

### Bug 95 (`cascade_mieru.sh`, `panel`) — Mieru cascade handshake failed (config parity)

**Symptom (RIXXX, 2-node stand DE entry → FI exit, both 3.33.0):** Mieru *direct*
works and Naive *cascade* works, but the **Mieru cascade** times out (curl
EXIT=97). On the exit (mita) `NewSession=0` / `NewSessionDecrypted=0` — bytes
arrive but no session is recognised. Crucially, a **localhost self-test on the
exit itself** (mieru-client → 127.0.0.1 → its own mita) *also* failed, which
rules out network/firewall/routing and pins the fault to the client↔server
config/handshake.

Diagnosis (checked against the official mieru 3.33 docs):
- The mieru session key is derived from **username + password + system time**
  (`docs/server-install.md`: *"The server can decrypt and respond only if the
  client and server have the same key… the system time of the client and the
  server must be in sync."*). A username/password mismatch **or** a clock skew →
  the server can't decrypt → `NewSession`/`NewSessionDecrypted` stay 0 and traffic
  is silently dropped. This matches the symptom exactly.
- The cascade client-config generator (`write_mieru_client_config`) carried a
  **wrong** comment ("client config MUST NOT contain mtu") and omitted `mtu` and
  `multiplexing`. Per `docs/client-install.md`, `mtu`, `multiplexing` and
  `handshakeMode` are valid fields that live **inside each `profile`**, and `mtu`
  *"must be the same as proxy server"* (default 1400, valid 1280–1400).
- Two of RIXXX's three hypotheses were **refuted by the docs** (recorded so we
  don't chase them again):
  - **Traffic pattern need NOT match.** `docs/traffic-pattern.md`: *"Traffic
    patterns can be configured independently on the client and server. The client
    and server do not need to use the same traffic pattern settings."* The
    `NONCE_TYPE_PRINTABLE_SUBSET 12/12` the exit reported is just the server's
    *implicit* pattern; the client does not need to replicate it. (So we do **not**
    inject a traffic pattern into the client config.)
  - **MTU is a UDP-only payload bound** (`docs/server-install.md` point 5); the
    cascade is TCP-only, and both ends already defaulted to 1400 — so MTU alone
    was not the breaker. We still emit `mtu` explicitly for guaranteed parity.
  - **Password/hash:** `mita reload` *does* pick up `users`/password changes
    (one of the two reload-safe fields), so a hash that "didn't change" just means
    the password was already correct — not a bug.

Fix (make the cascade correct + diagnosable out of the box):
- `write_mieru_client_config` now emits `mtu`, `multiplexing.level` and
  `handshakeMode` **inside the profile** (schema-correct), with `mtu` matching the
  exit (new `--exit-mtu`, panel passes `cascadeMieru.mtu` / `cfg.mtu`, clamped
  1280–1400) and `multiplexing` defaulting to `MULTIPLEXING_LOW` (`--exit-mux`).
- `do_setup` enables NTP (`timedatectl set-ntp true`) and warns if the entry clock
  isn't synced; it no longer swallows `mieru apply config` errors (an invalid/
  unknown field is now printed, passwords redacted).
- `do_status` gained **handshake diagnostics**: `mieru test`, a client-profile
  sanity line (user/host/ports/mtu/mux, no secrets), and an entry-clock / NTP
  check with remediation hint.
- Panel: `cascadeMieru.mtu` added to the config schema, the `GET`/`POST`
  `/api/settings/cascade` payloads, and the `runCascadeMieru('setup')` argv.

### Bug 88 (`install.sh`) — install aborted with `line 665: port: No such file or directory`

Many testers hit this on the final stage of a fresh install. The inline
Caddyfile fallback assigns a multi-line **double-quoted** shell string
(`caddyfile_content="…"`), and one comment line inside it contained an
**unescaped** double quote plus angle brackets:
```
# Bug 83: match the known-good reference server (":<port>, <domain>" listener +
```
Inside a `"…"` assignment the stray `"` *closed* the string, so bash then parsed
`:<port>` as a redirection from a file named `port` →
`line 665: port: No such file or directory`, and the generated Caddyfile was
truncated. (The users' workaround — deleting the `# Bug 83` line and removing the
comma — worked only because it deleted the poisoned comment, not because of the
comma.)

Fix: rewrite the comment with no double-quote / `<` / `>` characters. The
site-address line `:${NAIVE_PORT}, ${DOMAIN} {` (the catch-all `:443` **plus** the
domain, Bug 83 layout) is kept intact — it is valid Caddy and not the cause.

### Bug 90 (`panel`, `install.sh`) — Caddyfile written `root:root` is unreadable by `User=caddy`

`caddy-naive.service` runs as `User=caddy/Group=caddy`, but the panel wrote
`/etc/caddy-naive/Caddyfile` as `root:root 640`. The caddy user cannot read it →
`open …/Caddyfile: permission denied` → crash loop → systemd blocks it with
*"Start request repeated too quickly"*.

Fix: every Caddyfile write now hands ownership to **root:caddy** and keeps the
config dir traversable by the group:
- `panel/server/index.js` `writeCaddyfileAtomic()` calls a new `fixCaddyPerms()`
  (dir `root:caddy 750`, Caddyfile + `probe_secret` `root:caddy 640`).
- `install.sh` `write_caddyfile()` adds `chown root:caddy` after the `chmod 640`
  (in addition to `start_services()`'s existing Bug 79 dir fixup).

### Bug 91 (`panel`, `update.sh`) — `reload` silently kept the OLD config and masked failures

The panel applied config via `systemctl reload` (kill -USR1). A graceful reload
**silently keeps the in-memory config loaded at start** when the new config can't
be read (e.g. Bug 90). Everything *looked* healthy — `caddy validate` Valid,
`systemctl status` active, logs *"Reloaded"*, even a direct
`curl -x https://u:p@exit:443` returned the exit IP — yet the running process
never loaded the new `upstream`, so the client egressed from the **Entry** node.
It only surfaced on a full `restart` (which then failed with the Bug 90 perms
error).

Fix: after writing the Caddyfile, always do a **full `systemctl restart`**, then
verify `systemctl is-active`; on failure surface the real `journalctl` error.
- `panel/server/index.js`: new `applyCaddyConfig()` (restart + is-active +
  `collectCaddyError()`); `reloadCaddy()`/`restartCaddy()` now delegate to it.
  `applyAllConfigs()` and the cascade POST return `caddyError` to the UI.
- `update.sh`: the `reload || restart` block replaced with `reset-failed` +
  `restart` + `is-active` check.

### Bug 89 (`panel`) — new naive key didn't activate until `update.sh --force`

Creating a naive key in the panel didn't work in Karing until the operator ran
`sudo bash update.sh --force -y`. Root cause was the combination of Bug 90
(file written `root:root`) and Bug 91 (`reload` silently failing); `update.sh`
"fixed" it only because it ran `fix_caddy_perms` (root:caddy) + restart. With the
Bug 90 chown and the Bug 91 restart+verify now in the per-CRUD `applyAllConfigs()`
path, a new key activates immediately — no `--force` needed.

### Bug 92 (`panel`) — `upstream naive+https://…` rejected by `forward_proxy`

Users paste the subscription-format exit key as-is
(`naive+https://user:pass@host:443`). The panel wrote it verbatim, and
`caddy validate` failed:
> forward_proxy: insecure schemes are only allowed to localhost upstreams

`forward_proxy upstream` only accepts a clean `https://` URL. Fix: a shared
`normalizeUpstream()` strips a leading `naive+` (any `<scheme>+` wrapper), upgrades
`http://`→`https://`, and assumes `https://` when no scheme is given. Applied in
`panel/server/index.js` (store + both build paths) and in
`panel/server/caddyTemplate.js` `render()` (single source of truth, so
install.sh/update.sh inherit it).

### Bug 93 (`panel`, UX) — "Проверить статус" didn't diagnose the Naive cascade

The status button only ran the Mieru (Variant B) diagnostics, so a Naive-only
cascade always showed `configured: 0 / inactive` — misleading. Fix: a new
`naiveCascadeStatusText()` block reports, with credentials redacted:
`upstream` present in the live Caddyfile, `caddy-naive validate`,
`systemctl is-active caddy-naive`, and the **egress IP measured through the naive
upstream** (`curl -x https://u:p@exit:443 https://api.ipify.org`). The
`/api/settings/cascade/status` response now contains both the **NAIVE CASCADE**
and **MIERU CASCADE** sections (no UI change needed — it renders the text).

### Bug 87 (`panel`) — subscription JSON used `type:"http"` for naive (should be `type:"naive"`)

Live testing: from the universal subscription the **mieru** outbound worked but
the **naive** one did not, while the manual `naive+https://…` key worked fine.
The user also noticed Karing labelled the subscription's outbound `naive-out`
but the manual key `jazz.magniysovetuy.site:443` — a tell that the two were
*different outbound types*.

Root cause: `/api/users/:id/config/universal` emitted the naive outbound as
```json
{ "type": "http", "tag": "naive-out", … }
```
A plain `type:http` is an ordinary HTTP-CONNECT proxy. It performs TLS + CONNECT
but lacks NaiveProxy's Cronet/Chromium traffic shaping (HTTP/2 framing, padding,
header order) that the `caddy-forwardproxy-naive` server expects — so the server
never tunnels its traffic. The manual key parses to `type:naive` (Cronet), which
is why it worked.

Fix: emit the sing-box NaiveProxy outbound per the official spec
(<https://sing-box.sagernet.org/configuration/outbound/naive/>):
```json
{ "type": "naive", "tag": "naive-out",
  "server": "<domain>", "server_port": <port>,
  "username": "<u>", "password": "<p>",
  "quic": false,
  "tls": { "enabled": true, "server_name": "<domain>" } }
```
`quic:false` matches the server's `servers { protocols h1 h2 }` (Bug 80 — HTTP/3
disabled); `tls` carries only `server_name` (the naive outbound ignores other TLS
fields). Karing ships the `with_naive_outbound` build (libcronet), so
`type:naive` works there exactly like the manual key.

### Bug 86 (`update.sh`) — `rebuild_caddyfile_direct` silently wrote nothing (inline `node -e` bash-quoting)

Even after Bug 84/85 let `--repair` reach the rebuild, the live
`/etc/caddy-naive/Caddyfile` stayed OLD (mtime never changed) while the run
reported `Caddyfile rebuilt ✓`. Decisive evidence: the `[Caddyfile] rebuilt with
N user(s)` line that the node script prints **never appeared** in `--repair`
output (the mita equivalent `[mita-state] wrote N user(s)` did), and running the
*exact same logic* from a standalone `.js` file wrote the correct Bug 83
Caddyfile instantly (`WROTE 1540 bytes … NOW NEW ✅`).

Root cause: the rebuild ran as a giant **inline `node -e "<script>"`** embedded in
a **double-quoted bash string**. Bash pre-processed the whole blob —
`$DB_PATH`/`$PANEL_CONFIG`/`$CADDY_FILE` were string-substituted and any stray
`$`, backtick or `\` was subject to bash quoting. On the live server this
produced a node program that exited 0 **without writing the file**, after which
`caddy validate` validated the STALE Caddyfile → false "rebuilt ✓".

Fix: write the rebuild script with a **quoted heredoc** (`<<'NODE_EOF'`, zero bash
expansion), pass every path via `process.env` (`RB_DB_PATH`, `RB_PANEL_CONFIG`,
`RB_CADDY_FILE`, `RB_CADDY_CFGDIR`, `RB_TEMPLATE_JS`, `RB_FAKE_SITE`), and run
`node "$rebuild_js"`. A real failure now exits non-zero and is caught
(`log_warn` + `return 1`) instead of silently no-op'ing.

* **Bug 86b:** the temp `.js` is written **inside `$PANEL_DIR`** (not `/tmp`),
  because node resolves `require('better-sqlite3')` relative to the *script
  file's* directory, not the cwd — a `/tmp/*.js` would look in
  `/tmp/node_modules` and fail (re-triggering the Bug 82 "Cannot find module").

Verified end-to-end with a throwaway SQLite DB + config: the script writes the
exact reference layout (`:443, <domain> { tls <email>; forward_proxy {…}; …}`,
no `route{}`, both users, `protocols h1 h2`, bare `probe_resistance`).

### Bug 85 (`update.sh`) — `--repair` (and `--status`/`--expose`/`--ssh-only`) exited 1 SILENTLY before doing anything

Live testing: `sudo bash update.sh --repair -y` returned `EXIT=1` with **zero
output** and the Caddyfile was never rebuilt (still the old Bug 83-era layout),
so Bug 84's direct rebuild never even ran.

Root cause — the classic Bug 77 `set -e` trap: the **last** statement of
`parse_args` was
```bash
[[ -z "$MODE" ]] && MODE="update"
```
When a mode flag was supplied (e.g. `--repair` → `MODE="repair"`), the test
`[[ -z "repair" ]]` is FALSE, so `parse_args` **returned 1**. In `main()`,
`parse_args "$@"` is a plain command → `set -euo pipefail` aborted the whole
script immediately, and because the failure was a function *return* the `ERR`
trap was skipped → no message at all. This only hit mode flags; a bare update
left `MODE` empty, so the test was TRUE → return 0 → it worked (which is why
`--force -y` always ran but `--repair` never did).

Fix: replace the trailing one-liner with an explicit `if` block and a trailing
`return 0`:
```bash
if [[ -z "$MODE" ]]; then MODE="update"; fi
return 0
```
Now `--repair`/`--status`/`--expose`/`--ssh-only` reach their handlers, and with
Bug 84 `--repair` rebuilds the Caddyfile directly from the on-disk template.

### Bug 84 (`update.sh`) — `--repair` regenerated a STALE Caddyfile via the panel API

After Bug 83 was merged and deployed (the on-disk `caddyTemplate.js` in
`$PANEL_DIR` was confirmed to be the new format, 7346 bytes), the live
`/etc/caddy-naive/Caddyfile` was *still* the old layout (`route {}` wrapper,
domain-only listener) even though the rebuild reported success.

Root cause: `do_repair` POSTed to `/api/services/rebuild-all` **first**, which is
rendered by the **running PM2 panel process** using its *in-memory* `buildCaddyfile()`
from `index.js`. If that process hadn't reloaded the new `index.js` yet, the API
regenerated the OLD Caddyfile format — and the `rebuild_caddyfile_direct` fallback
(which uses the on-disk template, the single source of truth) **never ran** because
the API call "succeeded". So the new template on disk was ignored.

Fix: `do_repair` now **always** calls `rebuild_caddyfile_direct` /
`rebuild_mita_state_direct` directly, dropping the API-first path. The rebuilt
Caddyfile therefore always reflects `$PANEL_DIR/server/caddyTemplate.js` regardless
of whatever code the panel happens to have loaded in memory. (`do_update` already
used the direct rebuild and restarts PM2 with `--update-env`, so it was unaffected.)

### Bug 83 (`panel` + `install.sh` + `update.sh`) — Caddyfile site block to match reference exactly

Live testing: even after Bug 80/81 the naive key still wouldn't connect, while the
user's reference server worked. Side-by-side of both Caddyfiles showed the site
block differed structurally:

* Reference: `:443, poppuri.site { tls <email>; forward_proxy {...}; file_server {...} }`
* Ours:      `jazz.magniysovetuy.site:443 { route { forward_proxy {...} file_server {...} } }`

Three differences fixed so ours is byte-for-byte equivalent to the working server:
1. **Listener** `:<port>, <domain>` (catch-all `:443` **plus** the domain) instead of
   the domain-only `<domain>:<port>`. The catch-all ensures the CONNECT request
   matches this site regardless of how the client sets SNI/Host (the likely cause of
   the key not connecting).
2. **Explicit `tls <email>`** inside the site block (instead of relying solely on the
   global `email` + automatic HTTPS).
3. **Removed the `route { }` wrapper** — `forward_proxy` and `file_server` now sit
   directly in the site block; ordering still comes from the global
   `order forward_proxy before file_server`.

Applied to all four generators: `caddyTemplate.js`, `index.js` inline fallback,
`install.sh`, `update.sh`.

### Bug 82 (`update.sh` + `install.sh`) — `node -e` couldn't find `better-sqlite3`

Live update showed the Caddyfile rebuild crashing with
`Error: Cannot find module 'better-sqlite3'`, so the config was **not** regenerated
(stale Caddyfile kept the old secret + missing protocols block). Cause: the inline
`node -e "…"` scripts run with cwd = the git checkout (`~/Panel-Naive-Mieru-by-RIXXX`),
which has no `node_modules`; the modules live under `$PANEL_DIR`
(`/opt/panel-naive-mieru`). Fix: wrap the DB-reading `node -e` blocks in
`( cd "$PANEL_DIR" && node -e "…" )` so Node resolves `better-sqlite3` and the
template correctly.
- `update.sh`: `rebuild_caddyfile_direct()` and `rebuild_mita_state_direct()`.
- `install.sh`: the `naive_users_json` reader (its silent `try/catch` previously
  meant a `--force` reinstall could quietly drop all naive users).

### Bug 81b (`update.sh`) — migrate existing installs to bare + regenerate on update

Follow-up after live testing: `--force` update did **not** regenerate the Caddyfile
(it only restarted caddy), and existing `config.json` had a `probeSecret` but no
`probeMode`, so back-compat kept the old `probe_resistance <secret>` line and the
`servers { protocols h1 h2 }` block never appeared. Two fixes:

1. **`migrate_config()`** — on `update`/`repair`, when `probeMode` is missing it is
   set to `'bare'` (matching the reference server). The stored `probeSecret` is kept
   so the user can switch back to `secret` from the panel later.
2. **`do_update` now regenerates the Caddyfile** via `rebuild_caddyfile_direct()`
   (caddyTemplate.js) after migration, so the protocols block and bare
   `probe_resistance` take effect on a plain `update.sh --force` without needing
   a separate `--repair`.

### Bug 81 (`panel` + `install.sh` + `update.sh`) — probe_resistance mode (bare/secret/off)

**Naive config parity with a known-good reference server.** The user compared our
generated Caddyfile against a working reference (`poppuri.site`) and found we always
emitted `probe_resistance <secret>`, whereas the reference uses a **bare**
`probe_resistance` (no secret). With a secret, the masquerade site is only reachable
via a special secret domain — bare is simpler and matches the working server.

- New **`probeMode`** config field: `'off' | 'bare' | 'secret'`.
  - `off`    → no `probe_resistance` line at all.
  - `bare`   → bare `probe_resistance` (no secret) — **new default**, matches reference.
  - `secret` → `probe_resistance <secret>` (legacy behaviour; requires a secret domain).
- Back-compat: when `probeMode` is unset it is derived from `probeSecret`
  (non-empty → `secret`, empty → `bare`), so existing installs keep their behaviour.
- `caddyTemplate.js`, `index.js` inline fallback, `install.sh` + `update.sh` inline
  fallbacks all honour `probeMode`.
- Panel UI: Settings → Probe Resistance card now has a **mode selector**; the secret
  input is shown only in `secret` mode. New `POST /api/settings/probe-mode` endpoint;
  `POST /api/settings/probe-secret` now also sets `probeMode='secret'`.
- Status endpoint now returns `probeMode`. Locales (ru/en) updated.

### Bug 80 (`panel` + `install.sh` + `update.sh`) — disable HTTP/3/QUIC (`protocols h1 h2`)

The working reference server pins Caddy to HTTP/1.1 + HTTP/2 via a global
`servers { protocols h1 h2 }` block; our generated config left HTTP/3/QUIC enabled.
NaiveProxy tunnels over HTTP/2 `CONNECT`, and HTTP/3 can break some clients. Added the
block to all four Caddyfile generators (`caddyTemplate.js`, `index.js` inline fallback,
`install.sh`, `update.sh`) so naive matches the known-good reference.

### Bug 79b (`install.sh` + `update.sh`) — caddy-naive perms follow-up

Live-server diagnostics after Bug 79 showed the config **directory** was actually
fine (`drwxr-xr-x root caddy`), but the **Caddyfile itself was owned `root:root`**
(`-rw-r----- root root`) — so the caddy group's read bit was useless and the
service still failed with `permission denied`. Two follow-ups:

1. The real fix is the `chown -R root:caddy` already in `fix_caddy_perms()`; the
   earlier update simply hadn't shipped it yet (stale local clone).
2. **Failure-storm + ordering:** `update_caddy_naive` reinstalled the binary and
   immediately `systemctl start`ed it *before* perms were fixed, tripping the
   5-in-5-min restart limit (`Start request repeated too quickly`), so the later
   `fix_caddy_perms` couldn't recover the service. Fixes:
   - `update_caddy_naive` now calls `fix_caddy_perms` + `systemctl reset-failed`
     **before** starting caddy after a binary reinstall (also re-applies setcap,
     which `install` strips).
   - `do_update` and `install.sh start_services` add `systemctl reset-failed`
     before the (re)start.

### Bug 79 (`install.sh` + `update.sh`) — caddy-naive "Caddyfile: permission denied"

**P1 — Naive shown as disabled in the panel.** On the live server `caddy-naive`
was in a `failed` state, restart-looping with:
```
Error: reading config from file: open /etc/caddy-naive/Caddyfile: permission denied
```

Root cause — a directory-traversal permission bug. The service runs as
`User=caddy`, but the installer set up `/etc/caddy-naive` with
`chgrp caddy + chmod -R g+r + chmod 640 Caddyfile`. That gives the **group** read
on the files, but a **640 directory** (`drw-r-----`) has **no execute (x) bit for
the group**, so the `caddy` user cannot *traverse* the directory to open the file
inside it — hence "permission denied", even though the file's own perms looked OK.

**Fix** (both scripts):
- Own the whole config dir as `root:caddy`.
- Directory → **750** (`rwxr-x---`, group can traverse + list).
- Files → **640** (`rw-r-----`, group can read).
- Order matters: chmod the top dir to 750 **first**, then `find` the contents
  (a 640 dir can't be descended into by `find`). Verified in a sandbox.
- `update.sh` gains a `fix_caddy_perms()` helper, called from
  `rebuild_caddyfile_direct`, `do_repair`, and `do_update` (which now also
  restarts caddy-naive), so existing broken installs self-heal on update.

### Bug 78 (panel) — Monitoring traffic always 0 + selectable Mieru port

**P2 — traffic never updated.** Both `/api/stats/users` and the 60-second traffic
snapshot cron called `mita describe users` — a command that **does not exist** in
mita. It always returned empty output, so `parseMitaUsers` produced `[]` and every
key showed 0 MB regardless of real usage.

Root cause confirmed against the upstream mieru docs (`docs/operation.md`): the
real command is **`mita get users`**, which prints a table:
```
User  LastActive            1DayDownload  1DayUpload  30DaysDownload  30DaysUpload
abcd  2025-04-23T01:02:03Z  938.1MiB      12.9MiB     4.0GiB          31.8MiB
```
(There is also `mita get quotas` for quota progress.)

**Fix**:
- Replaced `mita describe users` → `mita get users` in both call sites.
- Rewrote `parseMitaUsers` to parse the real table: per-user `usedMB` = 30-day
  download + 30-day upload, `lastSeen` from the `LastActive` column.
- Rewrote `toMB` to understand IEC units (`B`/`KiB`/`MiB`/`GiB`/`TiB`) as well as
  the decimal spellings. Covered by a unit test against the documented output.

**P3 — selectable Mieru port in generated configs.** The config generators always
wrote the **range start** (e.g. 2012) into `server_port`. mita listens on the whole
configured range, so any port inside it is valid to dial.

**Fix**:
- `/api/users/:id/config/mieru` and `/config/universal` now accept an optional
  `?port=<n>` query param, validated against `[mieruPortStart, mieruPortEnd]` via
  the new `pickMieruPort()` helper (falls back to the range start when omitted or
  out of range — fully backward compatible).
- Added a "Mieru port" selector to the config-download modal (prefilled with the
  range, empty = range start) plus `config.mieruPort*` locale keys (ru/en).

### Bug 77 (`update.sh`) — **the actual** silent-exit cause: `check_root`/`check_install`

Even after Bug 76's ERR trap, `sudo bash update.sh --force -y` still printed
**nothing** and returned to the prompt (exit 1). A `bash -x` trace pinned it down:
the script died immediately after `check_root` at `[[ 0 -ne 0 ]]`.

Root cause — a classic `set -e` footgun. The one-liner functions were:
```sh
check_root()    { [[ $EUID -ne 0 ]] && die "Run as root"; }
check_install() { [[ ! -f "$PANEL_CONFIG" ]] && die "..."; }
```
On the **happy path** (running as root / panel installed), the `[[ ]]` test is
**false**, the `&&` short-circuits, and the test's exit status `1` becomes the
**function's** return value. When `main` then calls `check_root` as a plain
command, that non-zero return trips `set -e` → the whole script aborts before
any `log_*` runs (and the function-return doesn't reliably fire the ERR trap).

**Fix**: rewrote both as explicit `if` blocks ending in `return 0`. Verified with
`bash -x`: the script now runs end-to-end, copies the panel files, and reports
`Panel updated ✓ (v1.2.6 markers present)`.

### Bug 76 (`update.sh`) — update silently did nothing / skipped panel files

After a clean update, the live panel in `/opt/panel-naive-mieru` still ran the
old code (P3 password prompt present, no `downloadNote`/Bug-75 markers), and
`sudo bash update.sh -y` printed **nothing** and returned to the prompt.

Two root causes:
1. **Silent abort** — `set -euo pipefail` with no ERR trap: any un-handled
   non-zero command (e.g. a hiccup in `npm install --production`, or a `jq`
   parse under command substitution) aborted the whole script with zero output.
2. **"Already up-to-date" lie** — the version file had already been bumped to
   `1.2.6` by an earlier *partial* run that never copied the panel files, so the
   next `-y` run treated it as current and skipped the file sync.

**Fixes**:
- Added an `ERR` trap that prints the failing line + a hint to re-run with
  `--force -y` — no more silent exits.
- `update_panel()` now: falls back to the local `./panel` checkout if `git clone`
  fails, copies **all** files with `cp -a "$src/."`, runs `npm install` as
  **non-fatal**, restarts PM2 with `--update-env`, and **verifies** a v1.2.6
  sentinel (`downloadNote`) actually landed.
- In non-interactive mode (`-y`), an "up-to-date" version no longer skips the
  panel re-sync (the copy is idempotent and cheap).

### Bug 75 (P1, mieru server) — mita stayed IDLE, so the proxy never listened

Server logs showed `mita` running but reporting `app status IDLE`, and
`/var/lib/rixxx-panel/mita-state.json` held the correct port bindings + user — yet
mieru clients couldn't connect. Root cause: when a user is added via the panel,
`applyMitaConfig()` ran `mita apply config` followed by `mita reload`. Per the
upstream docs, **`mita reload` only re-reads the config of an already-RUNNING
server — it does NOT lift the service from IDLE → RUNNING.** Since the installer
intentionally does not start mita while `users[]` is empty (Bug 4), the first
panel-driven config update reloaded an IDLE server that never bound its ports.

**Fix**: `applyMitaConfig()` now checks `mita status`; if RUNNING it `reload`s,
otherwise it `mita start`s (falling back to `systemctl restart mita`). `install.sh`
likewise now issues `mita start` (not just a daemon restart) once the first user
exists, so the proxy actually enters RUNNING and binds 2012–2022.

Verified on the live server: after `mita start`, `mita status` → `RUNNING` and
`mita describe config` showed the user with `hashedPassword`
`2af72f0fee0af51523d57bca1e436aca52b85dd644e2f5e6c76d1bdc1c1129bf`. Confirmed via
the upstream protocol spec (`hashedPassword = SHA256(password || 0x00 ||
username)`) that this hash matches the expected plaintext password — i.e. the
panel stores and applies the correct mieru credential. (The empty `password` field
in `describe config` is expected: mita only keeps the hash.)

### Bug 74 (P1, mieru client config) — generated Mieru config did not connect

Field-tested against a **known-working** Karing/sing-box mieru config from another
server, the panel's generated mieru outbound differed in two ways that break the
client's mieru parser:

- We emitted `multiplex: { enabled: false }` (an object). The working client uses
  the string enum **`multiplexing: "MULTIPLEXING_HIGH"`**. The object form is for
  other protocols' stream-multiplexing and is silently rejected by the mieru
  outbound → no connection. **Fixed** in both `/config/mieru` and the mieru
  outbound of `/config/universal`.
- We sent both a single `server_port` **and** a `server_ports` array. The working
  config sends only a single `server_port`. Dropped the array to match.
- Mieru `server` now prefers the raw server IP (mieru is IP-based, no SNI/TLS),
  and the standalone mieru config now includes the same minimal `dns` block as
  the reference config.

Server-side diagnosis confirmed the VPS itself is healthy: Caddy holds a valid
Let's Encrypt cert (`curl -vI` → HTTP/2 200, verify ok), DNS A-record matches the
server IP, firewall opens 80/443/2012-2022 — so the no-connection issue was the
client config format, not the server.

### UX fixes (`genspark_ai_developer_audit`)

- **P2 — Email is now optional when adding a user.** The TLS certificate is
  obtained at install time via Caddy's ACME (the global `email` directive), not
  per-user, so a per-user email served no purpose. Removed the `required`
  attribute and the `*` from the form, relaxed `validateUserInput()` (an email is
  still format-checked *if* provided), and store `NULL` (not `''`) for empty
  emails. Added a one-time DB migration that rebuilds `users.email` from
  `TEXT NOT NULL UNIQUE` → `TEXT UNIQUE`, so multiple email-less users no longer
  collide on the UNIQUE constraint. Existing emails are preserved.

- **P3 — Removed the password prompt when downloading a client config.** The
  config-download modal previously asked for the user's password even though the
  admin is already authenticated and the server stores the plaintext password.
  The naive link / QR now auto-load on open and all three downloads (naive,
  mieru, universal) use the server's stored-password fallback — no extra input
  required. Removed the `cfg-password` input + note from the modal.

### Audit & cascade hardening (`genspark_ai_developer_audit`)

- **Bug 73 (P0, `install.sh`)** — **install aborted at `write_config_json`** on a
  clean Ubuntu 24.04: the admin password was passed to `node -e` as
  `process.argv[2]`, but `node -e` has no script-path arg so the value lands at
  `argv[1]`. `argv[2]` was `undefined` → `bcrypt.hashSync` threw → the
  `htpasswd` fallback failed too (apache2-utils not installed) → `die`, so
  `config.json` was never written and the panel/PM2 never started (`:3000` dead).
  **Fix**: pass the password via the `RIXXX_ADMIN_PASS` env var and read it from
  `process.env` (also avoids shell-quoting issues with special chars); the
  fallback now installs `apache2-utils` first. Added `install_panel` fallback to
  `$PWD/panel` and wrapped `npm install` in a subshell so the main shell's cwd is
  preserved. Regression checks added to `tests/e2e.sh`.


Pre-test tech-lead audit. The Mieru cascade was re-architected from native `egress`
(Variant A) to the field-tested **Variant B** (redsocks + iptables + mieru-client),
because the Exit node is a full Mieru server (`mita`), not a raw SOCKS5 endpoint.

- **P0 fix** — Mieru native egress SOCKS5 auth field corrected `username` → `user`
  (`app.js`), matching the official `socks5Authentication.{user,password}` schema.
- **P0 fix** — version sync to `1.2.6` across `uninstall.sh`, `tests/e2e.sh`,
  and `install.sh` ARM messages (previously `1.2.5`, would fail the e2e version step).
- **Added `panel/scripts/cascade_mieru.sh`** — orchestrator for Variant B with
  `setup` / `teardown` / `status`. Encapsulates the proven manual guide while
  avoiding its pitfalls: `profiles` (plural), no `mtu` in client config,
  `Type=forking` + `mieru start`, redsocks restarted with mieru via
  `ExecStartPost`, anti-loop `RETURN` for the resolved Exit IP, watchdog that
  restarts only after 3 consecutive failures, **lazy install** of
  `redsocks` + `mieru-client` on first enable, and the **full Exit port range**.
- **Server (`index.js`)** — `POST /api/settings/cascade` now runs
  `cascade_mieru.sh setup/teardown` for the Mieru leg (Naive leg still via
  Caddyfile `upstream`); `buildMitaStateFile()` no longer injects native egress
  when a Variant B exit host is set (legacy egress kept as explicit fallback);
  new `cfg.cascadeMieru { host, portStart, portEnd, user, pass }`; new
  `GET /api/settings/cascade/status`; `/api/config` masks the exit password
  (returns a boolean) so secrets never reach the browser; `runCascadeMieru()`
  uses `execFileSync` (no shell) so credentials are argv-safe.
- **UI** — exit **port range** (start/end) inputs, host/IP + username/password
  relabelled, blank-password-keeps-existing, a **Check status** button and a
  status panel; ru/en i18n keys added.
- **`install.sh`** — new `tune_network()` step finally invokes
  `scripts/sysctl_tune.sh` (BBR + UDP buffers).
- **`uninstall.sh`** — full cascade cleanup (iptables `REDSOCKS` chain,
  `mieru.service`, redsocks + drop-in, `/etc/redsocks.conf`, watchdog + cron,
  shred of client config + state) and an optional redsocks apt-purge prompt.

### Added

- **Cascade / Relay architecture (NaiveProxy + Mieru)** — Settings UI now supports chaining traffic through an intermediate "Exit" node:
  - **NaiveProxy**: `upstream` directive in `caddy-forwardproxy-naive` (`upstream https://user:pass@host:port`) for `client → Entry (RU) → Exit (EU) → internet`.
  - **Mieru**: `egress` property with SOCKS5 outbound proxies in `mita` config (`SOCKS5_PROXY_PROTOCOL` + `socks5Authentication`).
  - New REST API endpoints: `GET /api/settings/cascade`, `POST /api/settings/cascade` (requires auth).
  - New UI card in Settings page (`index.html` + `app.js`): checkbox "Enable cascade", Naive upstream URL input, Mieru exit host/port/user/pass inputs.
  - `caddyTemplate.js` `render(cfg, naiveUsers)` now accepts `upstream` parameter and emits `upstream <url>` inside the `forward_proxy` block.
  - `buildMitaStateFile()` in `index.js` injects `egress` JSON when `cascadeEnabled === true`.
  - Atomic config writes via `.new` + `fs.renameSync()` preserved for both Caddyfile and mita-state.

### Fixed

- **Bug 70 (P0, `install.sh`)**: Removed phantom `log_info "caddy-naive запущен ✓"` in `start_services()` that fired unconditionally even when `caddy-naive` failed to start, masking real startup failures.
- **Bug 71 (P0, `update.sh`)**: `smoke_test()` contained corrupted/garbage bytes and a duplicate function definition, causing syntax errors or unpredictable behaviour during update. Cleaned and deduplicated the function.
- **Bug 72 (P1, `update.sh`)**: `rebuild_caddyfile_direct()` did not pass `upstream` into `tpl.render()`, so cascade changes made via UI were lost on `--repair`. Fixed by threading `cfg.cascadeNaiveUpstream` through the Node one-liner.

### Changed

- `install.sh` version → `1.2.6`; `CURRENT_VERSION="1.2.6"`.
- `update.sh` version → `1.2.6`; `TARGET_VERSION="1.2.6"`.
- `panel/server/caddyTemplate.js` version comment → `v1.2.6`.
- `panel/server/index.js` version comment → `v1.2.6`; `DEFAULT_CONFIG.version` → `1.2.6`; added `cascadeEnabled`, `cascadeNaiveUpstream`, `cascadeMieruEgress` fields.
- `panel/public/index.html` version labels → `v1.2.6` (title, sidebar, topbar, about).
- `panel/public/app.js` version comment → `v1.2.6`; added `changeCascade()` handler, cascade field loading in `loadSettings()`, delegated click mapping for `change-cascade`.
- `panel/public/locales/ru.json` + `en.json` — added cascade translation keys under `settings.*` and `toast.*`.
- `README.md` / `README.en.md` — version badge bumped to `v1.2.6`; added Cascade/Relay architecture section with ASCII diagram and UI instructions.

---

## [v1.2.5] — 2026-05-07 (rev.2 — post-release audit)

### Fixed (P0 — release blockers)

- **Bug 41 (P0, `install.sh`)**: `write_config_json()` ran before `install_panel()`, so `bcryptjs` (from `panel/node_modules`) was not yet available when the admin-password hash was generated via `node -e "require('bcryptjs')"`. **Fix**: `install_panel` is called before `write_config_json` in `main()`.

- **Bug 42 (P0, `install.sh`)**: `/var/log/caddy-naive` was created by `write_caddyfile()` (running as root) before the `caddy` system user existed, leaving it owned by `root`. When Caddy later ran as `caddy`, it could not write the access log. **Fix**: `write_caddyfile()` no longer creates that directory; `start_services()` creates `/var/log/caddy-naive` and `/var/lib/caddy` **after** the `caddy` system user is created, setting `caddy:caddy 755/700` ownership.

- **Bug 43 (P0, `install.sh`)**: Caddy could not store ACME certificates because `/var/lib/caddy` did not exist and `XDG_DATA_HOME` was not set in the systemd unit. **Fix**: `start_services()` creates and chowns `/var/lib/caddy`; `write_caddy_service()` adds `Environment=XDG_DATA_HOME=/var/lib/caddy`, `Environment=XDG_CONFIG_HOME=/var/lib/caddy`, and `ReadWritePaths=/var/log/caddy-naive /etc/caddy-naive /var/lib/caddy` to the unit.

- **Bug 44 (P0, `panel/server/index.js`)**: `buildCaddyfile()` fell back to `passHash` (a bcrypt hash) when `password` was absent, and fed the bcrypt string directly to the Caddyfile. `caddy-forwardproxy-naive` hashes passwords internally and cannot accept a pre-hashed value, causing auth failures. **Fix**: users without a non-empty `password` field are silently skipped with a `console.warn` log line. A placeholder credential is still emitted when the filtered list is empty (Bug 34 behaviour preserved).

### Fixed (P1 — correctness)

- **Bug 45 (P1, `README.md` + `README.en.md`)**: No documentation warned operators about the plaintext-password storage model. `caddy-forwardproxy-naive` requires plaintext passwords at startup (it hashes them internally), so the panel must store them in SQLite. **Fix**: a `🔐 Security Warning` block added to both README files explaining the model, advising `600 root:root` permissions, and recommending against password reuse.

- **Bug 50 (P1, `panel/server/index.js`)**: `reloadCaddy()` used `systemctl reload … || kill -USR1 $(pgrep -x caddy-naive …)` — the `pgrep -x` fallback matched on the exact comm-name which may differ from the binary name, sending SIGUSR1 to the wrong PID or failing silently. **Fix**: `reloadCaddy()` now calls only `systemctl reload caddy-naive`; the broken fallback is removed.

- **Bug 51 (P1, `panel/server/index.js`)**: `buildMitaStateFile()` iterated `cfg.mieruPortStart … cfg.mieruPortEnd` without guarding against `undefined`/`NaN`, causing an infinite loop if the config file was missing or corrupt. **Fix**: `parseInt(...) || 2000` / `|| 2010` safe defaults applied before the loop.

- **Bug 52 (P1, `panel/server/index.js`)**: `POST /api/settings/naive-port` called `restartCaddy()` and returned `{ ok }` based on the function's return value, but `restartCaddy()` returns `false` only on a Node `execSync` exception — not when `systemctl restart` exits 0 but Caddy then dies. **Fix**: after `restartCaddy()`, `systemctl is-active caddy-naive` is checked; on failure the endpoint returns HTTP 500 with an actionable error message.

- **Bug 53 (P1, `panel/server/index.js`)**: `saveConfig()` called `fs.writeFileSync()` directly on the live `config.json` — a process kill mid-write left a truncated/corrupt file. **Fix**: `saveConfig()` writes to `config.json.new` first, then atomically renames to `config.json`.

### Fixed (P2 — lower priority)

- **Bug 55 (P2, `install.sh`)**: `caddy-naive` binary was `chmod 750`, preventing non-root users from running `caddy validate`. **Fix**: `start_services()` uses `chmod 755` (already applied in v1.2.4 code, now formally documented here).

- **Bug 60 (P2, `install.sh`)**: `write_caddyfile()` did not run `caddy fmt`, leaving the Caddyfile with mixed indentation that generated fmt warnings on every service start. **Fix**: `caddy fmt --overwrite "$CADDY_FILE"` is called immediately after the atomic write; errors are logged (non-fatal) to `$INSTALL_LOG`.

- **Bug 62 (P2, `install.sh`)**: `caddy-naive.service` lacked restart-storm protection; repeated ACME failures could hammer Let's Encrypt rate limits. **Fix**: `StartLimitBurst=5`, `StartLimitIntervalSec=300`, `RestartSec=10` added to the unit (already applied in v1.2.4 code; now formally documented).

- **Bug 63 (P2, `panel/server/caddyTemplate.js`)**: `roll_size` value used extra trailing spaces (`roll_size     50mb`) that `caddy fmt` normalised on every reload, producing noisy diffs. **Fix**: aligned spacing reduced to single space (`roll_size 50mb`).

- **Bug 64 (P2, `install.sh`)**: `mita.service` was enabled in `start_services()` but not verified with `systemctl enable`. **Fix**: `systemctl enable mita 2>/dev/null || true` is already present and correct; now explicitly tested in `e2e.sh`.

### Added / Changed

- `panel/server/caddyTemplate.js` version comment → `v1.2.5`.
- `panel/server/index.js` version comment → `v1.2.5`; `DEFAULT_CONFIG.version` → `1.2.5`.
- `panel/package.json` version → `1.2.5`.
- `panel/public/index.html` version labels → `v1.2.5`.
- `panel/public/app.js` version comment → `v1.2.5`.
- `install.sh` header → `v1.2.5`; `CURRENT_VERSION="1.2.5"`.
- `update.sh` header → `v1.2.5`; `TARGET_VERSION="1.2.5"`.
- `README.md` / `README.en.md` version badges → `v1.2.5`.
- `tests/e2e.sh` version checks updated to `1.2.5`; added check for `mita.service` enabled (Bug 64).

### Fixed (rev.2 — post-release code audit, same version)

- **Bug 65 (P1, `install.sh` + `update.sh`)**: `ProtectSystem=full` was used in both `write_caddy_service()` (install.sh) and `ensure_caddy_service()` (update.sh), but `ProtectSystem=full` makes `/etc` read-only **system-wide**, overriding `ReadWritePaths=/etc/caddy-naive` on some kernel versions. The correct pairing is `ProtectSystem=strict`. **Fix**: both service-writing functions changed to `ProtectSystem=strict`.

- **Bug 66 (P2, `update.sh`)**: `rebuild_caddyfile_direct()` created `/var/log/caddy-naive` (and the new `/var/lib/caddy`) without `chown caddy:caddy`, so `--repair` would recreate directories owned by root after a full reinstall. **Fix**: `mkdir -p … /var/lib/caddy` followed immediately by `chown caddy:caddy /var/log/caddy-naive /var/lib/caddy` (guarded by `id caddy &>/dev/null`).

- **Bug 67 (P1, `update.sh`)**: In the Node inline block of `rebuild_caddyfile_direct()`, the `.map()` that built naive user objects passed empty string through (`password: u.password || ''`), producing `basic_auth username ` (trailing space) which Caddy rejects. The `.filter(u => u.password.trim() !== '')` guard from Bug 44 was missing here. **Fix**: `.filter(u => u.password.trim() !== '')` added after `.map()`.

- **Bug 68 (P1, `update.sh`)**: In the same inline Caddyfile fallback array, the closing brace sequence for the `log {}` sub-block was wrong — `'    }'` / `'}'` / `'}'` instead of `'    }'` / `'  }'` / `'}'`. This left the global block syntactically unclosed, producing an invalid Caddyfile that failed `caddy validate`. **Fix**: corrected to `'    }'` (closes `output {}`), `'  }'` (closes `log {}`), `'}'` (closes global `{}`).

- **Bug 69 (P1, `update.sh`)**: `rebuild_mita_state_direct()` iterated `cfg.mieruPortStart … cfg.mieruPortEnd` without `parseInt` guards, same problem as Bug 51 in index.js. **Fix**: `parseInt(..., 10) || 2000/2010` applied before the loop.

- **Bug 70 (P1, `panel/server/index.js`)**: `/api/users/:id/config/mieru` and `/api/users/:id/config/universal` iterated `cfg.mieruPortStart … cfg.mieruPortEnd` in `for` loops without `parseInt` guards (same class as Bug 51 in `buildMitaStateFile`). On a config with string values or missing keys, both loops would silently produce empty `server_ports` arrays or loop forever. **Fix**: `parseInt(..., 10) || 2000/2010` guards added in both routes.

- **ARM error messages (`install.sh`)**: `detect_arch()` error strings for ARM64 and ARMv7 still referenced `v1.2.4`. **Fix**: updated to `v1.2.5`.

- **`uninstall.sh` version** bumped `v1.2.3 → v1.2.5`; also removes `/var/lib/caddy` (ACME cert storage added in Bug 43).

- **`update.sh` `ensure_caddy_service()`**: Also applies `RestartSec=10` (from Bug 62), `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, and `/var/lib/caddy` in `ReadWritePaths` so repaired services match the units written by `install.sh`.

---

## [v1.2.4] — 2026-05-07

### Fixed (release-blockers — regression from v1.2.3 on Ubuntu 24.04 amd64)

- **Bug 23 (P0, `panel/server/index.js` + `update.sh`)**: Caddyfile validation failed on every fresh install with:
  ```
  wrong argument count or unexpected line ending after 'basic_auth'
  ```
  Root cause 1: `buildCaddyfile()` in `index.js` emitted a standalone `basic_auth` token with no arguments as a *block opener* — this is invalid in `caddy-forwardproxy-naive`; the directive is not a block, it is a flat per-user line.
  Root cause 2: per-user credential lines used the wrong spelling `basicauth` (no underscore); the correct directive is `basic_auth <username> <password>`.
  **Fix**: `buildCaddyfile()` in `panel/server/index.js` now delegates to `panel/server/caddyTemplate.js` (single source of truth, Bug 26). The standalone bare `basic_auth` token is completely removed; each user produces exactly one `basic_auth <user> <pass>` line. The inline fallback (used before `install_panel()` has run) applies the same rules. Diagnostic counter regex in `/api/diagnostics` and `do_status` in `update.sh` updated from `basicauth` → `basic_auth`.

- **Bug 24 (P0, `install.sh`)**: `write_caddyfile()` called `log_warn` on `caddy validate` failure — install continued with an invalid Caddyfile, causing `caddy-naive` to fail silently later. **Fix**: validation failure now calls `die` (fatal), prints the full validator output, and aborts the install immediately.

- **Bug 25 (P0, `install.sh`)**: `start_services()` did not check whether `caddy-naive` became active after `systemctl restart`. **Fix**: added `systemctl is-active --quiet caddy-naive` check after a 2-second wait; on failure, dumps `journalctl -u caddy-naive -n 40` and calls `die`.

### Fixed (P1 — correctness)

- **Bug 26 (P1, `panel/server/index.js`)**: `buildCaddyfile()` and `rebuild_caddyfile_direct()` in `update.sh` each had an independent inline template that could drift from `install.sh`'s template. **Fix**: `panel/server/index.js` now `require()`s `panel/server/caddyTemplate.js` and calls `tpl.render(cfg, naiveUsers)`; `update.sh` already used the template. The inline fallback in each file mirrors the template exactly and is clearly marked as a fallback.

- **Bug 27 (P1, `install.sh`)**: `write_caddyfile()` silently overwrote any existing Caddyfile on `--force` reinstall, discarding DB users. **Fix**: existing Caddyfile is backed up to `${CADDY_FILE}.bak.YYYYMMDD-HHMMSS` before overwrite; DB users are read from SQLite (via Node) and imported into the new Caddyfile.

- **Bug 28 (P1, `panel/server/index.js` + `caddyTemplate.js`)**: site block contained a redundant `tls <email>` directive — Caddy's automatic HTTPS handles TLS entirely from the global `email` directive; the redundant line caused a warning. **Fix**: `tls` directive removed from site block in both `index.js` inline fallback and `caddyTemplate.js`.

- **Bug 29 (P1, `panel/server/index.js` + `caddyTemplate.js`)**: directive order inside `forward_proxy` was `basic_auth → (bare keyword) → hide_ip → hide_via → probe_resistance` — the wrong ordering can cause parse errors in strict Caddy versions. **Fix**: enforced order is `basic_auth <user> <pass>` lines → `hide_ip` → `hide_via` → `probe_resistance <secret>` (only when secret is set).

- **Bug 30 (P1, `panel/server/index.js` + `caddyTemplate.js`)**: `order forward_proxy before file_server` was missing from the global block in `index.js` inline template. **Fix**: added to both `caddyTemplate.js` and the `index.js` inline fallback.

- **Bug 33 (P1, `install.sh`)**: no DNS pre-flight check; installer could succeed while Caddy immediately failed ACME because the domain did not resolve to the server. **Fix**: `write_caddyfile()` now resolves `$DOMAIN` via `getent hosts` and compares against `api.ipify.org` server IP, logging a warning if they differ or if DNS has no record.

### Fixed (P2 — lower priority)

- **Bug 34 (P2, `panel/server/index.js` + `caddyTemplate.js`)**: placeholder credential line was emitted even when real users existed in some edge cases. **Fix**: placeholder is emitted only when `naiveUsers.length === 0`; as soon as the first real user is created the panel rebuilds the Caddyfile and the placeholder is replaced.

- **Bug 36 (P2, `install.sh`)**: UFW `--force reset` silently wiped all existing rules without warning. **Fix**: current UFW rules are backed up to `/etc/rixxx-panel/backups/ufw-before-install-*.rules` before reset; interactive mode prompts the user for confirmation before proceeding.

- **Bug 37 (P2, `install.sh`)**: `caddy-naive.service` ran as `root`. **Fix**: `write_caddy_service()` now sets `User=caddy Group=caddy` with `AmbientCapabilities=CAP_NET_BIND_SERVICE`; `start_services()` creates the `caddy` system user if absent and sets correct ownership/permissions on the binary, config dir, and log dir.

- **Bug 38 (P2, `panel/server/index.js` + `caddyTemplate.js`)**: log rotation used `roll_keep 5` (fixed file count). **Fix**: changed to `roll_keep_for 720h` (30-day age-based retention) in both `caddyTemplate.js` and the `index.js` inline fallback.

### Added

- **`panel/server/caddyTemplate.js`** (Bug 26): canonical Caddyfile renderer shared by `install.sh` (via `node -e "require('./caddyTemplate').render(cfg, [])"`) and `panel/server/index.js`. All template-level bugs (23, 28, 29, 30, 34, 38) are fixed in exactly one place. See module JSDoc for parameter spec.

- **`tests/e2e.sh`**: comprehensive end-to-end regression suite covering all v1.2.4 acceptance criteria:
  1. Non-interactive install → `caddy validate` → service health (Bugs 23–25).
  2. Caddyfile structure checks: no bare `basic_auth`, no `tls` in site block, `order` directive present, `roll_keep_for` present, single log block (Bugs 21, 23, 28–30, 38).
  3. Service state: `caddy-naive` active, runs as `caddy` user not root (Bug 37); `mita` enabled but inactive before first user (Bug 4).
  4. HTTP → 308 redirect; HTTPS → 200 with fake-site HTML (Bug 20).
  5. API login → create user → Caddyfile re-validate → `basic_auth <user> <pass>` line present → placeholder removed → mita starts (Bugs 23, 34).
  6. Naive config link uses `naive+https://`; Mieru sing-box config has `transport: TCP`, `server_ports` array.
  7. `update.sh --repair` → Caddyfile re-validate.
  8. Idempotent `--force` reinstall → Caddyfile valid.
  9. `uninstall.sh` → assert all files/services/UFW rules removed.
  10. Version consistency across all files (install.sh, update.sh, index.js, index.html, app.js, package.json, CHANGELOG.md).

  Run: `sudo bash tests/e2e.sh --domain vpn.example.com --email admin@example.com`

### Changed

- `panel/server/index.js` version comment → `v1.2.4`; `DEFAULT_CONFIG.version` → `1.2.4`.
- `panel/package.json` version → `1.2.4`.
- `panel/public/index.html` version labels → `v1.2.4`.
- `panel/public/app.js` version comment → `v1.2.4`.
- `install.sh` header → `v1.2.4`; `CURRENT_VERSION="1.2.4"`.
- `update.sh` header → `v1.2.4`; `TARGET_VERSION="1.2.4"`.

---

## [v1.2.3] — 2026-05-07

### Breaking Changes
- **Architecture**: `caddy-forwardproxy-naive` is **amd64 (x86_64) only**. ARM64 and ARMv7 are explicitly rejected by the installer with a clear error message.
- **NaiveProxy binary replaced**: standalone `naive` binary removed; replaced by `caddy-forwardproxy-naive` (Caddy with embedded forward-proxy module).
  - Binary path: `/usr/local/bin/caddy-naive`
  - Config: `/etc/caddy-naive/Caddyfile` (replaces `/etc/naive/config.json` + `/etc/naive/htpasswd`)
  - Systemd unit: `caddy-naive.service` (replaces `naive.service`)
  - TLS managed automatically by Caddy via TLS-ALPN-01 (no certbot, no port 80 needed)
- **htpasswd removed**: user authentication now lives directly in the Caddyfile as `basicauth` lines; rebuilt atomically after every user CRUD operation via `applyAllConfigs()`.
- **certbot / apache2-utils removed** from installer dependencies — Caddy handles its own TLS.
- **UFW**: port 80/tcp rule removed (Caddy TLS-ALPN-01 does not need HTTP-01); port 443 comment changed from `NaiveProxy HTTPS` → `CaddyNaive HTTPS`.

### Added
- **Fake site** (`/var/www/fake-site/index.html`): Caddy's `file_server` serves this page to unrecognised clients — provides a plausible "normal website" cover.
- **Probe resistance** (`probe_resistance <secret>`): clients must present the probe-secret token in the `Proxy-Authorization` header; unauthenticated scanners see the fake site instead of an error.
- **`--fake-site-url`** and **`--probe-secret`** CLI arguments added to `install.sh`.
- **`install_caddy_naive()`** function in `install.sh`: fetches latest `caddy-forwardproxy-naive.tar.xz` from `klzgrad/forwardproxy` GitHub releases; falls back to pinned `v2.10.0-naive` URL if GitHub API is unreachable; uses `setcap cap_net_bind_service` so caddy-naive can bind port 443 without running as root.
- **`write_caddyfile()`** in `install.sh`: generates Caddyfile with `forward_proxy { basic_auth … hide_ip hide_via probe_resistance <secret> }` + `file_server { root /var/www/fake-site }`.
- **`setup_fake_site()`** in `install.sh`: writes a minimal HTML landing page.
- **`buildCaddyfile(cfg, users)`** in `panel/server/index.js`: server-side Caddyfile builder called on every user change; writes atomically via `.new` + `rename`.
- **`writeCaddyfileAtomic()`**, **`reloadCaddy()`**, **`restartCaddy()`** in `panel/server/index.js`.
- **`applyAllConfigs()`** in `panel/server/index.js`: unified pipeline — build Caddyfile → reload Caddy → rebuild mita state → apply mita config.
- **`/api/services/rebuild-all`** POST endpoint (requires auth): rebuilds Caddyfile + mita-state from DB; used by `update.sh --repair`.
- **`/api/settings/probe-secret`** POST endpoint: updates `probeSecret` in config, rewrites `probe_secret` file, reloads Caddy.
- **`update_caddy_naive()`** in `update.sh`: replaces `update_naiveproxy()`; checks GitHub API for latest release; falls back to pinned v2.10.0 URL.
- **`rebuild_caddyfile_direct()`** and **`rebuild_mita_state_direct()`** in `update.sh` (`--repair`): Node.js one-liners that reconstruct configs from SQLite without needing the panel to be running.
- **`ensure_caddy_service()`** in `update.sh`: creates `caddy-naive.service` if missing, removes legacy `naive.service`.
- **Probe Secret setting card** in Settings page (`index.html` + `app.js`): masked input + "Apply Secret" button.
- **i18n keys** added to `en.json` and `ru.json`: `settings.probeSecretTitle/Desc/Label/Placeholder/Updated/TooShort/applyProbeSecret`.
- **Diagnostics page** (`app.js`): replaced `htpasswd users: N` counter with `Caddyfile users: N | probe_secret: ✓/✗` display.
- **Smoke tests** in `install.sh`: check `caddy-naive.service` active, Caddyfile present, fake-site `index.html` present, `probe_secret` file present.
- **`uninstall.sh` v1.2.3**: removes `caddy-naive.service`, `caddy-naive` binary, `/etc/caddy-naive/`, `/var/www/fake-site`, legacy `naive.service`/`/etc/naive/`, Certbot renewal hook; UFW rules updated for new comment strings.
- **`panel/package.json`** version bumped to `1.2.3`.

### Changed
- `install.sh` version → `1.2.3`; `update.sh` TARGET_VERSION → `1.2.3`; `panel/server/index.js` → `v1.2.3`; `panel/public/app.js` → `v1.2.3`; `panel/public/index.html` title/sidebar → `v1.2.3`.
- `config.json` now stores `caddyBin`, `caddyFile`, `caddyConfigDir`, `fakeSiteDir`, `fakeSiteUrl`, `probeSecret` fields.
- `/api/status` still returns `services.naive` key (front-end compat) but now reflects `caddy-naive.service` state and caddy binary version.
- `/api/logs/naive` and `/api/logs/caddy` now tail `journalctl -u caddy-naive` (back-compat aliases preserved).
- `/api/service/naive/…` maps to `caddy-naive` via `svcMap` (back-compat).
- `update.sh --status`: shows `caddy-naive` version, Caddyfile user count, fake-site presence, probe-resistance config.
- `update.sh --repair`: calls `/api/services/rebuild-all` first; falls back to direct Node.js DB rebuild.
- Final install banner shows `Probe secret` and `Fake site` values.

### Removed
- `install_naiveproxy()` function (replaced by `install_caddy_naive()`).
- `update_naiveproxy()` function in `update.sh` (replaced by `update_caddy_naive()`).
- `rebuild_htpasswd_from_db()`, `rebuild_naive_config()` functions in `update.sh`.
- `ensure_naive_service()` function (replaced by `ensure_caddy_service()`).
- `certbot`, `apache2-utils` from installer dependencies.
- `naive.service` systemd unit (replaced by `caddy-naive.service`).
- `/usr/local/bin/naive` binary (replaced by `/usr/local/bin/caddy-naive`).
- `/etc/naive/config.json` and `/etc/naive/htpasswd` (replaced by `/etc/caddy-naive/Caddyfile`).
- Certbot renewal hook `/etc/letsencrypt/renewal-hooks/deploy/restart-naive.sh` (no longer needed; Caddy auto-renews).
- Duplicate site-level `log { }` block from Caddyfile template (Bug 21 — kept global block only).

### Fixed (post-release patches)
- **Bug 18 (P0, install.sh + panel/server/index.js)**: Caddyfile generated with an empty `basic_auth` block when no users exist in the DB yet — Caddy rejects this and the install aborts. Fixed in both places:
  - `write_caddyfile()` (`install.sh`): generates a random `_placeholder_install` sentinel `basicauth` line before the heredoc; uses real DB users if any exist. Calls `caddy validate` after writing and logs warnings if validation fails.
  - `buildCaddyfile()` (`panel/server/index.js`): when `naiveUsers` array is empty emits a `_placeholder_<random-hex>` basicauth line using `crypto.randomBytes`; real users replace it on next rebuild.
- **Bug 19 (P0, install.sh)**: No rollback guidance on failure — installer silently exited, leaving system in partial state. Added `on_error()` function and `trap 'on_error $? $LINENO' ERR` immediately after the install-log redirect. The handler prints: exit code, line number, log path, and three recovery options (`--force` re-run, clean `uninstall.sh`, `tail -30` log).
- **Bug 20 (P1, install.sh)**: UFW did not open port 80, breaking ACME HTTP-01 TLS challenge (Caddy uses HTTP-01 as fallback when TLS-ALPN-01 is unavailable, and also needs port 80 for the HTTP→HTTPS redirect). Added `ufw allow 80/tcp comment "ACME HTTP-01 + redir HTTPS"` in `setup_ufw()`.
- **Bug 21 (P1, install.sh + panel/server/index.js)**: Caddyfile contained both a global `log { }` block and a duplicate site-level `log { output file … }` block writing to the same file — Caddy warns and only one block takes effect. Removed the site-level block; global block covers all requests.
- **Bug 22 (P1, install.sh)**: `caddy-naive.service` unit file was written *inside* `start_services()`, after `systemctl daemon-reload` had already been called — so the new unit was never picked up by systemd on the first run. Moved `write_caddy_service()` call to `main()` (between `write_caddyfile()` and `write_config_json()`); `start_services()` now runs `daemon-reload` with the unit already on disk.

---

## [v1.2.2] — 2026-05-07

### Fixed
- **Bug 1 (P0, frontend)**: Confirmed no inline handlers remain in `index.html`; CSP in `server/index.js` already has `'unsafe-inline'` in `scriptSrc` so dynamically rendered buttons work. Log tab renamed from "Caddy" → "Naive"; `logs.naive` key added to both locale files.
- **Bug 2 (P0, install.sh)**: `certbot certonly` does **not** accept `--cert-path` / `--key-path` flags — they are invalid and cause a non-zero exit even on success. Removed those flags; certs now land in the standard LE path `/etc/letsencrypt/live/<domain>/` which is read directly.
- **Bug 3 (P1, install.sh + index.js)**: UFW rejects `N:N/proto` range syntax when start port equals end port (e.g. `--mieru-start 2015 --mieru-end 2015`), crashing the installer. Added `_ufw_mieru_rule()` helper in `install.sh` that emits a single-port rule (`N/proto`) when start==end, or a range rule otherwise. Same fix applied in `panel/server/index.js` (`ufwMieruRule()` helper used in `/api/settings/mieru-ports` and `/api/settings/udp-toggle`).
- **Bug 4 (P1, install.sh)**: `mita` crashes on start when `users[]` is empty (fresh install has no users). `start_services()` now applies the config (so mita knows the port range) but only actually starts the `mita.service` when at least one user is present in `mita-state.json`. The panel's `rebuildServices()` starts mita automatically after the first user is created.
- **Bug 5 (P2, install.sh)**: TLS cert/key paths now point directly to `/etc/letsencrypt/live/<domain>/fullchain.pem` and `privkey.pem`. Added `chmod o+x` on `/etc/letsencrypt`, `live/`, and `archive/<domain>/` so the naive process (running as root) can traverse the symlink chain. Added `chmod o+r` on `*.pem` files. Renewal hook re-applies these permissions after every `certbot renew`.
- **i18n**: Added `logs.naive`, `diagnostics.naiveValid`, `diagnostics.naiveInvalid`, `login.sessionExpired` keys to `en.json` and `ru.json`.

---

## [v1.2.1] — 2026-05-07

### Fixed
- **Critical #1**: `detect_arch()` x86_64 mapping corrected — `NAIVE_ARCH` now set to `linux-x64` (was `linux-amd64`) in both `install.sh` and `update.sh`, matching the actual NaiveProxy release asset suffix
- **Minor #6**: jq asset-selection loop now tries fallback aliases `linux-amd64` → `linux-x86_64` after primary `linux-x64` for x86_64 hosts, protecting against future upstream asset-name changes (both scripts)
- **Blocker #3**: `do_status` in `update.sh` no longer fails when `naive --version` returns empty — wrapped with `|| echo 'installed'` fallback
- **Minor #7**: `naive --version` smoke-test wrapped with `timeout 5` in both `install.sh` and `update.sh` to avoid hanging if the binary stalls at startup
- **Minor #4**: Admin password generation replaced `tr -dc` (may produce shell-special chars) with `openssl rand -base64 18 | tr -d '/+='` — 20-char alphanumeric output, no shell quoting issues
- **Blocker #2**: Confirmed `rebuild_mita_state()` reads the `password` column (plaintext) — not `passHash` (bcrypt) — when constructing the JSON passed to `mita apply config`; no regression
- **Minor #5**: README.md / README.en.md — ARM64 and ARMv7 architectures marked *experimental, not tested in production*

---

## [v1.2.0] — 2026-05-07

### Breaking Changes
- **NaiveProxy binary** changed from `caddy-naive` to standalone `naive` binary
  - Binary path: `/usr/local/bin/naive` (was `/usr/local/bin/caddy-naive`)
  - Config: `/etc/naive/config.json` + `/etc/naive/htpasswd` (was Caddyfile)
  - Systemd unit: `naive.service` (was `caddy-naive.service`)
  - Run `bash update.sh --repair` to migrate an existing v1.1.x install

### Added
- **Blocker 1**: Strict architecture asset matching — `endswith("-" + arch + ".tar.xz")` with no Linux fallback
- **Blocker 2**: `NAIVE_BIN=/usr/local/bin/naive`, `NAIVE_CONFIG_DIR=/etc/naive`; searches for `naive`/`naiveproxy` binary in archive
- **Blocker 3**: `/etc/naive/config.json` with `listen`, `name`, `auth` (htpasswd path), `padding`, `log`
- **Blocker 4**: `naive.service` systemd unit; old `caddy-naive.service` removed on install/repair
- **Blocker 5**: Smoke tests — `naive --version`, `systemctl is-active naive`, port-listen check
- **Blocker 6**: `update.sh --repair` rebuilds htpasswd + naive config + mita-state from SQLite; `--status` shows naive version, config, htpasswd user count
- **Blocker 7**: `buildHtpasswd(users)` + `buildNaiveConfig()` in `server/index.js`; all user CRUD rebuilds htpasswd + reloads naive
- **Blocker 8**: Post-start Mieru port-listen check in smoke tests and `/api/diagnostics`
- **Blocker 9**: Installer output captured to `/var/log/rixxx-panel-install.log`
- **Blocker 10**: `--non-interactive`/`--force` flags; `--domain`, `--email`, `--admin-pass` etc. CLI args
- **Blocker 11**: Version file at `/etc/rixxx-panel/version` with key=value format (`panel_version`, `naive_version`, `mieru_version`, `installed_at`)
- **Blocker 12**: Generic listen `"https://:PORT"` in naive config; `"name": "${DOMAIN}"` for logging
- **Blocker 13**: Certbot step in `install.sh`; `cert`/`key` paths in config.json; renewal hook
- **Blocker 14**: `fmtLastSeen(iso)` in `app.js` — shows "X min ago / Xh ago / Xd ago" in tables
- **Blocker 15**: GitHub Actions CI matrix in `.github/workflows/ci.yml` — Ubuntu 24.04, 22.04, Debian 12
- `apache2-utils` and `certbot` added to `install_deps()`
- UFW opens port 80/tcp for Certbot HTTP-01 challenges
- `uninstall.sh` removes naive paths, legacy caddy-naive artifacts, Certbot hook

### Changed
- `install.sh` version bumped to `1.2.0`
- `update.sh` TARGET_VERSION bumped to `1.2.0`
- `panel/package.json` version bumped to `1.2.0`
- `panel/server/index.js` bumped to `v1.2.0`
- `panel/public/app.js` bumped to `v1.2.0`
- `/api/logs/caddy` aliased to `naive` logs for back-compat
- `/api/service/caddy-naive/…` aliased to `naive` for back-compat

### Fixed
- `update.sh --status` shows naive binary version
- `update.sh --repair` rebuilds from live DB without requiring a backup
- `uninstall.sh` cleans all v1.2.0 paths and legacy caddy-naive artifacts

---

## [v1.1.0] — 2026-05-06

### Added
- **Bilingual UI** — Russian (default) and English, language selector in header, stored in `localStorage`
- **Locale files** `panel/public/locales/ru.json` and `panel/public/locales/en.json`
- **Dark / Light theme toggle** — dark mode default, sun/moon switch persisted in `localStorage`
- **Redesigned CSS palette** — dark gradient `#1a1a1d → #2c2c30`, bronze accent `#c08552`, glassmorphism cards
- **QR-code generation** for Naive links (iOS/Android import via QR)
- **Karing client** added to recommended client lists (iOS / Android / Windows / macOS / Linux)
- **README.ru.md** — primary Russian documentation with architecture diagram, troubleshooting, client tables
- **README.en.md** — English documentation
- Language-switch links at top of both READMEs
- **CHANGELOG.md** — this file
- **LICENSE** — MIT license
- Corrected `/etc/mita/` documentation: internal protobuf store, not edited manually
- `mita-state.json` correctly documented at `/var/lib/rixxx-panel/mita-state.json`
- Troubleshooting section (top-5 fixes) in both READMEs
- Uninstall documentation with `--keep-configs` flag
- Donation / Telegram links prominently placed in READMEs

### Fixed
- Removed incorrect `/etc/mita/server.json` and `/etc/mita/users.json` references from docs
- `buildMitaStateFile()` now correctly uses `/var/lib/rixxx-panel/mita-state.json`
- `reloadMieru()` / `restartMieru()` verified to use correct state file path

### Changed
- `README.md` is now the primary Russian README (language switch link at top)
- CSS accent color changed from blue `#6c8ef5` to bronze `#c08552` per product identity

---

## [v1.0.0] — 2026-05-05

### Added
- **Sprint 1 — Installer** (`install.sh`)
  - Automatic OS detection (Ubuntu 20.04/22.04/24.04, Debian 11/12)
  - Architecture detection (x86_64, aarch64, armv7l)
  - NaiveProxy binary download from GitHub releases API
  - Mieru `.deb` install from enfein/mieru GitHub releases
  - NTP sync enforcement via `timedatectl`
  - Bilingual prompts (Russian default, English option)
  - Interactive setup wizard: domain, TLS email, Naive port (443), Mieru port range (2012-2022)
  - Optional UFW setup
  - Config stored at `/etc/rixxx-panel/config.json`
  - `mita-state.json` built and applied via `mita apply config`
  - Smoke tests (caddy-naive, mita, panel HTTP, time sync)
  - Idempotent reinstall support with backup

- **Sprint 2 — User CRUD**
  - SQLite model: id, email, username, password-hash, plain password (for mita), expiry, protocols, quota, timestamps
  - On create/update: rebuild Caddyfile + reload caddy-naive, rebuild Mieru JSON + `mita apply config` + `mita reload`
  - Expiry cron every 5 minutes
  - UI table with Edit / Config / Delete actions

- **Sprint 3 — Server Settings**
  - NaiveProxy port change: Caddy reload only (no restart)
  - Mieru port range change: UFW update + full `mita stop && mita start`
  - Traffic pattern presets: NOOP, RANDOM_PADDING, RANDOM_PADDING_AGGRESSIVE
  - MTU setting (1280–1400)
  - UI warning after port changes

- **Sprint 4 — Client Configs**
  - Naive link: `naive+https://username:password@domain:443`
  - Mieru sing-box JSON template
  - Universal config: NaiveProxy + Mieru + `urltest` auto-fallback selector
  - Download buttons in UI

- **Sprint 5 — Monitoring Dashboard**
  - Per-user traffic snapshots every 60 s
  - Live WebSocket metrics every 5 s (CPU, RAM, service status)
  - System metrics: CPU, RAM, Disk, uptime, OS, arch, service versions
  - Quota alerts (>80% warn, >95% danger)
  - `mita describe users` parser (handles version differences)

- **Sprint 6 — update.sh**
  - Flags: `--dry-run`, `--force`, `--expose <domain>`, `--ssh-only`, `--status`, `--repair`, `--help`
  - Backups in `/etc/rixxx-panel/backups/YYYY-MM-DD-HHMMSS/` (keeps last 10)
  - Version file at `/etc/rixxx-panel/version`
  - GitHub API version comparison for NaiveProxy and Mieru
  - Health-check commands after install/update
  - `--repair` rebuilds JSON from SQLite

- **uninstall.sh** — full cleanup with `shred`, `--keep-configs` flag
- **panel/server/index.js** — Express backend, REST API, WebSocket, SQLite, cron jobs
- **panel/public/** — SPA HTML + CSS + JS (login, dashboard, users, settings, monitoring, logs, diagnostics)
- **panel/package.json** — Node.js dependencies (Express, better-sqlite3, bcryptjs, ws, node-cron, systeminformation, etc.)
- **panel/scripts/** — standalone `install_naiveproxy.sh`, `install_mieru.sh`, `sysctl_tune.sh`

---

[v1.1.0]: https://github.com/InWithLost/Panel-Naive-Mieru-by-RIXXX/compare/v1.0.0...v1.1.0
[v1.0.0]: https://github.com/InWithLost/Panel-Naive-Mieru-by-RIXXX/releases/tag/v1.0.0
