// 档位切换：把某档位文件按字节整文件复制到 omo / slim 的 base 文件。
// 满足 FR-1.4：先备份、失败回滚，保证不出现“omo 改了 slim 没改”的半成品。
import fs from 'node:fs';
import path from 'node:path';
import { config } from './config.js';
import { getState, resolveSwitch } from './presets.js';
import { setCurrent, pushHistory } from './store.js';

// 安全校验：from/to 必须位于 opencodeDir 内（防目录穿越）。
function assertInside(file) {
  const dir = path.resolve(config.opencodeDir);
  const resolved = path.resolve(file);
  if (resolved !== dir && !resolved.startsWith(dir + path.sep)) {
    throw new Error(`非法路径（越界）：${file}`);
  }
}

export async function applyTier(slug) {
  const log = [];
  let plan;
  try {
    plan = resolveSwitch(slug); // [{providerId, from, to}] 通常 2 条
  } catch (err) {
    await pushHistory({ tier: slug, ok: false, detail: err.message });
    throw err;
  }

  // 记录每条的备份，用于回滚。
  const done = []; // { to, backup: Buffer|null, existed: bool }

  try {
    for (const step of plan) {
      assertInside(step.from);
      assertInside(step.to);
      if (!fs.existsSync(step.from)) {
        throw new Error(`档位源文件不存在：${step.from}`);
      }
      const existed = fs.existsSync(step.to);
      const backup = existed ? fs.readFileSync(step.to) : null;

      fs.copyFileSync(step.from, step.to); // 字节级复制，保留 BOM/格式
      done.push({ to: step.to, backup, existed });
      log.push(`[ok] ${step.providerId}: ${path.basename(step.from)} -> ${path.basename(step.to)}`);
    }
  } catch (err) {
    // 回滚所有已改动的 to。
    for (const d of done.reverse()) {
      try {
        if (d.existed && d.backup) fs.writeFileSync(d.to, d.backup);
        else if (!d.existed) fs.rmSync(d.to, { force: true });
        log.push(`[rollback] ${path.basename(d.to)}`);
      } catch (e) {
        log.push(`[rollback-failed] ${path.basename(d.to)}: ${e.message}`);
      }
    }
    await pushHistory({ tier: slug, ok: false, detail: err.message });
    const e = new Error(`切换失败并已回滚：${err.message}`);
    e.log = log;
    throw e;
  }

  await setCurrent(slug);
  await pushHistory({ tier: slug, ok: true });
  const { active } = getState();
  return { ok: true, active, log };
}
