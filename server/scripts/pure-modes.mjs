// pure-modes.mjs
// 生成 4 个「纯单模型」档位包（每个模型一个 zip，所有角色都用同一个模型）：
//   pure-deepseek (deepseek-v4-pro) / pure-qwen (qwen3.7-max) /
//   pure-opus (claude-opus-4-8)     / pure-gpt (gpt-5.5)
// 重型角色 variant=high，轻型角色(检索/快/junior) variant=low，无跨模型 fallback。
// 注意：deepseek-v4-pro 与 qwen3.7-max 为纯文本，纯版里视觉角色也用该模型，图像任务会退化。
// 非破坏性：只新增 4 个 zip，不改生效配置、不删任何东西。
//   node server/scripts/pure-modes.mjs [--dry-run]
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import JSZip from 'jszip';

const DRY = process.argv.includes('--dry-run');
const OPENCODE_DIR = process.env.OPENCODE_DIR || path.join(os.homedir(), '.config', 'opencode');
const FIXED_DATE = new Date('2000-01-01T00:00:00Z');
const BOM = '﻿';
const SHARED = ['opencode.jsonc', 'tui.json', 'package.json', 'package-lock.json'];
const OMO = 'oh-my-openagent.json';
const SLIM = 'oh-my-opencode-slim.json';

// slug -> { model, label, color }
const FAMILIES = {
  'pure-deepseek': { model: 'newapi/deepseek-v4-pro', label: 'Pure DeepSeek V4 Pro', color: '#a371f7' },
  'pure-qwen':     { model: 'newapi/qwen3.7-max',     label: 'Pure Qwen3.7-max',     color: '#e3b341' },
  'pure-opus':     { model: 'newapi/claude-opus-4-8', label: 'Pure Opus 4.8',        color: '#f85149' },
  'pure-gpt':      { model: 'newapi/gpt-5.5',         label: 'Pure GPT-5.5',         color: '#3fb950' },
};

// 轻型角色（用 low 变体省钱）；其余为重型（high）。
const LIGHT_AGENTS = new Set(['sisyphus-junior', 'librarian', 'explore']);
const LIGHT_CATS = new Set(['quick', 'unspecified-low']);
const LIGHT_SLIM = new Set(['librarian', 'explorer', 'fixer', 'observer']);

function readJsonBom(file) { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, '')); }
const omoTemplate = readJsonBom(path.join(OPENCODE_DIR, OMO));
const slimTemplate = readJsonBom(path.join(OPENCODE_DIR, SLIM));

function buildOmo(model) {
  const cfg = structuredClone(omoTemplate);
  for (const [name, node] of Object.entries(cfg.agents || {})) {
    node.model = model; node.variant = LIGHT_AGENTS.has(name) ? 'low' : 'high'; node.fallback_models = [];
  }
  for (const [name, node] of Object.entries(cfg.categories || {})) {
    node.model = model; node.variant = LIGHT_CATS.has(name) ? 'low' : 'high'; node.fallback_models = [];
  }
  return cfg;
}
function buildSlim(model) {
  const cfg = structuredClone(slimTemplate);
  for (const preset of Object.values(cfg.presets || {})) {
    for (const [role, node] of Object.entries(preset)) {
      node.model = model; node.variant = LIGHT_SLIM.has(role) ? 'low' : 'high';
    }
  }
  return cfg;
}

// 自校验：(model,variant) 必须在 opencode.jsonc 定义（同 server/src/validate.js）。
function stripJsonc(t) {
  return t.replace(/^﻿/, '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/[^\n]*/g, '$1').replace(/,(\s*[}\]])/g, '$1');
}
function loadDefinedModels() {
  const oc = JSON.parse(stripJsonc(fs.readFileSync(path.join(OPENCODE_DIR, 'opencode.jsonc'), 'utf8')));
  const d = new Map();
  for (const [pid, p] of Object.entries(oc.provider || {}))
    for (const [mid, mm] of Object.entries(p.models || {})) d.set(`${pid}/${mid}`, new Set(Object.keys(mm.variants || {})));
  return d;
}
function refs(cfg) {
  const out = [];
  const visit = (n, w) => { if (n && typeof n === 'object' && typeof n.model === 'string') out.push({ model: n.model, variant: n.variant ?? null, where: w }); };
  for (const s of ['agents', 'categories']) for (const [n, node] of Object.entries(cfg[s] || {})) visit(node, `${s}.${n}`);
  for (const [pn, pr] of Object.entries(cfg.presets || {})) for (const [r, node] of Object.entries(pr || {})) visit(node, `presets.${pn}.${r}`);
  return out;
}
const serialize = (cfg) => BOM + JSON.stringify(cfg, null, 2) + '\n';

const defined = loadDefinedModels();
const built = {};
const errs = [];
for (const [slug, fam] of Object.entries(FAMILIES)) {
  const omoCfg = buildOmo(fam.model), slimCfg = buildSlim(fam.model);
  for (const cfg of [omoCfg, slimCfg]) for (const { model, variant, where } of refs(cfg)) {
    const vs = defined.get(model);
    if (!vs) errs.push(`${slug} ${where}: model 未定义「${model}」`);
    else if (variant != null && !vs.has(variant)) errs.push(`${slug} ${where}: 「${model}」无 variant「${variant}」`);
  }
  built[slug] = { omoText: serialize(omoCfg), slimText: serialize(slimCfg) };
}
if (errs.length) { console.error('✗ 校验失败，未写盘：'); errs.forEach(e => console.error('  - ' + e)); process.exit(1); }
console.log(`✓ ${Object.keys(FAMILIES).length} 个纯版本全部通过 (model,variant) 校验`);
for (const [slug, fam] of Object.entries(FAMILIES)) console.log(`  ${slug.padEnd(14)} → ${fam.model}  (重型=high, 轻型=low)`);

if (DRY) { console.log('\n[dry-run] 未写盘。'); process.exit(0); }

const sharedBufs = {};
for (const f of SHARED) { const p = path.join(OPENCODE_DIR, f); if (fs.existsSync(p)) sharedBufs[f] = fs.readFileSync(p); }
for (const [slug, b] of Object.entries(built)) {
  const zip = new JSZip();
  zip.file(OMO, Buffer.from(b.omoText, 'utf8'), { date: FIXED_DATE, binary: true });
  zip.file(SLIM, Buffer.from(b.slimText, 'utf8'), { date: FIXED_DATE, binary: true });
  for (const [f, buf] of Object.entries(sharedBufs)) zip.file(f, buf, { date: FIXED_DATE, binary: true });
  const out = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 6 } });
  fs.writeFileSync(path.join(OPENCODE_DIR, `${slug}.zip`), out);
  console.log(`  ✓ ${slug}.zip (${out.length} B)`);
}
console.log('\n完成（生效配置未改动）。');
