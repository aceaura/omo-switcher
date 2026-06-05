// omo-switcher 服务端入口：Express 路由汇总。见 doc/design.md §4。
import express from 'express';
import cors from 'cors';
import { config } from './config.js';
import { initStore, storeMode, getHistory } from './store.js';
import { getState } from './presets.js';
import { applyTier } from './switcher.js';
import { restartOpencode } from './restart.js';
import * as versions from './versions.js';
import { scanLocalBundles, buildLocalBundle, applyLocalBundle, diffItems, isAllowedKey } from './sync.js';

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

app.get('/api/state', h(async (_req, res) => ok(res, await getState())));

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
// 远端“当前”档位包清单(key=slug，不含 zip 内容)：优先 head 快照，无快照退回扫描本机。
app.get(
  '/api/config/items',
  h(async (req, res) => {
    // ?fs=1 强制扫描本机文件系统(用于"导入本机")；否则取远端 head 快照，无则退回扫描。
    if (req.query.fs === '1') {
      return ok(res, { source: 'filesystem', items: await scanLocalBundles() });
    }
    let items = await versions.getCurrentItems();
    let source = 'snapshot';
    if (!items.length) {
      items = await scanLocalBundles();
      source = 'filesystem';
    } else {
      items = items.map(({ contentB64, ...rest }) => rest); // 列表不带 zip 大内容
    }
    ok(res, { source, items });
  })
);

// 取单个档位包(zip)。key=slug。?snapshot=<id> 取历史版本。
app.get(
  '/api/config/item/:key',
  h(async (req, res) => {
    const { key } = req.params;
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法档位: ${key}`);
    // ?fs=1 强制实时打包本机该档位（用于"导入本机"，忽略 head 快照）
    if (req.query.fs === '1') return ok(res, await buildLocalBundle(key));
    const snapshot = req.query.snapshot;
    if (snapshot) {
      const item = await versions.getSnapshotItem(snapshot, key);
      if (!item) return fail(res, 'NOT_FOUND', `快照 ${snapshot} 无 ${key}`, 404);
      return ok(res, item);
    }
    const cur = await versions.getCurrentItems();
    const found = cur.find((i) => i.key === key);
    if (found) return ok(res, found);
    // 退回：实时打包本机该档位
    ok(res, await buildLocalBundle(key));
  })
);

app.post(
  '/api/config/item/:key/fs',
  h(async (req, res) => {
    const { key } = req.params;
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法档位: ${key}`);
    const { contentB64 } = req.body || {};
    if (typeof contentB64 !== 'string') return fail(res, 'BAD_PARAM', `缺少 contentB64: ${key}`);
    ok(res, await applyLocalBundle(key, contentB64));
  })
);

// 客户端推送档位包 -> 生成新快照
app.post(
  '/api/config/push',
  h(async (req, res) => {
    const { items, note } = req.body || {};
    if (!Array.isArray(items) || !items.length) return fail(res, 'BAD_PARAM', '缺少 items');
    for (const it of items) {
      if (!isAllowedKey(it.key)) return fail(res, 'BAD_KEY', `非法档位: ${it.key}`);
      if (typeof it.contentB64 !== 'string') return fail(res, 'BAD_PARAM', `缺少 contentB64: ${it.key}`);
    }
    const snapshotId = await versions.createSnapshot(items, { note: note || 'push' });
    ok(res, { snapshotId });
  })
);

// 从云端当前仓库删除配置项：用“剩余集合”生成新快照，不修改历史快照。
app.delete(
  '/api/config/items',
  h(async (req, res) => {
    const { keys, note } = req.body || {};
    if (!Array.isArray(keys) || !keys.length) return fail(res, 'BAD_PARAM', '缺少 keys');
    const uniqueKeys = [...new Set(keys.map((key) => String(key)))];
    for (const key of uniqueKeys) {
      if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法档位: ${key}`);
    }

    let current = await versions.getCurrentItems();
    if (!current.length) {
      const scanned = await scanLocalBundles();
      current = await Promise.all(scanned.map((item) => buildLocalBundle(item.key)));
    }
    const remaining = current.filter((item) => !uniqueKeys.includes(item.key));
    const snapshotId = await versions.createSnapshot(remaining, {
      note: note || `delete ${uniqueKeys.join(', ')}`,
      parentId: await versions.getHead(),
    });
    ok(res, { snapshotId, deleted: uniqueKeys });
  })
);

// 从云端当前仓库重命名配置项：用“重命名后的集合”生成新快照，不修改历史快照。
app.post(
  '/api/config/item/:key/rename',
  h(async (req, res) => {
    const { key } = req.params;
    const { newKey, note } = req.body || {};
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法档位: ${key}`);
    if (!isAllowedKey(newKey)) return fail(res, 'BAD_KEY', `非法目标档位: ${newKey}`);
    let current = await versions.getCurrentItems();
    if (!current.length) {
      const scanned = await scanLocalBundles();
      current = await Promise.all(scanned.map((item) => buildLocalBundle(item.key)));
      await versions.createSnapshot(current, { note: 'import filesystem before rename' });
    }
    const found = current.find((item) => item.key === key);
    if (!found) return fail(res, 'NOT_FOUND', `当前云端仓库无档位: ${key}`, 404);
    if (current.some((item) => item.key === newKey)) {
      return fail(res, 'CONFLICT', `目标档位已存在: ${newKey}`, 409);
    }
    const snapshotId = await versions.renameCurrentItem(key, newKey, { note });
    ok(res, { snapshotId, key, newKey });
  })
);

// diff：客户端传本地档位清单，返回与远端当前的差异。
app.post(
  '/api/config/diff',
  h(async (req, res) => {
    const local = (req.body && req.body.localItems) || [];
    let remote = await versions.getCurrentItems();
    if (!remote.length) remote = await scanLocalBundles();
    ok(res, { diff: diffItems(local, remote) });
  })
);

// ---- 版本快照 / 回滚 (FR-4) ----
// 历史版本列表（按时间倒序）：{ head, items:[{id,ts,note,parentId,keys[]}] }
app.get(
  '/api/snapshots',
  h(async (req, res) => {
    const limit = Number(req.query.limit || 50);
    ok(res, await versions.listSnapshots(limit));
  })
);

// 某快照详情（含各项 sha/size，不含 zip 大内容）。
app.get(
  '/api/snapshots/:id',
  h(async (req, res) => {
    const snap = await versions.getSnapshot(req.params.id);
    if (!snap) return fail(res, 'NOT_FOUND', `快照不存在: ${req.params.id}`, 404);
    ok(res, { ...snap.meta, items: snap.items });
  })
);

// 整体回滚到该版本（复制旧快照内容→新快照并指向）。
app.post(
  '/api/snapshots/:id/rollback',
  h(async (req, res) => {
    const { note } = req.body || {};
    const snapshotId = await versions.rollbackAll(req.params.id, { note });
    ok(res, { snapshotId });
  })
);

// 单文件回滚（从该版本取单个档位包覆盖当前内容集→新快照）。
app.post(
  '/api/snapshots/:id/rollback-file',
  h(async (req, res) => {
    const { key, note } = req.body || {};
    if (!isAllowedKey(key)) return fail(res, 'BAD_KEY', `非法档位: ${key}`);
    const snapshotId = await versions.rollbackFile(req.params.id, key, { note });
    ok(res, { snapshotId });
  })
);

app.use((_req, res) => fail(res, 'NOT_FOUND', 'route not found', 404));

app.listen(config.port, config.host, () => {
  console.log(`omo-switcher server: http://${config.host}:${config.port} (store=${storeMode()})`);
  console.log(`opencodeDir: ${config.opencodeDir}`);
});
