// 重启 opencode：杀掉正在运行的 opencode 进程，再在新终端窗口启动 opencode。
// FR-2。首要支持 macOS（osascript）。其它平台暂返回“未实现”。
import { execFile, execFileSync } from 'node:child_process';
import { config } from './config.js';

const DEFAULT_TERM_WAIT_MS = 1200;
const DEFAULT_KILL_WAIT_MS = 800;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function parseProcessList(out) {
  const processes = [];
  for (const line of out.split('\n')) {
    const m = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
    if (!m) continue;
    processes.push({ pid: Number(m[1]), ppid: Number(m[2]), cmd: m[3] });
  }
  return processes;
}

function readProcessList() {
  try {
    return parseProcessList(execFileSync('ps', ['-axo', 'pid=,ppid=,command='], { encoding: 'utf8' }));
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err), processes: [] };
  }
}

export function collectRestartTargets(processes, { currentPid, killNeedle }) {
  const needle = config.restart.killNeedle;
  const normalizedNeedle = String(killNeedle || needle).toLowerCase();
  const childrenByParent = new Map();
  for (const proc of processes) {
    const children = childrenByParent.get(proc.ppid) || [];
    children.push(proc);
    childrenByParent.set(proc.ppid, children);
  }

  const byPid = new Map(processes.map((proc) => [proc.pid, proc]));
  const targets = new Map();
  const addTree = (proc) => {
    if (targets.has(proc.pid)) return;
    targets.set(proc.pid, proc);
    for (const child of childrenByParent.get(proc.pid) || []) addTree(child);
  };

  for (const proc of processes) {
    const cmd = proc.cmd;
    if (proc.pid === currentPid) continue;
    if (cmd.includes('omo-switcher')) continue; // 不杀自己
    if (cmd.toLowerCase().includes(normalizedNeedle)) addTree(proc);
  }

  return [...targets.values()]
    .filter((proc) => proc.pid !== currentPid && byPid.has(proc.pid))
    .sort((a, b) => b.pid - a.pid)
    .map(({ pid, cmd }) => ({ pid, cmd }));
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export async function terminateRestartTargets(targets, deps = {}) {
  const kill = deps.kill || ((pid, signal) => process.kill(pid, signal));
  const isAlive = deps.isAlive || isProcessAlive;
  const wait = deps.sleep || sleep;
  const termWaitMs = deps.termWaitMs ?? DEFAULT_TERM_WAIT_MS;
  const killWaitMs = deps.killWaitMs ?? DEFAULT_KILL_WAIT_MS;
  const killed = [];
  const failed = [];

  for (const { pid } of targets) {
    try {
      kill(pid, 'SIGTERM');
    } catch (err) {
      failed.push({ pid, reason: err instanceof Error ? err.message : String(err) });
    }
  }

  if (targets.length) await wait(termWaitMs);

  for (const { pid } of targets) {
    if (!isAlive(pid)) {
      killed.push(pid);
      continue;
    }
    try {
      kill(pid, 'SIGKILL');
    } catch (err) {
      failed.push({ pid, reason: err instanceof Error ? err.message : String(err) });
    }
  }

  if (targets.length) await wait(killWaitMs);

  for (const { pid } of targets) {
    if (!killed.includes(pid) && !isAlive(pid)) killed.push(pid);
    else if (!killed.includes(pid) && !failed.some((item) => item.pid === pid)) {
      failed.push({ pid, reason: 'process still alive after SIGKILL' });
    }
  }

  return { killed: [...new Set(killed)], failed };
}

// AppleScript 字符串里需要转义双引号与反斜杠。
function escForApplescript(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, `'\\''`)}'`;
}

function parseOpenApp(cmd) {
  // 解析 'open -a AppName' 或 'open /path/to/App.app'
  const parts = cmd.split(/\s+/).filter(Boolean);
  if (parts[0] === 'open') {
    const idx = parts.indexOf('-a');
    if (idx >= 0 && parts[idx + 1]) return { app: parts[idx + 1] };
    const pathIdx = parts.findIndex((p) => p.endsWith('.app'));
    if (pathIdx >= 0) return { app: parts[pathIdx] };
    // fallback: treat entire cmd as open args
    return { args: parts.slice(1) };
  }
  return null;
}

function relaunchDarwin({ cwd, launchCmd }) {
  // 桌面应用：直接用 open 命令，不经过 Terminal
  const openApp = parseOpenApp(launchCmd);
  if (openApp) {
    return new Promise((resolve, reject) => {
      const args = openApp.args || ['-a', openApp.app];
      execFile('open', args, { timeout: config.restart.launchTimeoutMs }, (err, stdout, stderr) => {
        if (err) reject(new Error(`open 失败: ${stderr || err.message}`));
        else resolve(true);
      });
    });
  }

  // TUI/终端命令：走 osascript Terminal
  return new Promise((resolve, reject) => {
    const inner = `cd ${shellQuote(cwd)} ; ${launchCmd}`;
    const script = [
      'tell application "Terminal"',
      '  activate',
      `  do script "${escForApplescript(inner)}"`,
      'end tell',
    ];
    const args = [];
    for (const line of script) {
      args.push('-e', line);
    }
    execFile('osascript', args, { timeout: config.restart.launchTimeoutMs }, (err, stdout, stderr) => {
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
  const listed = readProcessList();
  const processes = Array.isArray(listed) ? listed : listed.processes;
  if (!Array.isArray(listed) && listed.error) log.push(`[scan-failed] ps: ${listed.error}`);
  const found = collectRestartTargets(processes, {
    currentPid: process.pid,
    killNeedle: config.restart.killNeedle,
  });
  for (const { pid, cmd: c } of found) {
    log.push(`[kill-target] pid=${pid} ${c.slice(0, 120)}`);
  }
  if (found.length === 0) log.push('[kill] 未发现运行中的 opencode 进程');
  const { killed, failed } = await terminateRestartTargets(found);
  for (const pid of killed) log.push(`[kill] pid=${pid}`);
  for (const item of failed) log.push(`[kill-failed] pid=${item.pid} ${item.reason}`);

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
