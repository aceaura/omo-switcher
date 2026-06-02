// 档位文件写入前校验：在 applyTier 字节复制到 base 之前，确保该档位文件没有
// 损坏的 model / 非法 variant。历史上曾出现某外部 PowerShell 生成器把
// fallback_models 的对象逐字符切碎（如 {"model":"n","variant":"e"}），
// 导致回退链全部失效。本守卫负责拦截这类文件，避免污染生效配置。
import fs from 'node:fs';
import path from 'node:path';

// reasoningEffort / variant 合法档位（与 opencode 内置档位一致）。
const VALID_VARIANTS = new Set([
  'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max',
]);

// 一个合法的 model id 形如 `<provider>/<model>`：含且仅含一个层级分隔，
// 不含空白，两侧非空。可拦截 "n" / "m" / "lo" 之类被切碎的垃圾。
function looksLikeModelId(s) {
  return typeof s === 'string' && /^[^\s/]+\/[^\s]+$/.test(s) && s.length > 3;
}

function stripJsonc(text) {
  // 去 BOM、块注释、行注释（保留 URL 中的 ://）、尾逗号。
  let t = text.replace(/^﻿/, '');
  t = t.replace(/\/\*[\s\S]*?\*\//g, '');
  t = t.replace(/(^|[^:])\/\/[^\n]*/g, '$1');
  t = t.replace(/,(\s*[}\]])/g, '$1');
  return t;
}

// 从 opencode.jsonc 读取每个 provider/model 定义的 variant 集合。
// 解析失败时返回 null —— 此时只做结构校验，不做语义校验。
function loadDefinedModels(opencodeDir) {
  try {
    const file = path.join(opencodeDir, 'opencode.jsonc');
    const raw = fs.readFileSync(file, 'utf8');
    const oc = JSON.parse(stripJsonc(raw));
    const defined = new Map();
    for (const [pid, p] of Object.entries(oc.provider || {})) {
      for (const [mid, mm] of Object.entries(p.models || {})) {
        defined.set(`${pid}/${mid}`, new Set(Object.keys(mm.variants || {})));
      }
    }
    return defined.size ? defined : null;
  } catch {
    return null;
  }
}

// 收集一个档位配置里所有 (model, variant) 引用点。
function collectRefs(cfg) {
  const refs = [];
  const visit = (node, where) => {
    if (!node || typeof node !== 'object') return;
    if (typeof node.model === 'string') {
      refs.push({ model: node.model, variant: node.variant ?? null, where });
    }
    const fbs = node.fallback_models;
    if (Array.isArray(fbs)) {
      fbs.forEach((fb, i) => {
        if (typeof fb === 'string') refs.push({ model: fb, variant: null, where: `${where}.fallback[${i}]` });
        else if (fb && typeof fb === 'object' && typeof fb.model === 'string') {
          refs.push({ model: fb.model, variant: fb.variant ?? null, where: `${where}.fallback[${i}]` });
        }
      });
    }
  };
  for (const sect of ['agents', 'categories']) {
    for (const [name, node] of Object.entries(cfg[sect] || {})) visit(node, `${sect}.${name}`);
  }
  for (const [pname, preset] of Object.entries(cfg.presets || {})) {
    if (preset && typeof preset === 'object') {
      for (const [ag, node] of Object.entries(preset)) visit(node, `presets.${pname}.${ag}`);
    }
  }
  return refs;
}

// 校验单个档位文件。返回 { ok, errors[] }。
export function validateTierFile(filePath, opencodeDir) {
  const errors = [];
  let cfg;
  try {
    cfg = JSON.parse(fs.readFileSync(filePath, 'utf8').replace(/^﻿/, ''));
  } catch (e) {
    return { ok: false, errors: [`JSON 解析失败：${e.message}`] };
  }

  const defined = loadDefinedModels(opencodeDir);
  const refs = collectRefs(cfg);

  for (const { model, variant, where } of refs) {
    // 结构校验（无外部依赖）：拦截被切碎的垃圾 model。
    if (!looksLikeModelId(model)) {
      errors.push(`${where}: 非法/损坏的 model「${model}」`);
      continue;
    }
    if (variant != null && !VALID_VARIANTS.has(variant)) {
      errors.push(`${where}: 非法 variant「${variant}」(model=${model})`);
    }
    // 语义校验（仅当 opencode.jsonc 可解析）。
    if (defined) {
      const vs = defined.get(model);
      if (!vs) errors.push(`${where}: model 未在 opencode.jsonc 定义「${model}」`);
      else if (variant != null && !vs.has(variant)) {
        errors.push(`${where}: model「${model}」不支持 variant「${variant}」`);
      }
    }
  }

  return { ok: errors.length === 0, errors };
}
