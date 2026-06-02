// 档位打包：把"一个性能档位(slug)"涉及的文件打成一个自包含 zip。
// zip 成员 = 两个 provider 的档位文件 + 共享文件(opencode.jsonc / tui.json / package*.json)。
// 关键：确定性打包（固定时间戳/压缩级别）→ 内容不变则 zip 字节不变 → sha256 稳定 → diff 准确。
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import JSZip from 'jszip';
import { config } from './config.js';

const FIXED_DATE = new Date('2000-01-01T00:00:00Z');

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function zipPath(slug) {
  return path.join(config.opencodeDir, `${slug}.zip`);
}

export function allowedBundleNames() {
  const names = new Set(config.bundle.sharedFiles);
  for (const prov of Object.values(config.providers)) {
    names.add(`${prov.prefix}.json`);
  }
  return names;
}

function normalizeBundleName(slug, name) {
  if (allowedBundleNames().has(name)) return name;
  for (const prov of Object.values(config.providers)) {
    const re = new RegExp(`^${prov.prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.\\d+-${slug}\\.json$`);
    if (re.test(name)) return `${prov.prefix}.json`;
  }
  return null;
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

async function readZipMetadata(slug, buf) {
  const zip = await JSZip.loadAsync(buf);
  const files = [...new Set(Object.values(zip.files)
    .filter((entry) => !entry.dir)
    .map((entry) => normalizeBundleName(slug, entry.name) || entry.name))]
    .sort();
  return {
    key: slug,
    slug,
    index: config.tierMeta[slug]?.index ?? 999,
    label: config.tierMeta[slug]?.label || slug,
    color: config.tierMeta[slug]?.color || '#8b949e',
    files,
    contentB64: buf.toString('base64'),
    sha256: sha256(buf),
    size: buf.length,
  };
}

export async function buildTierBundle(slug) {
  const file = zipPath(slug);
  if (!fs.existsSync(file)) throw new Error(`档位 zip 不存在：${path.basename(file)}`);
  return readZipMetadata(slug, redact(fs.readFileSync(file), path.basename(file)));
}

function assertAllowedZipEntry(slug, name) {
  if (path.basename(name) !== name || !normalizeBundleName(slug, name)) {
    throw new Error(`zip 包含不允许写入的文件: ${name}`);
  }
}

async function normalizeZipBuffer(slug, buf) {
  const source = await JSZip.loadAsync(buf);
  const zip = new JSZip();
  const names = [];
  for (const entry of Object.values(source.files)) {
    if (entry.dir) continue;
    assertAllowedZipEntry(slug, entry.name);
    const name = normalizeBundleName(slug, entry.name);
    zip.file(name, await entry.async('nodebuffer'), { date: FIXED_DATE, binary: true });
    names.push(name);
  }
  if (!names.length) throw new Error(`档位 "${slug}" 没有可写入的文件`);
  return zip.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });
}

export async function writeTierBundle(slug, contentB64) {
  fs.mkdirSync(config.opencodeDir, { recursive: true });
  const buf = await normalizeZipBuffer(slug, Buffer.from(contentB64, 'base64'));
  const meta = await readZipMetadata(slug, buf);
  fs.writeFileSync(zipPath(slug), buf);
  return { key: slug, slug, files: meta.files, sha256: meta.sha256, size: meta.size };
}

export async function listTierBundles() {
  const dir = config.opencodeDir;
  let entries = [];
  try { entries = fs.readdirSync(dir); } catch { entries = []; }
  const bundles = [];
  for (const entry of entries) {
    if (!entry.endsWith('.zip')) continue;
    const slug = entry.slice(0, -'.zip'.length);
    if (!/^[a-z0-9-]+$/.test(slug)) continue;
    const b = await buildTierBundle(slug);
    bundles.push(b);
  }
  bundles.sort((a, b) => a.index - b.index);
  return bundles;
}

export function isAllowedSlug(slug) {
  if (typeof slug !== 'string' || !/^[a-z0-9-]+$/.test(slug)) return false;
  return Object.keys(config.tierMeta).includes(slug) || fs.existsSync(zipPath(slug));
}

export async function extractTierBundle(slug) {
  const bundle = await buildTierBundle(slug);
  const normalized = await normalizeZipBuffer(slug, Buffer.from(bundle.contentB64, 'base64'));
  const zip = await JSZip.loadAsync(normalized);
  const entries = [];
  for (const entry of Object.values(zip.files)) {
    if (entry.dir) continue;
    assertAllowedZipEntry(slug, entry.name);
    entries.push({ name: entry.name, content: await entry.async('nodebuffer') });
  }
  if (!entries.length) throw new Error(`档位 "${slug}" 没有可应用的文件`);
  return { ...bundle, entries };
}
