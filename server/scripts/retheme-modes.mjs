// retheme-modes.mjs
// 把 opencode 的 omo / slim 配置重构成两套「模式族」，每族 4 档（ultra/high/medium/low），
// 全部打包成符合 omo-switcher 标准的 zip 档位包，并把生效配置置为 opus-high。
//
//   OpusMode  = Claude Opus 4.8 + DeepSeek V4 Pro 为主，GPT-5.5 轻量辅助   → opus-ultra/high/medium/low
//   GptMode   = GPT-5.5 + DeepSeek V4 Pro 为主，Opus 4.8 轻量辅助          → gpt-ultra/high/medium/low
//
// 按「能力覆盖」分配角色，并按档位强度搭配便宜小模型；所有 (model,variant) 在写盘前
// 都对照 opencode.jsonc 自校验（与 server/src/validate.js 同规则），保证切换不被拒。
//
// 用法：node server/scripts/retheme-modes.mjs           # 执行（含备份）
//       node server/scripts/retheme-modes.mjs --dry-run # 只构建+校验+打印，不写盘
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

// ── 模型常量（均存在于 opencode.jsonc 的 newapi provider）──────────────────────
const M = {
  OP: 'newapi/claude-opus-4-8',     // 视觉, 1M, thinking 预算分档
  GPT: 'newapi/gpt-5.5',            // 视觉, 1M, reasoningEffort 分档
  DSP: 'newapi/deepseek-v4-pro',    // 纯文本, 1M, 强推理(low=不思考, max=最强)
  DSF: 'newapi/deepseek-v4-flash',  // 便宜快
  MM: 'newapi/minimax-m3',          // 便宜检索(有视觉)
  GF: 'newapi/gemini-3.5-flash',    // 便宜视觉
  KIMI: 'newapi/kimi-k2.6',         // 创作(有视觉)
  QWEN: 'newapi/qwen3.7-max',       // 写作(纯文本)
  MINI: 'newapi/gpt-5.4-mini',      // 便宜 gpt(有视觉)
  GLM: 'newapi/glm-5.1',            // 便宜推理
};
const LEVELS = ['ultra', 'high', 'medium', 'low'];

// ── 角色 → 各档位 [主模型, 变体, [[fb模型,变体]...]]；"P"=该族主力，"A"=轻量辅助 ──
// agents（11）：按能力覆盖。主驱动/规划=P；深推理/审查=DSP；视觉=P/GF；检索/快=便宜小模型。
const AGENTS = {
  'sisyphus':        { ultra:['P','max',[['DSP','max'],['A','high']]], high:['P','high',[['DSP','high'],['A','high']]], medium:['P','medium',[['DSP','high'],['A','medium']]], low:['DSP','high',[['P','medium']]] },
  'hephaestus':      { ultra:['P','high',[['DSP','high'],['A','high']]], high:['P','high',[['DSP','high']]], medium:['DSP','high',[['P','medium']]], low:['DSP','high',[['DSF','low']]] },
  'sisyphus-junior': { ultra:['DSP','high',[['P','medium'],['MINI','medium']]], high:['DSF','low',[['DSP','low'],['MINI','low']]], medium:['DSF','low',[['MM','low']]], low:['MINI','low',[['DSF','low'],['MM','low']]] },
  'prometheus':      { ultra:['P','max',[['DSP','max'],['A','high']]], high:['P','high',[['DSP','high']]], medium:['P','medium',[['DSP','high']]], low:['DSP','high',[['P','medium']]] },
  'metis':           { ultra:['P','high',[['DSP','high']]], high:['DSP','high',[['P','high']]], medium:['DSP','high',[['P','medium']]], low:['DSP','high',[['MM','medium']]] },
  'atlas':           { ultra:['P','high',[['A','high'],['DSP','high']]], high:['DSP','high',[['P','medium'],['A','medium']]], medium:['DSP','high',[['P','medium']]], low:['DSP','medium',[['MM','medium']]] },
  'oracle':          { ultra:['P','high',[['DSP','max']]], high:['DSP','max',[['P','high']]], medium:['DSP','high',[['P','high']]], low:['DSP','high',[['P','medium']]] },
  'momus':           { ultra:['P','high',[['DSP','max']]], high:['DSP','max',[['P','high']]], medium:['DSP','high',[['P','medium']]], low:['DSP','high',[['GLM','low']]] },
  'multimodal-looker':{ ultra:['P','high',[['GF','medium']]], high:['P','medium',[['GF','medium']]], medium:['GF','medium',[['P','medium']]], low:['GF','low',[['P','low']]] },
  'librarian':       { ultra:['MM','medium',[['GF','medium'],['DSP','high']]], high:['MM','medium',[['GF','medium']]], medium:['MM','low',[['GF','low']]], low:['MM','low',[['GF','low']]] },
  'explore':         { ultra:['MM','low',[['DSF','low'],['DSP','low']]], high:['MM','low',[['DSF','low']]], medium:['MM','low',[['DSF','low']]], low:['MM','low',[['DSF','low']]] },
};
// categories（8）
const CATS = {
  'visual-engineering':{ ultra:['P','high',[['GF','medium']]], high:['P','medium',[['GF','medium']]], medium:['GF','medium',[['P','medium']]], low:['GF','low',[['P','low']]] },
  'ultrabrain':      { ultra:['P','max',[['DSP','max'],['A','high']]], high:['DSP','max',[['P','high']]], medium:['DSP','max',[['P','high']]], low:['DSP','high',[['P','medium']]] },
  'deep':            { ultra:['DSP','max',[['P','high']]], high:['DSP','high',[['P','high']]], medium:['DSP','high',[['P','medium']]], low:['DSP','high',[['GLM','low']]] },
  'unspecified-high':{ ultra:['P','high',[['DSP','max']]], high:['DSP','high',[['P','high']]], medium:['DSP','high',[['P','medium']]], low:['DSP','medium',[['MINI','low']]] },
  'artistry':        { ultra:['KIMI','medium',[['P','high'],['QWEN','medium']]], high:['KIMI','medium',[['QWEN','medium'],['P','medium']]], medium:['KIMI','medium',[['QWEN','medium']]], low:['QWEN','low',[['KIMI','medium']]] },
  'writing':         { ultra:['P','high',[['QWEN','medium'],['DSP','high']]], high:['QWEN','medium',[['P','medium'],['DSP','high']]], medium:['QWEN','medium',[['DSP','medium']]], low:['QWEN','low',[['MM','medium']]] },
  'quick':           { ultra:['DSF','low',[['MINI','low'],['MM','low']]], high:['DSF','low',[['MINI','low']]], medium:['DSF','low',[['MM','low']]], low:['DSF','low',[['MM','low']]] },
  'unspecified-low': { ultra:['DSF','low',[['MINI','low'],['MM','low']]], high:['MINI','low',[['MM','low'],['GLM','low']]], medium:['MINI','low',[['MM','low']]], low:['MM','low',[['GLM','low']]] },
};
// slim 角色（单模型，无 fallback；skills/mcps 原样保留）
const SLIM_ROLES = {
  'orchestrator':{ ultra:['P','high'], high:['P','high'], medium:['DSP','high'], low:['DSP','medium'] },
  'oracle':      { ultra:['P','high'], high:['DSP','max'], medium:['DSP','high'], low:['DSP','high'] },
  'council':     { ultra:['P','high'], high:['DSP','max'], medium:['DSP','high'], low:['DSP','high'] },
  'librarian':   { ultra:['MM','medium'], high:['MM','medium'], medium:['MM','low'], low:['MM','low'] },
  'explorer':    { ultra:['MM','low'], high:['MM','low'], medium:['MM','low'], low:['MM','low'] },
  'designer':    { ultra:['P','medium'], high:['GF','medium'], medium:['GF','low'], low:['GF','low'] },
  'fixer':       { ultra:['DSF','low'], high:['DSF','low'], medium:['DSF','low'], low:['DSF','low'] },
  'observer':    { ultra:['DSP','medium'], high:['DSP','low'], medium:['KIMI','low'], low:['MM','low'] },
};

// 8 个档位定义：slug → { premium, assist, level }
const TIERS = {};
for (const lvl of LEVELS) {
  TIERS[`opus-${lvl}`] = { P: M.OP, A: M.GPT, level: lvl, mode: 'OpusMode' };
  TIERS[`gpt-${lvl}`] = { P: M.GPT, A: M.OP, level: lvl, mode: 'GptMode' };
}

function resolve(token, P, A) {
  if (token === 'P') return P;
  if (token === 'A') return A;
  if (M[token]) return M[token];
  throw new Error(`未知模型记号: ${token}`);
}
function agentEntry(spec, P, A) {
  const [m, v, fbs] = spec;
  return {
    model: resolve(m, P, A),
    variant: v,
    fallback_models: (fbs || []).map(([fm, fv]) => ({ model: resolve(fm, P, A), variant: fv })),
  };
}

// ── 读模板（当前生效文件）──────────────────────────────────────────────────────
function readJsonBom(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
}
const omoTemplate = readJsonBom(path.join(OPENCODE_DIR, OMO));
const slimTemplate = readJsonBom(path.join(OPENCODE_DIR, SLIM));

function buildOmo({ P, A, level }) {
  const cfg = structuredClone(omoTemplate);
  for (const [name, spec] of Object.entries(AGENTS)) {
    if (!cfg.agents?.[name]) throw new Error(`模板缺 agent: ${name}`);
    const e = agentEntry(spec[level], P, A);
    cfg.agents[name].model = e.model;
    cfg.agents[name].variant = e.variant;
    cfg.agents[name].fallback_models = e.fallback_models;
  }
  for (const [name, spec] of Object.entries(CATS)) {
    if (!cfg.categories?.[name]) throw new Error(`模板缺 category: ${name}`);
    const e = agentEntry(spec[level], P, A);
    cfg.categories[name].model = e.model;
    cfg.categories[name].variant = e.variant;
    cfg.categories[name].fallback_models = e.fallback_models;
  }
  return cfg;
}
function buildSlim({ P, A, level }) {
  const cfg = structuredClone(slimTemplate);
  for (const preset of Object.values(cfg.presets || {})) {
    for (const [role, node] of Object.entries(preset)) {
      const spec = SLIM_ROLES[role];
      if (!spec) continue; // 未知角色：保持原样
      const [m, v] = spec[level];
      node.model = resolve(m, P, A);
      node.variant = v;
    }
  }
  return cfg;
}

// ── 自校验：每个 (model,variant) 必须在 opencode.jsonc 定义（同 validate.js 规则）──
function stripJsonc(text) {
  let t = text.replace(/^﻿/, '');
  t = t.replace(/\/\*[\s\S]*?\*\//g, '');
  t = t.replace(/(^|[^:])\/\/[^\n]*/g, '$1');
  t = t.replace(/,(\s*[}\]])/g, '$1');
  return t;
}
function loadDefinedModels() {
  const oc = JSON.parse(stripJsonc(fs.readFileSync(path.join(OPENCODE_DIR, 'opencode.jsonc'), 'utf8')));
  const defined = new Map();
  for (const [pid, p] of Object.entries(oc.provider || {})) {
    for (const [mid, mm] of Object.entries(p.models || {})) {
      defined.set(`${pid}/${mid}`, new Set(Object.keys(mm.variants || {})));
    }
  }
  return defined;
}
function collectRefs(cfg) {
  const refs = [];
  const visit = (node, where) => {
    if (!node || typeof node !== 'object') return;
    if (typeof node.model === 'string') refs.push({ model: node.model, variant: node.variant ?? null, where });
    if (Array.isArray(node.fallback_models)) node.fallback_models.forEach((fb, i) => {
      if (fb && typeof fb.model === 'string') refs.push({ model: fb.model, variant: fb.variant ?? null, where: `${where}.fb[${i}]` });
    });
  };
  for (const s of ['agents', 'categories']) for (const [n, node] of Object.entries(cfg[s] || {})) visit(node, `${s}.${n}`);
  for (const [pn, pr] of Object.entries(cfg.presets || {})) for (const [r, node] of Object.entries(pr || {})) visit(node, `presets.${pn}.${r}`);
  return refs;
}
function validate(slug, cfg, defined) {
  const errs = [];
  for (const { model, variant, where } of collectRefs(cfg)) {
    const vs = defined.get(model);
    if (!vs) errs.push(`${slug} ${where}: model 未定义「${model}」`);
    else if (variant != null && !vs.has(variant)) errs.push(`${slug} ${where}: 「${model}」无 variant「${variant}」`);
  }
  return errs;
}

function serialize(cfg) {
  return BOM + JSON.stringify(cfg, null, 2) + '\n';
}

// ── 构建全部 8 档（内存）+ 校验 ───────────────────────────────────────────────
const defined = loadDefinedModels();
const built = {}; // slug -> { omoText, slimText, omoCfg, slimCfg }
const allErrs = [];
for (const [slug, t] of Object.entries(TIERS)) {
  const omoCfg = buildOmo(t);
  const slimCfg = buildSlim(t);
  allErrs.push(...validate(slug, omoCfg, defined), ...validate(slug, slimCfg, defined));
  built[slug] = { omoText: serialize(omoCfg), slimText: serialize(slimCfg), omoCfg, slimCfg };
}
if (allErrs.length) {
  console.error('✗ 校验失败，未写盘：');
  for (const e of allErrs) console.error('  - ' + e);
  process.exit(1);
}
console.log(`✓ 8 档全部通过 (model,variant) 校验（共 ${Object.keys(TIERS).length} 档）`);

// 打印一览
for (const [slug, t] of Object.entries(TIERS)) {
  const c = built[slug].omoCfg;
  const row = (k, node) => `${k}=${node.model.replace('newapi/', '')}:${node.variant}`;
  console.log(`\n── ${slug} (${t.mode} · ${t.level}) ──`);
  console.log('  ' + ['sisyphus','prometheus','oracle','momus','multimodal-looker'].map(k => row(k, c.agents[k])).join('  '));
  console.log('  ' + ['ultrabrain','deep','visual-engineering','quick'].map(k => row(k, c.categories[k])).join('  '));
}

if (DRY) { console.log('\n[dry-run] 未写盘。'); process.exit(0); }

// ── 备份 ──────────────────────────────────────────────────────────────────────
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const backupDir = path.join(OPENCODE_DIR, '_backup', stamp);
fs.mkdirSync(backupDir, { recursive: true });
const OLD_ZIPS = ['token-saving.zip', 'predictable-cost.zip', 'balanced.zip', 'quality-first.zip'];
for (const f of [...OLD_ZIPS, OMO, SLIM]) {
  const src = path.join(OPENCODE_DIR, f);
  if (fs.existsSync(src)) fs.copyFileSync(src, path.join(backupDir, f));
}
console.log(`\n✓ 备份 → ${backupDir}`);

// ── 打包 8 个 zip（确定性：FIXED_DATE + DEFLATE6，与 server/src/bundle.js 一致）──
const sharedBufs = {};
for (const f of SHARED) {
  const p = path.join(OPENCODE_DIR, f);
  if (fs.existsSync(p)) sharedBufs[f] = fs.readFileSync(p);
}
for (const [slug, b] of Object.entries(built)) {
  const zip = new JSZip();
  zip.file(OMO, Buffer.from(b.omoText, 'utf8'), { date: FIXED_DATE, binary: true });
  zip.file(SLIM, Buffer.from(b.slimText, 'utf8'), { date: FIXED_DATE, binary: true });
  for (const [f, buf] of Object.entries(sharedBufs)) zip.file(f, buf, { date: FIXED_DATE, binary: true });
  const out = await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE', compressionOptions: { level: 6 } });
  fs.writeFileSync(path.join(OPENCODE_DIR, `${slug}.zip`), out);
  console.log(`  ✓ ${slug}.zip (${out.length} B)`);
}

// ── 删除旧的 4 档 zip（已备份）──────────────────────────────────────────────────
for (const f of OLD_ZIPS) {
  const p = path.join(OPENCODE_DIR, f);
  if (fs.existsSync(p)) { fs.rmSync(p); console.log(`  ✓ 移除旧档 ${f}`); }
}

// ── 置生效配置 = opus-high（与 opus-high.zip 内同名条目字节一致）─────────────────
const ACTIVE = 'opus-high';
fs.writeFileSync(path.join(OPENCODE_DIR, OMO), Buffer.from(built[ACTIVE].omoText, 'utf8'));
fs.writeFileSync(path.join(OPENCODE_DIR, SLIM), Buffer.from(built[ACTIVE].slimText, 'utf8'));
console.log(`\n✓ 生效配置已置为 ${ACTIVE}（重启 opencode 生效）`);
console.log('完成。');
