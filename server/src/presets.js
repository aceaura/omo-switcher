// 扫描 opencode 配置目录，列出可用的性能档位，并通过字节比对判断当前生效档位。
import fs from 'node:fs';
import path from 'node:path';
import { config, activeFileName } from './config.js';
import { listTierBundles, extractTierBundle } from './bundle.js';

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

function detectActive(prefix, bundles) {
  const baseFile = path.join(config.opencodeDir, activeFileName(prefix));
  const baseBytes = readBytes(baseFile);
  if (!baseBytes) return null;
  const memberName = activeFileName(prefix);
  for (const bundle of bundles) {
    const entry = bundle.entries.find((item) => item.name === memberName);
    if (entry && entry.content.equals(baseBytes)) return bundle.slug;
  }
  return null;
}

// 汇总状态：tiers 是 omo / slim 共享的档位列表（按 index 排序），
// active 给出每个 provider 当前档位及二者是否一致(shared)。
export async function getState() {
  const bundles = [];
  for (const item of await listTierBundles()) bundles.push(await extractTierBundle(item.slug));
  const tiers = bundles.map((bundle) => ({
    slug: bundle.slug,
    index: bundle.index,
    label: bundle.label,
    color: bundle.color,
    shared: true,
    files: bundle.files,
  }));
  const active = {};
  for (const [id, prov] of Object.entries(config.providers)) {
    active[id] = detectActive(prov.prefix, bundles);
  }
  const distinct = new Set(Object.values(active));
  active.shared = distinct.size === 1 ? [...distinct][0] : null;

  return {
    opencodeDir: config.opencodeDir,
    providers: config.providers,
    tiers,
    active,
  };
}

export async function resolveSwitch(slug) {
  const bundle = await extractTierBundle(slug);
  return bundle.entries.map((entry) => ({
    name: entry.name,
    content: entry.content,
    to: path.join(config.opencodeDir, entry.name),
  }));
}
