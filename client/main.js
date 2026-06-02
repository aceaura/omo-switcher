// Electron 主进程：创建窗口、初始化 SQLite、提供 IPC（设置/DB/HTTP 调用）。
// 渲染层不直接访问 node；所有能力经 preload 白名单暴露。
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');
const db = require('./db.js');

function serverUrl() {
  return (db.getSetting('server_url') || 'http://127.0.0.1:7600').replace(/\/+$/, '');
}

// 主进程统一发起 HTTP，避免渲染层 CORS / 暴露 token。
async function apiCall(method, pathname, body) {
  const url = serverUrl() + pathname;
  const headers = { 'content-type': 'application/json' };
  const token = db.getSetting('auth_token');
  if (token) headers['authorization'] = `Bearer ${token}`;
  const res = await fetch(url, {
    method,
    headers,
    body: body != null ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { ok: false, error: { code: 'BAD_JSON', message: text.slice(0, 200) } }; }
  if (!res.ok && json.ok === undefined) json.ok = false;
  return json;
}

function registerIpc() {
  // 设置
  ipcMain.handle('settings:all', () => db.allSettings());
  ipcMain.handle('settings:get', (_e, key) => db.getSetting(key));
  ipcMain.handle('settings:set', (_e, key, value) => { db.setSetting(key, value); return true; });

  // 通用 HTTP 透传
  ipcMain.handle('api:call', (_e, method, pathname, body) => apiCall(method, pathname, body));

  // 本地配置项（SQLite）
  ipcMain.handle('db:listItems', () => db.listConfigItems());
  ipcMain.handle('db:getItem', (_e, key) => db.getConfigItem(key));
  ipcMain.handle('db:recentSync', (_e, n) => db.recentSyncLog(n));

  // 高层操作：拉取（远端→本地 SQLite，仅所选 key；不触碰 local_settings）
  ipcMain.handle('sync:pull', async (_e, { keys, snapshot }) => {
    const pulled = [];
    for (const key of keys) {
      const q = snapshot ? `?snapshot=${encodeURIComponent(snapshot)}` : '';
      const r = await apiCall('GET', `/api/config/item/${encodeURIComponent(key)}${q}`);
      if (r.ok !== false && r.contentB64) {
        db.upsertConfigItem({ key, ...r }, 'pulled');
        pulled.push(key);
      }
    }
    db.addSyncLog('pull', keys.length > 1 ? 'all' : 'single', pulled, snapshot || null, true);
    return { ok: true, pulled };
  });

  // 高层操作：推送（本地 SQLite 所选 key → 远端，生成新快照）
  ipcMain.handle('sync:push', async (_e, { keys, note }) => {
    const items = keys.map((k) => {
      const it = db.getConfigItem(k);
      return { key: it.key, contentB64: it.content_b64, sha256: it.sha256, size: it.size };
    });
    const r = await apiCall('POST', '/api/config/push', { items, note: note || 'push from client' });
    db.addSyncLog('push', keys.length > 1 ? 'all' : 'single', keys, r.snapshotId || null, r.ok !== false);
    return r;
  });

  // 从本机文件系统导入到 SQLite（首次填充本地配置项；走服务端扫描接口）
  ipcMain.handle('local:importFromServer', async () => {
    const list = await apiCall('GET', '/api/config/items');
    const imported = [];
    if (list.items) {
      for (const meta of list.items) {
        const full = await apiCall('GET', `/api/config/item/${encodeURIComponent(meta.key)}`);
        if (full.contentB64) { db.upsertConfigItem({ ...meta, ...full }, 'local-scan'); imported.push(meta.key); }
      }
    }
    return { ok: true, imported };
  });
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1100,
    height: 800,
    title: 'omo-switcher',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

app.whenReady().then(() => {
  db.init(app.getPath('userData'));
  registerIpc();
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
