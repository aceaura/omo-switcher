// omo-switcher 服务端入口：Express 路由汇总。见 doc/design.md §4。
import express from 'express';
import cors from 'cors';
import { config } from './config.js';
import { initStore, storeMode, getHistory } from './store.js';
import { getState } from './presets.js';
import { applyTier } from './switcher.js';
import { restartOpencode } from './restart.js';
import * as versions from './versions.js';
import { scanLocalConfigItems, diffItems, isAllowedKey } from './sync.js';

initStore();

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));

const ok = (res, payload = {}) => res.json({ ok: true, ...payload });
const fail = (res, code, message, status = 400) =>
  res.status(status).json({ ok: false, error: { code, message } });

// 包装异步 handler 的错误。
const h = (fn) => (req, res) =>
  Promise.resolve(fn(req, res)).catch((err) => {
    console.error('[api] error:', err);
    if (!res.headersSent) fail(res, 'INTERNAL', err.message, 500);
  });

// ---- 状态 / 切换 / 重启 (FR-1 / FR-2) ----
app.get('/api/health', h(async (_req, res) => ok(res, { storeMode: storeMode() })));

app.get('/api/state', h(async (_req, res) => ok(res, getState())));

app.post(
  '/api/switch',
  h(async (req, res) => {
    const { tier } = req.body || {};
    if (!tier) return fail(res, 'BAD_PARAM', '缺少 tier');
    const result = await applyTier(tier);
    ok(res, result);
  })
);

app.post(
  '/api/restart',
  h(async (req, res) => {
    const { cwd, launchCmd } = req.body || {};
    const result = await restartOpencode({ cwd, launchCmd });
    ok(res, result);
  })
);

app.get(
  '/api/history',
  h(async (req, res) => {
    const limit = Number(req.query.limit || 20);
    ok(res, { items: await getHistory(limit) });
  })
);

// ---- 配置项 / 同步 (FR-3) ----
// 远端“当前”配置项：优先取 head 快照；无快照则退回扫描本机文件系统。
app.get(
  '/api/config/items',
  h(async (_req, res) => {
    let items = await versions.getCurrentItems();
    let source = 'snapshot';
    if (!items.length) {
      items = scanLocalConfigItems({ withContent: false });
      source = 'filesystem';
    } else {
      items = items.map(({ contentB64, ...rest }) => rest); // 列表不带大内容
    }
    ok(res, { source, items });
  })
);

app.get(
  '/api/config/item/:key',
  h(async (req, res) => {
    const { key } = req.params;
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法 key: ${key}`);
    const snapshot = req.query.snapshot;
    if (snapshot) {
      const item = await versions.getSnapshotItem(snapshot, key);
      if (!item) return fail(res, 'NOT_FOUND', `快照 ${snapshot} 无 ${key}`, 404);
      return ok(res, item);
    }
    // 当前：先 head 快照，再退回文件系统
    const cur = await versions.getCurrentItems();
    const found = cur.find((i) => i.key === key);
    if (found) return ok(res, found);
    const fsItems = scanLocalConfigItems({ withContent: true });
    const f = fsItems.find((i) => i.key === key);
    if (!f) return fail(res, 'NOT_FOUND', `无 ${key}`, 404);
    ok(res, f);
  })
);

// 客户端推送本地项 -> 生成新快照
app.post(
  '/api/config/push',
  h(async (req, res) => {
    const { items, note } = req.body || {};
    if (!Array.isArray(items) || !items.length) return fail(res, 'BAD_PARAM', '缺少 items');
    for (const it of items) {
      if (!isAllowedKey(it.key)) return fail(res, 'BAD_KEY', `非法 key: ${it.key}`);
      if (typeof it.contentB64 !== 'string') return fail(res, 'BAD_PARAM', `缺少 contentB64: ${it.key}`);
    }
    const snapshotId = await versions.createSnapshot(items, { note: note || 'push' });
    ok(res, { snapshotId });
  })
);

// diff：客户端可传本地清单，服务端返回与远端当前的差异。
app.post(
  '/api/config/diff',
  h(async (req, res) => {
    const local = (req.body && req.body.localItems) || [];
    let remote = await versions.getCurrentItems();
    if (!remote.length) remote = scanLocalConfigItems({ withContent: false });
    ok(res, { diff: diffItems(local, remote) });
  })
);

// ---- 版本历史 / 回滚 (FR-4) ----
app.get(
  '/api/snapshots',
  h(async (req, res) => {
    const limit = Number(req.query.limit || 50);
    ok(res, await versions.listSnapshots(limit));
  })
);

app.get(
  '/api/snapshots/:id',
  h(async (req, res) => {
    const snap = await versions.getSnapshot(req.params.id);
    if (!snap) return fail(res, 'NOT_FOUND', `无快照 ${req.params.id}`, 404);
    ok(res, snap);
  })
);

app.post(
  '/api/snapshots/:id/rollback',
  h(async (req, res) => {
    const snapshotId = await versions.rollbackAll(req.params.id, { note: req.body?.note });
    ok(res, { snapshotId });
  })
);

app.post(
  '/api/snapshots/:id/rollback-file',
  h(async (req, res) => {
    const { key, note } = req.body || {};
    if (!key) return fail(res, 'BAD_PARAM', '缺少 key');
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法 key: ${key}`);
    const snapshotId = await versions.rollbackFile(req.params.id, key, { note });
    ok(res, { snapshotId });
  })
);

app.use((_req, res) => fail(res, 'NOT_FOUND', 'route not found', 404));

app.listen(config.port, config.host, () => {
  console.log(`omo-switcher server: http://${config.host}:${config.port} (store=${storeMode()})`);
  console.log(`opencodeDir: ${config.opencodeDir}`);
});
