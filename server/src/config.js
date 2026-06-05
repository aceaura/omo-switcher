// 集中配置：所有路径 / 端口 / Redis 均可通过环境变量覆盖。
import os from 'node:os';
import path from 'node:path';

const home = os.homedir();

export const config = {
  // 监听端口（nginx 反代时指向这里）
  port: Number(process.env.OMO_SWITCHER_PORT || 7600),
  host: process.env.OMO_SWITCHER_HOST || '0.0.0.0',

  // opencode 配置目录（存放 oh-my-* 配置文件的地方）
  opencodeDir: process.env.OPENCODE_DIR || path.join(home, '.config', 'opencode'),

  // 两个插件的文件前缀。性能档位文件形如 `<prefix>.<index>-<slug>.json`，
  // 当前生效文件为 `<prefix>.json`。
  providers: {
    omo: { label: 'omo (oh-my-openagent)', prefix: 'oh-my-openagent' },
    'omo-slim': { label: 'omo-slim (oh-my-opencode-slim)', prefix: 'oh-my-opencode-slim' },
  },

  // 性能档位的展示元数据（key 取文件名中的 slug 部分）
  // 两套模式族，每族 4 档：OpusMode = Opus 4.8 + DeepSeek V4 Pro 为主（GPT-5.5 辅助）；
  // GptMode = GPT-5.5 + DeepSeek V4 Pro 为主（Opus 4.8 辅助）。颜色按强度 ultra>high>medium>low。
  tierMeta: {
    'opus-ultra': { index: 1, label: 'OpusMode · Ultra', color: '#f85149' },
    'opus-high': { index: 2, label: 'OpusMode · High', color: '#d29922' },
    'opus-medium': { index: 3, label: 'OpusMode · Medium', color: '#58a6ff' },
    'opus-low': { index: 4, label: 'OpusMode · Low', color: '#3fb950' },
    'gpt-ultra': { index: 5, label: 'GptMode · Ultra', color: '#f85149' },
    'gpt-high': { index: 6, label: 'GptMode · High', color: '#d29922' },
    'gpt-medium': { index: 7, label: 'GptMode · Medium', color: '#58a6ff' },
    'gpt-low': { index: 8, label: 'GptMode · Low', color: '#3fb950' },
  },

  redis: {
    url: process.env.REDIS_URL || 'redis://127.0.0.1:6379',
    keyPrefix: process.env.REDIS_KEY_PREFIX || 'omo-switcher:',
    // Redis 不可用时是否退回内存存储（开发/无 Redis 环境）
    fallbackToMemory: process.env.REDIS_FALLBACK !== '0',
  },

  // 档位打包：每个档位(slug)打成一个自包含 zip。
  bundle: {
    // 除两个 provider 的档位文件外，额外打包进每个 zip 的"共享文件"。
    // 仅打包实际存在的；缺失的自动跳过。
    sharedFiles: (process.env.BUNDLE_SHARED_FILES ||
      'opencode.jsonc,tui.json,package.json,package-lock.json')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    // 是否对打包内容做密钥脱敏（把 apiKey 等抹成 ***）。默认关闭（保留真实密钥）。
    redactSecrets: process.env.BUNDLE_REDACT_SECRETS === '1',
  },

  restart: {
    // 用于匹配待杀进程的关键字（在进程命令行中查找）。
    killNeedle: process.env.RESTART_KILL_NEEDLE || 'opencode',
    // 重启 Desktop 的命令
    launchCmd: process.env.RESTART_LAUNCH_CMD || 'open -a OpenCode',
    // 新终端的工作目录
    launchCwd: process.env.RESTART_LAUNCH_CWD || home,
    launchTimeoutMs: Number(process.env.RESTART_LAUNCH_TIMEOUT_MS || 8000),
  },
};

export function tierFileName(prefix, slug, index) {
  return `${prefix}.${index}-${slug}.json`;
}

export function activeFileName(prefix) {
  return `${prefix}.json`;
}
