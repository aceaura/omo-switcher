// 同步辅助（FR-3）：扫描本机 tier 文件为“配置项”，并提供 diff 与 key 白名单校验。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { config } from './config.js';

// 合法 key 白名单：只允许 8 个 tier 文件（2 provider × 4 档），禁止路径分隔符。
export function isAllowedKey(key) {
  if (typeof key !== 'string' || key.includes('/') || key.includes('\\') || key.includes('..')) {
    return false;
  }
  for (const prov of Object.values(config.providers)) {
    if (new RegExp(`^${escapeRe(prov.prefix)}\\.\\d+-[a-z0-9-]+\\.json$`).test(key)) return true;
  }
  return false;
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function providerOfKey(key) {
  for (const [id, prov] of Object.entries(config.providers)) {
    if (key.startsWith(prov.prefix + '.')) return id;
  }
  return null;
}

function parseTier(key) {
  const m = /\.(\d+)-([a-z0-9-]+)\.json$/.exec(key);
  return m ? { tierIndex: Number(m[1]), tierSlug: m[2] } : { tierIndex: null, tierSlug: null };
}

// 扫描文件系统上的全部 tier 文件，返回带内容的配置项数组。
export function scanLocalConfigItems({ withContent = true } = {}) {
  const dir = config.opencodeDir;
  let entries = [];
  try {
    entries = fs.readdirSync(dir);
  } catch {
    return [];
  }
  const items = [];
  for (const f of entries) {
    if (!isAllowedKey(f)) continue;
    const full = path.join(dir, f);
    const buf = fs.readFileSync(full);
    const sha = crypto.createHash('sha256').update(buf).digest('hex');
    const { tierIndex, tierSlug } = parseTier(f);
    const item = {
      key: f,
      provider: providerOfKey(f),
      tierSlug,
      tierIndex,
      sha256: sha,
      size: buf.length,
    };
    if (withContent) item.contentB64 = buf.toString('base64');
    items.push(item);
  }
  return items;
}

// 按 sha256 计算两组配置项差异。
export function diffItems(localItems, remoteItems) {
  const l = new Map(localItems.map((i) => [i.key, i.sha256]));
  const r = new Map(remoteItems.map((i) => [i.key, i.sha256]));
  const onlyLocal = [];
  const onlyRemote = [];
  const changed = [];
  const same = [];
  for (const [k, sh] of l) {
    if (!r.has(k)) onlyLocal.push(k);
    else if (r.get(k) !== sh) changed.push(k);
    else same.push(k);
  }
  for (const k of r.keys()) if (!l.has(k)) onlyRemote.push(k);
  return { onlyLocal, onlyRemote, changed, same };
}
