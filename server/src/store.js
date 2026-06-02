// Redis 存储封装，负责保存“当前生效档位”和“切换历史”。
// Redis 不可用时退回进程内内存存储（带告警），保证工具在无 Redis 时仍可用。
import Redis from 'ioredis';
import { config } from './config.js';

const K_CURRENT = `${config.redis.keyPrefix}current`; // 字符串：当前 tier slug
const K_HISTORY = `${config.redis.keyPrefix}history`; // list：JSON 字符串

let redis = null;
let usingMemory = false;
const mem = { current: null, history: [] };

export function initStore() {
  try {
    redis = new Redis(config.redis.url, {
      lazyConnect: false,
      maxRetriesPerRequest: 1,
      retryStrategy: () => null, // 不无限重连，连不上就退回内存
    });
    redis.on('error', (err) => {
      if (!usingMemory) {
        usingMemory = config.redis.fallbackToMemory;
        console.warn(
          `[store] Redis 连接失败 (${err.code || err.message})；` +
            (usingMemory ? '已退回内存存储。' : '内存退回已禁用。')
        );
      }
    });
    redis.on('connect', () => {
      usingMemory = false;
      console.log(`[store] 已连接 Redis: ${config.redis.url}`);
    });
  } catch (err) {
    usingMemory = config.redis.fallbackToMemory;
    console.warn('[store] 初始化 Redis 失败，退回内存存储:', err.message);
  }
}

function live() {
  return redis && redis.status === 'ready' && !usingMemory;
}

export function storeMode() {
  return live() ? 'redis' : 'memory';
}

// 供 versions.js 复用同一连接；内存模式返回 null。
export function getRedis() {
  return live() ? redis : null;
}

export async function getCurrent() {
  if (live()) return await redis.get(K_CURRENT);
  return mem.current;
}

export async function setCurrent(slug) {
  if (live()) await redis.set(K_CURRENT, slug);
  else mem.current = slug;
}

export async function pushHistory(entry) {
  const record = { ...entry, at: new Date().toISOString() };
  const line = JSON.stringify(record);
  if (live()) {
    await redis.lpush(K_HISTORY, line);
    await redis.ltrim(K_HISTORY, 0, 99); // 仅保留最近 100 条
  } else {
    mem.history.unshift(record);
    mem.history = mem.history.slice(0, 100);
  }
  return record;
}

export async function getHistory(limit = 20) {
  if (live()) {
    const rows = await redis.lrange(K_HISTORY, 0, limit - 1);
    return rows.map((r) => {
      try {
        return JSON.parse(r);
      } catch {
        return { raw: r };
      }
    });
  }
  return mem.history.slice(0, limit);
}
