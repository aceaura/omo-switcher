// 重启 opencode：杀掉正在运行的 opencode 进程，再在新终端窗口启动 opencode。
// FR-2。首要支持 macOS（osascript）。其它平台暂返回“未实现”。
import { execFile, execFileSync } from 'node:child_process';
import { config } from './config.js';

// 找出待杀的 opencode 进程 pid。
// 规则：命令行含 killNeedle(默认 'opencode')，但排除本工具自身(含 'omo-switcher')与当前进程。
function findOpencodePids() {
  let out = '';
  try {
    out = execFileSync('ps', ['-axo', 'pid=,command='], { encoding: 'utf8' });
  } catch {
    return [];
  }
  const needle = config.restart.killNeedle;
  const pids = [];
  for (const line of out.split('\n')) {
    const m = /^\s*(\d+)\s+(.*)$/.exec(line);
    if (!m) continue;
    const pid = Number(m[1]);
    const cmd = m[2];
    if (pid === process.pid) continue;
    if (cmd.includes('omo-switcher')) continue; // 不杀自己
    if (cmd.includes(needle)) pids.push({ pid, cmd });
  }
  return pids;
}

function killPid(pid) {
  try {
    process.kill(pid, 'SIGTERM');
    return true;
  } catch {
    try {
      process.kill(pid, 'SIGKILL');
      return true;
    } catch {
      return false;
    }
  }
}

// AppleScript 字符串里需要转义双引号与反斜杠。
function escForApplescript(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function relaunchDarwin({ cwd, launchCmd }) {
  return new Promise((resolve, reject) => {
    const inner = `cd ${escForApplescript(cwd)} ; ${escForApplescript(launchCmd)}`;
    const script = [
      'tell application "Terminal"',
      '  activate',
      `  do script "${inner}"`,
      'end tell',
    ];
    const args = [];
    for (const line of script) {
      args.push('-e', line);
    }
    execFile('osascript', args, (err, stdout, stderr) => {
      if (err) reject(new Error(`osascript 失败: ${stderr || err.message}`));
      else resolve(true);
    });
  });
}

async function relaunchByPlatform(opts) {
  if (process.platform === 'darwin') return relaunchDarwin(opts);
  throw new Error(`暂未实现的平台重启逻辑: ${process.platform}`);
}

export async function restartOpencode({ cwd, launchCmd } = {}) {
  const log = [];
  const targetCwd = cwd || config.restart.launchCwd;
  const cmd = launchCmd || config.restart.launchCmd;

  // 1) 杀进程
  const found = findOpencodePids();
  const killed = [];
  for (const { pid, cmd: c } of found) {
    if (killPid(pid)) {
      killed.push(pid);
      log.push(`[kill] pid=${pid} ${c.slice(0, 80)}`);
    } else {
      log.push(`[kill-failed] pid=${pid}`);
    }
  }
  if (found.length === 0) log.push('[kill] 未发现运行中的 opencode 进程');

  // 2) 新开终端启动
  let launched = false;
  try {
    await relaunchByPlatform({ cwd: targetCwd, launchCmd: cmd });
    launched = true;
    log.push(`[launch] 新终端: cd ${targetCwd} ; ${cmd}`);
  } catch (err) {
    log.push(`[launch-failed] ${err.message}`);
  }

  return { ok: launched, killed, launched, log };
}
