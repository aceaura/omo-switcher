// 档位打包：把"一个性能档位(slug)"涉及的文件打成一个自包含 zip。
// zip 成员 = 两个 provider 的档位文件 + 共享文件(opencode.jsonc / tui.json / package*.json)。
// 关键：确定性打包（固定时间戳/压缩级别）→ 内容不变则 zip 字节不变 → sha256 稳定 → diff 准确。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import JSZip from 'jszip';
import { config } from './config.js';

const FIXED_DATE = new Date('2000-01-01T00:00:00Z'); // 固定 mtime，保证确定性

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// 某档位涉及的成员文件（仅返回存在的）。返回 [{ name(zip内文件名), abs(绝对路径) }]
export function tierMemberFiles(slug) {
  const dir = config.opencodeDir;
  const members = [];
  for (const prov of Object.values(config.providers)) {
    // 找该 provider 对应该 slug 的档位文件： <prefix>.<n>-<slug>.json
    const re = new RegExp(`^${prov.prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.\\d+-${slug}\\.json$`);
    let entries = [];
    try { entries = fs.readdirSync(dir); } catch { entries = []; }
    const f = entries.find((e) => re.test(e));
    if (f) members.push({ name: f, abs: path.join(dir, f) });
  }
  for (const shared of config.bundle.sharedFiles) {
    const abs = path.join(dir, shared);
    if (fs.existsSync(abs)) members.push({ name: shared, abs });
  }
  return members;
}

// 简单脱敏：把 JSON(C) 文本里的 apiKey 值替换为 ***。
function redact(buf, name) {
  if (!config.bundle.redactSecrets) return buf;
  if (!/\.jsonc?$/.test(name)) return buf;
  const text = buf.toString('utf8');
  const masked = text
    .replace(/("apiKey"\s*:\s*")[^"]*(")/g, '$1***$2')
    .replace(/("authorization"\s*:\s*")[^"]*(")/gi, '$1***$2');
  return Buffer.from(masked, 'utf8');
}

// 为某档位构建 zip。返回 { slug, files:[name], contentB64, sha256, size }。
export async function buildTierBundle(slug) {
  const members = tierMemberFiles(slug);
  if (!members.length) throw new Error(`档位 "${slug}" 无任何成员文件`);
  const zip = new JSZip();
  const fileNames = [];
  for (const m of members) {
    const raw = redact(fs.readFileSync(m.abs), m.name);
    zip.file(m.name, raw, { date: FIXED_DATE, binary: true });
    fileNames.push(m.name);
  }
  const buf = await zip.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
    // platform 与 date 固定即可获得确定性输出
  });
  return {
    slug,
    files: fileNames.sort(),
    contentB64: buf.toString('base64'),
    sha256: sha256(buf),
    size: buf.length,
  };
}

// 列出所有"共享档位"(omo 与 slim 都存在的 slug)的包元数据（不含 zip 内容）。
export async function listTierBundles() {
  const dir = config.opencodeDir;
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch { entries = []; }
  // 收集各 provider 拥有的 slug
  const providerSlugs = {};
  for (const [id, prov] of Object.entries(config.providers)) {
    const re = new RegExp(`^${prov.prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.\\d+-([a-z0-9-]+)\\.json$`);
    providerSlugs[id] = new Set();
    for (const e of entries) {
      const m = re.exec(e);
      if (m) providerSlugs[id].add(m[1]);
    }
  }
  const providerIds = Object.keys(config.providers);
  const slugCount = new Map();
  for (const id of providerIds) for (const s of providerSlugs[id]) slugCount.set(s, (slugCount.get(s) || 0) + 1);

  const bundles = [];
  for (const [slug, count] of slugCount) {
    if (count !== providerIds.length) continue; // 仅共享档位
    const meta = config.tierMeta[slug] || { index: 999, label: slug, color: '#8b949e' };
    const b = await buildTierBundle(slug);
    bundles.push({
      slug,
      index: meta.index,
      label: meta.label,
      color: meta.color,
      files: b.files,
      sha256: b.sha256,
      size: b.size,
    });
  }
  bundles.sort((a, b) => a.index - b.index);
  return bundles;
}

// 校验 slug 是否为合法档位名（白名单，禁路径符）。
export function isAllowedSlug(slug) {
  if (typeof slug !== 'string' || !/^[a-z0-9-]+$/.test(slug)) return false;
  return Object.keys(config.tierMeta).includes(slug) || tierMemberFiles(slug).length > 0;
}
