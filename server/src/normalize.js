// 落盘前的「自动修复」：每次应用配置（切换档位）时，对即将写入 opencode 配置目录的
// 成员内容做幂等规范化，保证两类已知会反复发作的问题不再复发。注入点是 bundle.js 的
// extractTierBundle —— 切换写盘 (presets.resolveSwitch) 与当前档位检测 (presets.detectActive)
// 都经它取成员内容，因此两侧看到的是同一份「规范化后」内容，检测不会因修复而错位。
//
//  A) oh-my-openagent.json 必须禁用 security-research / security-review 两个 skill。
//     原因：oh-my-openagent ≥4.7.x 的 "runtime skill source server" 硬依赖 Bun.serve，
//     而 opencode desktop(Windows) 用 Node 跑插件 → 抛 "requires Bun.serve" → 整个插件
//     加载失败、它的 agent 从 UI 消失。该 server 仅在 selectRuntimeSecuritySkills() 非空时
//     创建，而后者由 disabled_skills 控制：两个都禁用 → 空列表 → 不触发 Bun.serve。
//  B) package.json 的 dependencies 必须声明 oh-my-opencode-slim，否则 npm 不会安装该插件
//     （它原本只在 opencode.jsonc 的 plugin 数组里，导致 slim 没被装上）。
import { config } from './config.js';

const BOM = '﻿';

// 需要在 oh-my-openagent.json 里禁用的 skill（两个都禁用才能让 runtime skill source 为空）。
export const REQUIRED_DISABLED_SKILLS = (process.env.OMO_FIX_DISABLED_SKILLS ||
  'security-research,security-review')
  .split(',').map((s) => s.trim()).filter(Boolean);

// package.json 里必须存在的依赖；已存在则保留其版本，仅在缺失时补上默认版本。
export const REQUIRED_DEPS = {
  'oh-my-opencode-slim': process.env.OMO_FIX_SLIM_VERSION || '^1.1.1',
};

function omoMemberName() {
  return `${config.providers.omo?.prefix || 'oh-my-openagent'}.json`;
}

function parseJsonPreserveBom(buf) {
  let text = buf.toString('utf8');
  const hadBom = text.charCodeAt(0) === 0xfeff;
  if (hadBom) text = text.slice(1);
  return { obj: JSON.parse(text), hadBom };
}

function serialize(obj, hadBom) {
  return Buffer.from((hadBom ? BOM : '') + JSON.stringify(obj, null, 2) + '\n', 'utf8');
}

// 把 disabled_skills 放在 $schema 之后（没有 $schema 时放最前），保证排序稳定 → 字节稳定。
function withDisabledSkills(obj, merged) {
  const out = {};
  if ('$schema' in obj) {
    for (const [k, v] of Object.entries(obj)) {
      if (k === 'disabled_skills') continue;
      out[k] = v;
      if (k === '$schema') out.disabled_skills = merged;
    }
    return out;
  }
  out.disabled_skills = merged;
  for (const [k, v] of Object.entries(obj)) {
    if (k !== 'disabled_skills') out[k] = v;
  }
  return out;
}

function normalizeOmo(buf) {
  const { obj, hadBom } = parseJsonPreserveBom(buf);
  const cur = Array.isArray(obj.disabled_skills) ? obj.disabled_skills : [];
  const merged = [...cur];
  for (const s of REQUIRED_DISABLED_SKILLS) if (!merged.includes(s)) merged.push(s);
  // 已满足（key 存在且已含全部所需）→ 原样返回，避免无谓的字节变动。
  if (Array.isArray(obj.disabled_skills) && merged.length === cur.length) return buf;
  return serialize(withDisabledSkills(obj, merged), hadBom);
}

function normalizePackageJson(buf) {
  const { obj, hadBom } = parseJsonPreserveBom(buf);
  const deps = obj.dependencies && typeof obj.dependencies === 'object' ? obj.dependencies : {};
  let changed = false;
  const next = { ...deps };
  for (const [name, version] of Object.entries(REQUIRED_DEPS)) {
    if (!next[name]) { next[name] = version; changed = true; }
  }
  if (!changed) return buf;
  obj.dependencies = next;
  return serialize(obj, hadBom);
}

// 对单个 zip 成员内容做规范化。未知/无关成员原样返回。
export function normalizeMemberContent(name, content) {
  try {
    if (name === omoMemberName()) return normalizeOmo(content);
    if (name === 'package.json') return normalizePackageJson(content);
  } catch {
    // 内容不是合法 JSON 时不阻断切换：交由后续 validate / 用户排查。
    return content;
  }
  return content;
}
