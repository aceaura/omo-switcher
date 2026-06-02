// 客户端本地 SQLite。隔离“本机私有设置(local_settings)”与“可同步配置项(config_items)”。
// 见 doc/design.md §3.3。pull 全盘覆盖时只动 config_items，绝不触碰 local_settings。
const path = require('node:path');
const Database = require('better-sqlite3');

let db;

function init(userDataDir) {
  const file = path.join(userDataDir, 'omo-switcher.sqlite');
  db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS local_settings (
      key TEXT PRIMARY KEY,
      value TEXT
    );
    CREATE TABLE IF NOT EXISTS config_items (
      key TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      tier_slug TEXT,
      tier_index INTEGER,
      content_b64 TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      size INTEGER,
      source TEXT,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS switch_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      tier_slug TEXT, ok INTEGER, detail TEXT, at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS sync_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      direction TEXT, scope TEXT, items TEXT, snapshot_id TEXT, ok INTEGER, at TEXT NOT NULL
    );
  `);
  // 默认服务器地址
  if (!getSetting('server_url')) setSetting('server_url', 'http://127.0.0.1:7600');
  return file;
}

// ---- local_settings（私有，不参与同步）----
function getSetting(key) {
  const row = db.prepare('SELECT value FROM local_settings WHERE key=?').get(key);
  return row ? row.value : null;
}
function setSetting(key, value) {
  db.prepare(
    'INSERT INTO local_settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value'
  ).run(key, String(value));
}
function allSettings() {
  return db.prepare('SELECT key,value FROM local_settings').all()
    .reduce((o, r) => ((o[r.key] = r.value), o), {});
}

// ---- config_items（可同步）----
function listConfigItems() {
  return db.prepare(
    'SELECT key,provider,tier_slug AS tierSlug,tier_index AS tierIndex,sha256,size,source,updated_at FROM config_items ORDER BY key'
  ).all();
}
function getConfigItem(key) {
  return db.prepare('SELECT * FROM config_items WHERE key=?').get(key);
}
function upsertConfigItem(it, source = 'pulled') {
  db.prepare(`
    INSERT INTO config_items(key,provider,tier_slug,tier_index,content_b64,sha256,size,source,updated_at)
    VALUES(@key,@provider,@tierSlug,@tierIndex,@contentB64,@sha256,@size,@source,@updated_at)
    ON CONFLICT(key) DO UPDATE SET
      provider=excluded.provider, tier_slug=excluded.tier_slug, tier_index=excluded.tier_index,
      content_b64=excluded.content_b64, sha256=excluded.sha256, size=excluded.size,
      source=excluded.source, updated_at=excluded.updated_at
  `).run({
    key: it.key,
    // 现在 key 即档位 slug，内容为整个档位 zip；provider 固定 'bundle'。
    provider: it.provider || 'bundle',
    tierSlug: it.slug || it.tierSlug || it.key,
    tierIndex: it.index ?? it.tierIndex ?? null,
    contentB64: it.contentB64, sha256: it.sha256,
    size: it.size ?? null, source, updated_at: new Date().toISOString(),
  });
}

// ---- 历史 / 同步日志 ----
function addSwitchHistory(tierSlug, ok, detail) {
  db.prepare('INSERT INTO switch_history(tier_slug,ok,detail,at) VALUES(?,?,?,?)')
    .run(tierSlug, ok ? 1 : 0, detail || null, new Date().toISOString());
}
function addSyncLog(direction, scope, items, snapshotId, ok) {
  db.prepare('INSERT INTO sync_log(direction,scope,items,snapshot_id,ok,at) VALUES(?,?,?,?,?,?)')
    .run(direction, scope, JSON.stringify(items || []), snapshotId || null, ok ? 1 : 0, new Date().toISOString());
}
function recentSyncLog(limit = 20) {
  return db.prepare('SELECT * FROM sync_log ORDER BY id DESC LIMIT ?').all(limit);
}

module.exports = {
  init, getSetting, setSetting, allSettings,
  listConfigItems, getConfigItem, upsertConfigItem,
  addSwitchHistory, addSyncLog, recentSyncLog,
};
