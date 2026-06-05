// 验证：用 omo-switcher 自身代码路径检查 8 个新档位包。
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { getState } from '../src/presets.js';
import { extractTierBundle } from '../src/bundle.js';
import { validateTierFile } from '../src/validate.js';
import { config } from '../src/config.js';

const dir = config.opencodeDir;
const tmp = path.join(dir, `.verify-${process.pid}`);

// 1) listTierBundles + active 检测
const st = await getState();
console.log('档位列表（getState）:');
for (const t of st.tiers) console.log(`  [${t.index}] ${t.slug.padEnd(12)} ${t.label}  files=${t.files.length}`);
console.log('active:', JSON.stringify(st.active));

// 2) 对每个档位的两个 provider 文件跑真实 validateTierFile（与切换时同一守卫）
let bad = 0;
for (const t of st.tiers) {
  const bundle = await extractTierBundle(t.slug);
  for (const e of bundle.entries) {
    if (e.name !== 'oh-my-openagent.json' && e.name !== 'oh-my-opencode-slim.json') continue;
    fs.writeFileSync(tmp, e.content);
    const { ok, errors } = validateTierFile(tmp, dir);
    if (!ok) { bad++; console.log(`✗ ${t.slug}/${e.name}:`); errors.forEach((x) => console.log('   - ' + x)); }
  }
}
fs.rmSync(tmp, { force: true });
console.log(bad === 0 ? '✓ 8 档 × (omo+slim) 全部通过 validateTierFile（切换不会被拒）' : `✗ ${bad} 个文件未通过`);

// 3) 生效文件 == opus-high.zip 内同名条目（字节级）
const high = await extractTierBundle('opus-high');
for (const name of ['oh-my-openagent.json', 'oh-my-opencode-slim.json']) {
  const active = fs.readFileSync(path.join(dir, name));
  const entry = high.entries.find((e) => e.name === name).content;
  console.log(`  生效 ${name} ${active.equals(entry) ? '== opus-high.zip ✓' : '!= opus-high.zip ✗'}`);
}
process.exit(bad === 0 ? 0 : 1);
