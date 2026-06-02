// 同步辅助（FR-3）：同步单位为"档位包(zip)"，以 slug 为 key。
import { listTierBundles, buildTierBundle, isAllowedSlug, writeTierBundle } from './bundle.js';

// key 白名单：现在 key 即档位 slug。
export function isAllowedKey(key) {
  return isAllowedSlug(key);
}

// 远端"当前"档位包清单（不含 zip 内容）。key=slug。
export async function scanLocalBundles() {
  const bundles = await listTierBundles();
  return bundles.map((b) => ({
    key: b.slug,
    slug: b.slug,
    index: b.index,
    label: b.label,
    color: b.color,
    files: b.files,
    sha256: b.sha256,
    size: b.size,
  }));
}

// 取单个档位包（含 zip 内容）。
export async function buildLocalBundle(slug) {
  const b = await buildTierBundle(slug);
  return { key: b.slug, ...b };
}

export async function applyLocalBundle(slug, contentB64) {
  return writeTierBundle(slug, contentB64);
}

// 按 sha256 计算两组配置项差异（key 通用，对 slug 同样适用）。
export function diffItems(localItems, remoteItems) {
  const l = new Map(localItems.map((i) => [i.key, i.sha256]));
  const r = new Map(remoteItems.map((i) => [i.key, i.sha256]));
  const onlyLocal = [], onlyRemote = [], changed = [], same = [];
  for (const [k, sh] of l) {
    if (!r.has(k)) onlyLocal.push(k);
    else if (r.get(k) !== sh) changed.push(k);
    else same.push(k);
  }
  for (const k of r.keys()) if (!l.has(k)) onlyRemote.push(k);
  return { onlyLocal, onlyRemote, changed, same };
}
