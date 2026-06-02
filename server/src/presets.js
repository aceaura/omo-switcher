// 扫描 opencode 配置目录，列出可用的性能档位，并通过字节比对判断当前生效档位。
import fs from 'node:fs';
import path from 'node:path';
import { config, activeFileName } from './config.js';

// 解析形如 `oh-my-openagent.3-balanced.json` 的文件名。
// 返回 { index, slug } 或 null。
function parseTierFile(prefix, fileName) {
  if (!fileName.startsWith(prefix + '.') || !fileName.endsWith('.json')) return null;
  const middle = fileName.slice(prefix.length + 1, -'.json'.length); // e.g. "3-balanced"
  const m = /^(\d+)-(.+)$/.exec(middle);
  if (!m) return null; // 跳过 `<prefix>.json` 这种当前生效文件
  return { index: Number(m[1]), slug: m[2] };
}

function readBytes(file) {
  try {
    return fs.readFileSync(file);
  } catch {
    return null;
  }
}

// 返回每个 provider 下所有档位文件： { [providerId]: Map<slug, {index, slug, file}> }
function scanProviderTiers() {
  const dir = config.opencodeDir;
  let entries = [];
  try {
    entries = fs.readdirSync(dir);
  } catch (err) {
    throw new Error(`无法读取 opencode 配置目录 ${dir}: ${err.message}`);
  }
  const result = {};
  for (const [providerId, prov] of Object.entries(config.providers)) {
    const map = new Map();
    for (const f of entries) {
      const parsed = parseTierFile(prov.prefix, f);
      if (parsed) map.set(parsed.slug, { ...parsed, file: path.join(dir, f) });
    }
    result[providerId] = map;
  }
  return result;
}

// 找出某 provider 当前生效的档位（base 文件与哪个档位文件字节一致）。
function detectActive(prefix, tierMap) {
  const baseFile = path.join(config.opencodeDir, activeFileName(prefix));
  const baseBytes = readBytes(baseFile);
  if (!baseBytes) return null;
  for (const [slug, t] of tierMap) {
    const b = readBytes(t.file);
    if (b && b.equals(baseBytes)) return slug;
  }
  return null;
}

// 汇总状态：tiers 是 omo / slim 共享的档位列表（按 index 排序），
// active 给出每个 provider 当前档位及二者是否一致(shared)。
export function getState() {
  const perProvider = scanProviderTiers();

  // 共享档位 = 所有 provider 都存在的 slug。
  const providerIds = Object.keys(config.providers);
  const slugCount = new Map();
  for (const id of providerIds) {
    for (const slug of perProvider[id].keys()) {
      slugCount.set(slug, (slugCount.get(slug) || 0) + 1);
    }
  }

  const tiers = [];
  for (const [slug, count] of slugCount) {
    const meta = config.tierMeta[slug] || { index: 999, label: slug, color: '#8b949e' };
    const files = {};
    for (const id of providerIds) {
      const t = perProvider[id].get(slug);
      files[id] = t ? path.basename(t.file) : null;
    }
    tiers.push({
      slug,
      index: meta.index,
      label: meta.label,
      color: meta.color,
      shared: count === providerIds.length, // 两个 provider 都有 -> 可共享切换
      files,
    });
  }
  tiers.sort((a, b) => a.index - b.index);

  const active = {};
  for (const id of providerIds) {
    active[id] = detectActive(config.providers[id].prefix, perProvider[id]);
  }
  // 共享视角：omo 与 slim 档位一致时返回该 slug，否则 null（说明被手动改乱了）。
  const distinct = new Set(Object.values(active));
  active.shared = distinct.size === 1 ? [...distinct][0] : null;

  return {
    opencodeDir: config.opencodeDir,
    providers: config.providers,
    tiers,
    active,
  };
}

// 取得某 provider 指定档位的源文件与目标(当前生效)文件路径。
export function resolveSwitch(slug) {
  const perProvider = scanProviderTiers();
  const plan = [];
  for (const [id, prov] of Object.entries(config.providers)) {
    const tier = perProvider[id].get(slug);
    if (!tier) {
      throw new Error(`provider ${id} 不存在档位 "${slug}"`);
    }
    plan.push({
      providerId: id,
      from: tier.file,
      to: path.join(config.opencodeDir, activeFileName(prov.prefix)),
    });
  }
  return plan;
}
