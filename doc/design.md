# omo-switcher 设计文档 (design.md)

> 配套 `requirements.md`。本文件描述**如何实现**：模块划分、数据模型、API、SQLite/Redis 结构、
> 关键算法、实现顺序与可直接落地的代码契约。术语与需求编号沿用 requirements.md。

最后更新：2026-06-02

---

## 0. 重要变更：同步单位 = 档位包 (bundle/zip)  ⭐ 2026-06-02

同步/版本的单位从「8 个散文件」改为「**4 个档位包 (zip)**」，key = 档位 slug（`token-saving` /
`predictable-cost` / `balanced` / `quality-first`）。本节**取代** §3.1 / §4.2 中以单文件为单位的描述。

**每个档位包 `<slug>.zip` 内容**（由 `server/src/bundle.js` 确定性打包）：

| 文件 | 打包 | 说明 |
| --- | --- | --- |
| `oh-my-openagent.<n>-<slug>.json` | ✅ | omo 该档位 |
| `oh-my-opencode-slim.<n>-<slug>.json` | ✅ | slim 该档位 |
| `opencode.jsonc` | ✅ | 主配置；**含明文 apiKey/baseURL**（见下方安全） |
| `tui.json` | ✅ | 决定 TUI 激活哪个 plugin（48B） |
| `package.json` / `package-lock.json` | ✅ | 锁定插件版本，换机可复现 |
| `skills/`、`*.bak`、`.DS_Store`、`verify-variants.sh`、`node_modules/`、`log/storage/auth.json` | ❌ | 与档位无关/垃圾/凭据/产物 |

- 共享文件清单可用 `BUNDLE_SHARED_FILES`(逗号分隔) 覆盖；`BUNDLE_REDACT_SECRETS=1` 把 apiKey 抹成 `***`。
- **确定性打包**：所有 entry 用固定 mtime(2000-01-01) + DEFLATE level 6 → 内容不变则 zip 字节不变 → sha256 稳定 → diff 准确。
- **安全**：默认保留真实密钥（用户要求）。zip 仅进本机 Redis/SQLite，私有仓库不含数据库文件。
- **switch 不变**：`applyTier` 仍是把单个档位文件复制到 base 文件；打包只服务于"同步/版本"。
- **UI**：同步/历史列表只显示 slug（如 `balanced`），完整 label 与所含文件放进悬浮 title。
- **API 调整**：
  - `GET /api/config/items[?fs=1]`：列档位包元数据(key=slug，不含 zip)。`fs=1` 强制扫本机文件系统(用于"导入本机")，否则取远端 head 快照。
  - `GET /api/config/item/:slug[?snapshot=<id>|?fs=1]`：取该档位 zip(contentB64)。
  - `POST /api/config/push`：items=[{key:slug, contentB64, sha256}] → 生成快照。
  - 版本/回滚（`versions.js`）内容无关，key 换成 slug、内容换成 zip 即可，逻辑不变。
- 新增模块：`server/src/bundle.js`（`buildTierBundle` / `listTierBundles` / `tierMemberFiles` / `isAllowedSlug`）。依赖 `jszip`。

---

## 1. 仓库结构

```
omo-switcher/
├── package.json                 # 根：workspaces(server, client) + 便捷脚本
├── .gitignore
├── README.md                    # 安装/启动/同步说明（TODO）
├── doc/
│   ├── requirements.md
│   └── design.md
├── server/                      # Node.js + Redis 服务端
│   ├── package.json             # type:module；deps: express, cors, ioredis
│   └── src/
│       ├── config.js            # ✅ 路径/档位/redis/restart 配置（env 可覆盖）
│       ├── store.js             # ✅ Redis 封装：当前档位 + 切换历史 + 内存退回
│       ├── presets.js           # ✅ 扫描档位/字节比对检测当前档位/生成切换计划
│       ├── switcher.js          # ⛔TODO 备份+复制+回滚（FR-1.3/1.4）
│       ├── restart.js           # ⛔TODO 杀进程 + osascript 新终端（FR-2）
│       ├── versions.js          # ⛔TODO Redis 快照版本库 + 回滚（FR-4）
│       ├── sync.js              # ⛔TODO 配置项 diff + 同步原语（FR-3）
│       └── index.js             # ⛔TODO Express 路由汇总
└── client/                      # Electron 桌面客户端
    ├── package.json             # deps: electron, better-sqlite3, @electron/rebuild
    ├── main.js                  # ⛔TODO 主进程：窗口 + IPC + SQLite + HTTP 调用
    ├── preload.js               # ⛔TODO 暴露安全 API 给渲染层
    ├── db.js                    # ⛔TODO SQLite schema + DAO
    └── renderer/
        ├── index.html           # ⛔TODO 下拉框/重启/同步/历史 UI
        ├── styles.css
        └── renderer.js
```

✅=已实现，⛔=待实现。

---

## 2. 技术选型与理由

| 关注点 | 选型 | 理由 |
| --- | --- | --- |
| 服务端框架 | **Express** + `cors` | 轻量、零构建、路由直观，符合“小工具”。 |
| 服务端模块制式 | **ESM** (`"type":"module"`) | Node 25 原生支持；与 `presets.js` 等一致。 |
| 服务端状态/版本库 | **Redis**（`ioredis`） | 用户指定。当前档位、切换历史、配置快照版本均存 Redis。 |
| Redis 不可用 | **内存退回** | 见 store.js；保证无 Redis 也能跑（带告警）。NFR-1。 |
| 客户端 | **Electron** | 用户指定，桌面体验、可放系统托盘。 |
| 客户端本地存储 | **SQLite** | 用户指定（“配置走 sqlite”）。 |
| 文件切换 | **`fs.copyFile` 整文件字节复制** | 保留 BOM / 原始格式，绝不 JSON 重序列化。见 requirements §2。 |
| 重启 | **`pkill`-式精确杀 + `osascript` 新终端** | macOS 一键重启。FR-2。 |

### 2.1 客户端 SQLite 选型决策
- **首选 `better-sqlite3`**（同步 API、稳定、生态成熟）。Electron 下需对原生模块重建：
  - 加 `@electron/rebuild` 到 devDeps，`postinstall: electron-rebuild -f -w better-sqlite3`。
- **备选 `node:sqlite`**（Node 22.5+ 内置，免编译）。若 Electron 内置 Node 版本支持且想免去 native rebuild，可切换。
  - 风险：不同 Electron 版本对 `node:sqlite` 暴露不一致；需 `--experimental-sqlite`。
- **决策**：默认 `better-sqlite3`；`db.js` 用一层薄 DAO 封装，便于将来替换。

---

## 3. 数据模型

### 3.1 “配置项 (config item)” 规范化
- key = 文件名（如 `oh-my-openagent.3-balanced.json`）。
- 仅纳入 **8 个 tier 文件**（2 provider × 4 档）。base 文件与 `opencode.jsonc`/`auth.json` **不纳入**。
- value = 文件内容（以 **base64 或原始 UTF-8 文本 + 显式 `hasBOM`** 存储，保证字节级还原）。
  - 推荐存 `contentB64`（base64 of raw bytes）+ `sha256`，彻底规避编码/BOM 问题。
- 元数据：`size`、`sha256`、`mtime`（来源端的修改时间，仅供展示）。

```jsonc
// ConfigItem
{
  "key": "oh-my-openagent.3-balanced.json",
  "provider": "omo",            // 由前缀推导
  "tierSlug": "balanced",        // 由文件名推导
  "tierIndex": 3,
  "contentB64": "...",          // base64(原始字节)
  "sha256": "…",
  "size": 19956
}
```

### 3.2 Redis 键设计（服务端权威库）
前缀 `omo-switcher:`（可配）。

| Key | 类型 | 含义 |
| --- | --- | --- |
| `current` | string | 当前生效档位 slug（切换时写） |
| `history` | list | 切换历史（JSON 行，LPUSH，保留 100 条） |
| `snapshots` | zset | 成员=snapshotId，score=时间戳ms。用于按时间浏览/排序 |
| `snapshot:<id>` | hash | 一个快照的元数据：`{ id, ts, note, author, parentId }` |
| `snapshot:<id>:items` | hash | field=配置项 key，value=该项内容(JSON: {contentB64, sha256, size}) |
| `remote:head` | string | 远端“当前指针”指向的 snapshotId（FR-4.4 回滚即改它或生成新快照并指向） |

- snapshotId 建议：`<ts>-<shorthash>`（时间戳可读 + 内容指纹防碰撞）。
- **不可变**：已写入的 `snapshot:*` 永不修改；回滚 = 生成新快照（内容复制自旧快照/旧文件），更新 `remote:head`，`parentId` 记录来源，保留可追溯链。

### 3.3 客户端 SQLite schema
> “本地配置”与“当前配置/私有设置”分表隔离（FR-3.5）。

```sql
-- 本机私有设置：永不被同步覆盖（含服务器地址、当前档位缓存、UI 偏好）
CREATE TABLE IF NOT EXISTS local_settings (
  key   TEXT PRIMARY KEY,
  value TEXT
);
-- 约定键：'server_url'(同步地址), 'current_tier'(当前档位缓存),
--          'theme', 'last_sync_at', 'auth_token'(可选)

-- 本地配置项缓存（参与同步；pull 会按所选项覆盖这里）
CREATE TABLE IF NOT EXISTS config_items (
  key        TEXT PRIMARY KEY,   -- 文件名
  provider   TEXT NOT NULL,
  tier_slug  TEXT,
  tier_index INTEGER,
  content_b64 TEXT NOT NULL,
  sha256     TEXT NOT NULL,
  size       INTEGER,
  source     TEXT,               -- 'local-scan' | 'pulled' | 'edited'
  updated_at TEXT NOT NULL
);

-- 本地切换历史（与服务端 history 各存一份，FR-1.6）
CREATE TABLE IF NOT EXISTS switch_history (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  tier_slug  TEXT,
  ok         INTEGER,
  detail     TEXT,
  at         TEXT NOT NULL
);

-- 同步操作日志（FR-3.4 留痕）
CREATE TABLE IF NOT EXISTS sync_log (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  direction  TEXT,               -- 'pull' | 'push'
  scope      TEXT,               -- 'all' | 'single'
  items      TEXT,               -- JSON 数组：涉及的 key
  snapshot_id TEXT,              -- 关联远端快照（pull 自/push 生成）
  ok         INTEGER,
  at         TEXT NOT NULL
);
```

**隔离要点**：`pull` 全盘覆盖时，只清空/覆盖 `config_items`（且仅所选 key），
**绝不触碰** `local_settings`（server_url / current_tier 等）。这正是“当前配置不被覆盖”。

---

## 4. 服务端 API（Express，全部 JSON）

> base path 例：`/api`。nginx 在前面反代。所有写操作返回 `{ ok, ...payload, log? }`。

### 4.1 状态与切换（FR-1 / FR-2）
| Method & Path | 说明 | 入参 | 返回 |
| --- | --- | --- | --- |
| `GET /api/health` | 健康检查 | - | `{ ok, storeMode: 'redis'\|'memory' }` |
| `GET /api/state` | 当前完整状态 | - | `{ opencodeDir, providers, tiers[], active{omo,'omo-slim',shared} }`（即 `presets.getState()`） |
| `POST /api/switch` | 切换档位（omo+slim 同时） | `{ tier: slug }` | `{ ok, active, log[] }` |
| `POST /api/restart` | 重启 opencode | `{ cwd?, launchCmd? }` | `{ ok, killed:[pid…], launched:bool, log[] }` |
| `GET /api/history?limit=20` | 切换历史 | - | `{ items[] }` |

### 4.2 同步与版本（FR-3 / FR-4）
| Method & Path | 说明 | 入参 | 返回 |
| --- | --- | --- | --- |
| `GET /api/config/items` | 远端**当前**配置项清单（来自 `remote:head` 快照；若无则取文件系统现状） | - | `{ items:[{key,provider,tierSlug,tierIndex,sha256,size}] }` |
| `GET /api/config/item/:key?snapshot=<id>` | 取某项内容（默认当前，或指定快照） | - | `{ key, contentB64, sha256, size }` |
| `POST /api/config/push` | 客户端推送本地项 → 生成新快照 | `{ items:[{key,contentB64,sha256}], note? }` | `{ ok, snapshotId }` |
| `GET /api/snapshots?limit=50` | 历史版本列表（按时间倒序） | - | `{ head, items:[{id,ts,note,parentId,keys[]}] }` |
| `GET /api/snapshots/:id` | 某快照详情（含各项 sha/size，不含大内容） | - | `{ id, ts, note, items:[{key,sha256,size}] }` |
| `POST /api/snapshots/:id/rollback` | **整体回滚**到该版本（生成新快照并指向） | `{ note? }` | `{ ok, snapshotId }` |
| `POST /api/snapshots/:id/rollback-file` | **单文件回滚**（从该版本取单文件，生成新快照） | `{ key, note? }` | `{ ok, snapshotId }` |

> 说明：
> - `push`/回滚都通过 `versions.js` 生成新快照并更新 `remote:head`，**只动 Redis，不直接动文件系统**。
> - 远端快照与“文件系统上的 tier 文件”是两回事：服务端可选地提供 `POST /api/config/apply`（把某快照内容**写回**到 `~/.config/opencode` 的 tier 文件），但默认**不自动写盘**（避免污染本机）。是否需要见开放问题 Q-A。
> - 客户端 `pull` = 调 `GET /api/config/items` + 按所选 key 调 `GET /api/config/item/:key`（可带 `snapshot`），写入本地 SQLite `config_items`。

### 4.3 错误约定
- 4xx：参数错误 / 白名单外的 key / 不存在的快照。
- 5xx：fs / redis / 子进程错误。
- 统一返回 `{ ok:false, error:{ code, message } }`。

---

## 5. 模块契约（给实现者的精确说明）

### 5.1 `config.js`（✅已实现）
导出 `config`（端口、opencodeDir、providers{omo,omo-slim}.prefix、tierMeta、redis、restart）、
`tierFileName(prefix,slug,index)`、`activeFileName(prefix)`。所有项 env 可覆盖。

### 5.2 `store.js`（✅已实现）
- `initStore()` 连接 Redis，失败则退回内存（`fallbackToMemory`）。
- `storeMode()` → `'redis'|'memory'`。
- `getCurrent()/setCurrent(slug)`；`pushHistory(entry)`（自动加 `at`，保留 100）；`getHistory(limit)`。
- **TODO 扩展**：版本库相关方法建议放到独立 `versions.js`，复用同一个 ioredis 连接（可从 store 暴露 `getRedis()`）。

### 5.3 `presets.js`（✅已实现）
- `getState()` → 见 §4.1 返回结构。内部：扫描目录解析 `<prefix>.<index>-<slug>.json`；
  共享档位 = 两 provider 都有的 slug；`active` 通过字节比对得出，并给出 `shared`。
- `resolveSwitch(slug)` → `[{providerId, from, to}]` 切换计划（供 switcher 使用）。

### 5.4 `switcher.js`（⛔TODO）契约
```
export async function applyTier(slug): Promise<{ ok, active, log[] }>
```
算法（满足 FR-1.4 原子+回滚）：
1. `plan = resolveSwitch(slug)`（2 条：omo、slim）。
2. 对每条：读取 `to` 旧内容到内存备份（若存在）。
3. 依次 `fs.copyFileSync(from, to)`；记录已成功的条目。
4. 任一步失败 → 用备份**回滚所有已改动的 `to`**，抛错。
5. 成功 → `store.setCurrent(slug)`，`store.pushHistory({tier:slug, ok:true})`，返回 `getState().active` 与 log。
- 失败也 `pushHistory({tier:slug, ok:false, detail})`。
- **安全**：只操作 `resolveSwitch` 给出的白名单路径，from 必须存在且在 opencodeDir 内。

### 5.5 `restart.js`（⛔TODO）契约
```
export async function restartOpencode({ cwd?, launchCmd? }): Promise<{ ok, killed[], launched, log[] }>
```
1. **找进程**：`ps -axo pid=,command=`，逐行筛选 command 含 `config.restart.killNeedle`（默认 `opencode`），
   且**不含** `omo-switcher`，且 pid ≠ `process.pid`。
2. **杀**：对命中 pid `process.kill(pid, 'SIGTERM')`（必要时 SIGKILL 兜底）。记录 killed。
3. **拉起**：macOS 用 osascript 新开 Terminal：
   ```
   osascript -e 'tell application "Terminal"' \
     -e 'activate' \
     -e 'do script "cd <cwd> ; <launchCmd>"' \
     -e 'end tell'
   ```
   - `cwd` 默认 `config.restart.launchCwd`（home），`launchCmd` 默认 `opencode`。
   - 注意 shell 转义（cwd/cmd 中的引号）。
4. 平台抽象：导出 `relaunchByPlatform()`，非 darwin 暂返回“未实现”。NFR-6。
5. 返回结构化日志。

### 5.6 `versions.js`（⛔TODO）契约
```
export async function createSnapshot(items, {note, author, parentId}): Promise<snapshotId>
export async function listSnapshots(limit): Promise<{head, items[]}>
export async function getSnapshot(id): Promise<{meta, items}>      // items: key->{sha256,size}
export async function getSnapshotItem(id, key): Promise<{contentB64,sha256,size}>
export async function getCurrentItems(): Promise<ConfigItem[]>      // 取 remote:head 快照；无则扫文件系统
export async function rollbackAll(id, {note}): Promise<snapshotId>  // 复制旧快照内容→新快照→改 head
export async function rollbackFile(id, key, {note}): Promise<snapshotId> // 取旧快照单文件覆盖到“当前内容集”→新快照→改 head
```
- 用 Redis 结构见 §3.2。`createSnapshot` 写 `snapshots`(zset)+`snapshot:<id>`+`snapshot:<id>:items`，并更新 `remote:head`。
- snapshotId = `${Date.now()}-${sha256(allItems).slice(0,8)}`。
- 内存退回模式下用一个内存数组模拟（与 store 一致风格）。

### 5.7 `sync.js`（⛔TODO）契约（主要差异计算，便于确认页展示）
```
export function diffItems(localItems, remoteItems): {
  onlyLocal: key[], onlyRemote: key[], changed: key[], same: key[]
}   // 按 sha256 比较
```
- 真正的“写入”由客户端（pull 写 SQLite）或服务端（push→createSnapshot）完成；
  `sync.js` 在服务端可仅提供 diff 辅助；客户端也可本地实现同款 diff。

### 5.8 `index.js`（⛔TODO）
- `initStore()`；装配 `cors()`、`express.json({limit:'5mb'})`；按 §4 注册路由；
  错误中间件统一成 `{ok:false,error}`；`listen(config.port, config.host)`。

---

## 6. Electron 客户端设计

### 6.1 进程模型
- **main.js**：创建 BrowserWindow；初始化 SQLite（`db.js`）；通过 IPC 暴露：
  - `settings:get/set`（读写 `local_settings`，含 server_url）
  - `http:call`（main 进程用 `fetch` 请求服务端，避免渲染层 CORS / 暴露 token）
  - `db:*`（读写 config_items / 历史 / 同步日志）
- **preload.js**：`contextBridge.exposeInMainWorld('api', {...})` 只暴露白名单方法。
- **renderer**：纯 HTML/CSS/JS（或可选小框架）。**不直接** require node 模块。

### 6.2 UI 布局（单窗口，分区）
1. **顶部状态条**：服务端连通状态、storeMode、当前生效档位（omo/slim 一致性提示）。
2. **档位切换区（FR-1）**：下拉框(4 档) + “应用”按钮 → 确认弹窗 → 调 `POST /api/switch`。
3. **重启区（FR-2）**：可填工作目录，“重启 opencode”按钮 → `POST /api/restart` → 显示日志。
4. **设置区（FR-3.6）**：**服务器同步地址输入框**（持久化到 `local_settings.server_url`）+ “测试连接”(`GET /api/health`)。
5. **同步区（FR-3/FR-4）**：
   - 左“本地”/右“远端”两栏，列出配置项 + 各自 sha 短码；中间显示 diff 标记（onlyLocal/onlyRemote/changed/same）。
   - 每行一个 **checkbox**；顶部“全选/全不选”。
   - 方向切换：`pull ⟵` / `push ⟶`（单选）。
   - 版本选择器：远端可选“最新”或某历史快照（下拉/列表）。
   - “同步选中项”按钮 → **确认页**（展示将覆盖/新增的清单）→ 执行 → 写 `sync_log`。
   - **当前配置/服务器地址不在列表内**，UI 明确标注“当前配置（不参与同步）”。
6. **历史版本区（FR-4）**：远端快照列表（时间戳/备注/文件数）；点开看文件列表；
   - “整体回滚”按钮（`/rollback`）；行内“单文件回滚”（`/rollback-file`）。

### 6.3 关键交互流程
- **pull（远端→本地）**：选版本→拉清单→与本地 diff→勾选→确认→逐项 `GET item`→写 `config_items`（仅所选 key）→`local_settings` 不动。
- **push（本地→远端）**：勾选→确认→`POST /config/push`（含所选项内容）→服务端 `createSnapshot`→刷新历史。
- **测试连接**：`GET {server_url}/api/health`，展示 storeMode。

---

## 7. 安全与一致性细则
- 白名单：服务端任何按 `key` 访问的接口，先用正则校验 `key` 属于 8 个合法 tier 文件之一，拒绝路径分隔符。
- 备份回滚：见 5.4。
- 凭据隔离：永不读取/同步 `opencode.jsonc`、`auth.json`；`.gitignore` 已忽略 `.env`、`*.sqlite`。
- 字节保真：所有内容走 base64，sha256 校验；切换走 `copyFile`。

---

## 8. 实现顺序（推荐，给接力者）
1. **里程碑 A（核心闭环，可演示）**：`switcher.js` + `restart.js` + 最小 `index.js`（health/state/switch/restart/history）。手动用 curl 验收 FR-1/FR-2。
2. **里程碑 B（版本库）**：`versions.js` + 快照/回滚路由。用 curl 验收 FR-4。
3. **里程碑 C（同步原语）**：`config/items`、`config/item`、`config/push`、`sync.diffItems`。
4. **里程碑 D（客户端）**：Electron 骨架 → 设置区(server_url) + 状态/切换/重启 → 同步区 → 历史区。
5. **里程碑 E**：README + 推送 GitHub（不含凭据）+ 联调验收（requirements §7）。

> 已实现的 `config.js/store.js/presets.js` 已为里程碑 A 准备好 `getState()`/`resolveSwitch()`/`store.*`，
> 直接据 §5.4/§5.5 写 switcher/restart 即可跑通。

---

## 9. 本地启动（开发）
```bash
# 安装
cd omo-switcher && npm run install:all       # 等价于分别 npm --prefix server/client install

# 服务端（无 Redis 也能跑，会退回内存并告警）
npm run server                                # 默认 127.0.0.1:7600
#   可选 env：OPENCODE_DIR / REDIS_URL / OMO_SWITCHER_PORT / RESTART_* 等

# 客户端（Electron）
npm run client
```
> 装 Redis（可选，启用版本/历史持久化）：`brew install redis && brew services start redis`。

---

## 10. 开放问题（设计层，承接 requirements §8）
- Q-A 远端快照是否需要“写回文件系统”（`/api/config/apply`）？默认否。若用户希望“远端版本→直接生效到本机 opencode”，需新增写盘+可选自动 `switch`。
- Q-B 多机：若客户端与服务端异机，重启/切换只影响服务端那台。需在 UI 标注“操作目标=服务端主机”。
- Q-C 鉴权：预留 `local_settings.auth_token` → 客户端 `http:call` 注入 `Authorization`，服务端中间件校验（当前未启用）。
- Q-D 快照保留策略：当前永久保留。如需上限/清理，加 `snapshots` zset 修剪策略。
