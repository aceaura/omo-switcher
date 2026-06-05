// 远端配置快照版本库（FR-4）。按时间戳保留所有历史版本，支持整体/单文件回滚。
// 存储在 Redis；无 Redis 时退回进程内内存（与 store.js 一致风格）。
import crypto from 'node:crypto';
import { config } from './config.js';
import { getRedis } from './store.js';

const P = config.redis.keyPrefix;
const K_SNAPSHOTS = `${P}snapshots`; // zset: member=id, score=ts
const K_HEAD = `${P}remote:head`; // string: 当前指针 snapshotId
const kMeta = (id) => `${P}snapshot:${id}`;
const kItems = (id) => `${P}snapshot:${id}:items`;

// 内存退回库
const mem = {
  snapshots: new Map(), // id -> { meta, items: Map<key, {contentB64,sha256,size}> }
  order: [], // [{id, ts}]
  head: null,
};

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function makeId(items) {
  const fingerprint = sha256(
    Buffer.from(items.map((i) => `${i.key}:${i.sha256}`).sort().join('|'))
  ).slice(0, 8);
  return `${Date.now()}-${fingerprint}`;
}

// items: [{ key, contentB64, sha256?, size? }]
export async function createSnapshot(items, { note = '', author = '', parentId = null } = {}) {
  const normalized = items.map((i) => {
    const buf = Buffer.from(i.contentB64, 'base64');
    return {
      key: i.key,
      contentB64: i.contentB64,
      sha256: i.sha256 || sha256(buf),
      size: i.size ?? buf.length,
    };
  });
  const id = makeId(normalized);
  const ts = Date.now();
  const meta = { id, ts, note, author, parentId };

  const redis = getRedis();
  if (redis) {
    const pipe = redis.pipeline();
    pipe.zadd(K_SNAPSHOTS, ts, id);
    pipe.hset(kMeta(id), meta);
    const itemHash = {};
    for (const it of normalized) itemHash[it.key] = JSON.stringify(it);
    if (Object.keys(itemHash).length) pipe.hset(kItems(id), itemHash);
    pipe.set(K_HEAD, id);
    await pipe.exec();
  } else {
    mem.snapshots.set(id, { meta, items: new Map(normalized.map((i) => [i.key, i])) });
    mem.order.push({ id, ts });
    mem.head = id;
  }
  return id;
}

export async function getHead() {
  const redis = getRedis();
  if (redis) return await redis.get(K_HEAD);
  return mem.head;
}

export async function listSnapshots(limit = 50) {
  const redis = getRedis();
  if (redis) {
    const ids = await redis.zrevrange(K_SNAPSHOTS, 0, limit - 1);
    const items = [];
    for (const id of ids) {
      const meta = await redis.hgetall(kMeta(id));
      const keys = await redis.hkeys(kItems(id));
      items.push({ ...meta, ts: Number(meta.ts), keys });
    }
    return { head: await getHead(), items };
  }
  const ordered = [...mem.order].sort((a, b) => b.ts - a.ts).slice(0, limit);
  const items = ordered.map(({ id }) => {
    const s = mem.snapshots.get(id);
    return { ...s.meta, keys: [...s.items.keys()] };
  });
  return { head: mem.head, items };
}

export async function getSnapshot(id) {
  const redis = getRedis();
  if (redis) {
    const meta = await redis.hgetall(kMeta(id));
    if (!meta || !meta.id) return null;
    const raw = await redis.hgetall(kItems(id));
    const items = Object.entries(raw).map(([key, v]) => {
      const o = JSON.parse(v);
      return { key, sha256: o.sha256, size: o.size };
    });
    return { meta: { ...meta, ts: Number(meta.ts) }, items };
  }
  const s = mem.snapshots.get(id);
  if (!s) return null;
  return {
    meta: s.meta,
    items: [...s.items.values()].map((i) => ({ key: i.key, sha256: i.sha256, size: i.size })),
  };
}

export async function getSnapshotItem(id, key) {
  const redis = getRedis();
  if (redis) {
    const v = await redis.hget(kItems(id), key);
    return v ? JSON.parse(v) : null;
  }
  const s = mem.snapshots.get(id);
  return s ? s.items.get(key) || null : null;
}

// 取“当前 head 快照”的全部配置项（含内容）。无快照则返回 []（调用方可退回扫文件系统）。
export async function getCurrentItems() {
  const head = await getHead();
  if (!head) return [];
  const redis = getRedis();
  if (redis) {
    const raw = await redis.hgetall(kItems(head));
    return Object.values(raw).map((v) => JSON.parse(v));
  }
  const s = mem.snapshots.get(head);
  return s ? [...s.items.values()] : [];
}

export async function deleteCurrentItems(keys, { note = '' } = {}) {
  const keySet = new Set(keys);
  const current = await getCurrentItems();
  const remaining = current.filter((item) => !keySet.has(item.key));
  return createSnapshot(remaining, {
    note: note || `delete ${keys.join(', ')}`,
    parentId: await getHead(),
  });
}

export async function renameCurrentItem(fromKey, toKey, { note = '' } = {}) {
  const current = await getCurrentItems();
  const found = current.find((item) => item.key === fromKey);
  if (!found) throw new Error(`当前云端仓库无档位：${fromKey}`);
  if (current.some((item) => item.key === toKey)) throw new Error(`目标档位已存在：${toKey}`);
  const renamed = current.map((item) =>
    item.key === fromKey ? { ...item, key: toKey, slug: toKey, tierSlug: toKey } : item
  );
  return createSnapshot(renamed, {
    note: note || `rename ${fromKey} to ${toKey}`,
    parentId: await getHead(),
  });
}

async function getAllItemsOfSnapshot(id) {
  const redis = getRedis();
  if (redis) {
    const raw = await redis.hgetall(kItems(id));
    return Object.values(raw).map((v) => JSON.parse(v));
  }
  const s = mem.snapshots.get(id);
  return s ? [...s.items.values()] : [];
}

// 整体回滚：复制旧快照全部内容生成新快照并指向（保留可追溯 parentId）。
export async function rollbackAll(id, { note = '' } = {}) {
  const items = await getAllItemsOfSnapshot(id);
  if (!items.length) throw new Error(`快照不存在或为空：${id}`);
  return createSnapshot(items, { note: note || `rollback-all from ${id}`, parentId: id });
}

// 单文件回滚：以“当前 head 内容集”为基底，仅把指定 key 替换为旧快照中的内容，生成新快照。
export async function rollbackFile(id, key, { note = '' } = {}) {
  const old = await getSnapshotItem(id, key);
  if (!old) throw new Error(`快照 ${id} 中无文件：${key}`);
  const base = await getCurrentItems();
  const map = new Map(base.map((i) => [i.key, i]));
  map.set(key, old);
  return createSnapshot([...map.values()], {
    note: note || `rollback-file ${key} from ${id}`,
    parentId: await getHead(),
  });
}
