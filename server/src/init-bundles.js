// 一次性初始化：从 opencodeDir 中的散文件生成档位 zip 包。
// 用法：node src/init-bundles.js
import fs from 'node:fs';
import path from 'node:path';
import JSZip from 'jszip';
import { config } from './config.js';

const FIXED_DATE = new Date('2000-01-01T00:00:00Z');

async function createBundleFromDisk(slug) {
  const dir = config.opencodeDir;
  const zip = new JSZip();

  // 1. 两个 provider 的档位文件
  for (const prov of Object.values(config.providers)) {
    const meta = config.tierMeta[slug];
    if (!meta) throw new Error(`未知档位: ${slug}`);
    const tierFile = `${prov.prefix}.${meta.index}-${slug}.json`;
    const src = path.join(dir, tierFile);
    if (!fs.existsSync(src)) {
      console.warn(`  [skip] 缺失 ${tierFile}`);
      continue;
    }
    const content = fs.readFileSync(src);
    const targetName = `${prov.prefix}.json`; // 标准化名称
    zip.file(targetName, content, { date: FIXED_DATE, binary: true });
    console.log(`  [ok] ${tierFile} -> ${targetName}`);
  }

  // 2. 共享文件
  for (const name of config.bundle.sharedFiles) {
    const src = path.join(dir, name);
    if (!fs.existsSync(src)) {
      console.warn(`  [skip] 缺失共享文件 ${name}`);
      continue;
    }
    const content = fs.readFileSync(src);
    zip.file(name, content, { date: FIXED_DATE, binary: true });
    console.log(`  [ok] ${name}`);
  }

  const buf = await zip.generateAsync({
    type: 'nodebuffer',
    compression: 'DEFLATE',
    compressionOptions: { level: 6 },
  });
  const dest = path.join(dir, `${slug}.zip`);
  fs.writeFileSync(dest, buf);
  console.log(`  -> ${dest} (${buf.length} bytes)`);
}

const slugs = Object.keys(config.tierMeta);
console.log(`初始化档位包: ${slugs.join(', ')}`);
console.log(`目录: ${config.opencodeDir}\n`);

for (const slug of slugs) {
  console.log(`[${slug}]`);
  try {
    await createBundleFromDisk(slug);
  } catch (err) {
    console.error(`  失败: ${err.message}`);
  }
}

console.log('\n完成.');
