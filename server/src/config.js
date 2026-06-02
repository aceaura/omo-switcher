// 集中配置：所有路径 / 端口 / Redis 均可通过环境变量覆盖。
import os from 'node:os';
import path from 'node:path';

const home = os.homedir();

export const config = {
  // 监听端口（nginx 反代时指向这里）
  port: Number(process.env.OMO_SWITCHER_PORT || 7600),
  host: process.env.OMO_SWITCHER_HOST || '127.0.0.1',

  // opencode 配置目录（存放 oh-my-* 配置文件的地方）
  opencodeDir: process.env.OPENCODE_DIR || path.join(home, '.config', 'opencode'),

  // 两个插件的文件前缀。性能档位文件形如 `<prefix>.<index>-<slug>.json`，
  // 当前生效文件为 `<prefix>.json`。
  providers: {
    omo: { label: 'omo (oh-my-openagent)', prefix: 'oh-my-openagent' },
    'omo-slim': { label: 'omo-slim (oh-my-opencode-slim)', prefix: 'oh-my-opencode-slim' },
  },

  // 性能档位的展示元数据（key 取文件名中的 slug 部分）
  tierMeta: {
    'token-saving': { index: 1, label: '省钱 · Token Saving', color: '#3fb950' },
    'predictable-cost': { index: 2, label: '可预测成本 · Predictable Cost', color: '#58a6ff' },
    'balanced': { index: 3, label: '均衡 · Balanced', color: '#d29922' },
    'quality-first': { index: 4, label: '质量优先 · Quality First', color: '#f85149' },
  },

  redis: {
    url: process.env.REDIS_URL || 'redis://127.0.0.1:6379',
    keyPrefix: process.env.REDIS_KEY_PREFIX || 'omo-switcher:',
    // Redis 不可用时是否退回内存存储（开发/无 Redis 环境）
    fallbackToMemory: process.env.REDIS_FALLBACK !== '0',
  },

  restart: {
    // 用于匹配待杀进程的关键字（在进程命令行中查找）。
    killNeedle: process.env.RESTART_KILL_NEEDLE || 'opencode',
    // 重新拉起 opencode 的命令（在新终端里执行）
    launchCmd: process.env.RESTART_LAUNCH_CMD || 'opencode',
    // 新终端的工作目录
    launchCwd: process.env.RESTART_LAUNCH_CWD || home,
  },
};

export function tierFileName(prefix, slug, index) {
  return `${prefix}.${index}-${slug}.json`;
}

export function activeFileName(prefix) {
  return `${prefix}.json`;
}
