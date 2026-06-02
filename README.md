# omo-switcher

为本机 [opencode](https://opencode.ai) 在 **omo**（`oh-my-openagent`）与 **omo-slim**（`oh-my-opencode-slim`）
两个插件之间，按统一的「性能/消耗档位」一键切换配置文件，并一键重启 opencode。
另含**本地 ↔ 远端的带版本历史的配置同步**。

> 设计与需求详见 [`doc/requirements.md`](doc/requirements.md) 与 [`doc/design.md`](doc/design.md)。

## 功能
- **档位切换**：下拉框选 1 个性能版本（省钱 / 可预测成本 / 均衡 / 质量优先），同时应用到 omo 与 omo-slim。按字节整文件复制，保留 BOM/格式；失败自动回滚。
- **重启 opencode**：杀掉运行中的 opencode 进程，新开 macOS 终端窗口重新启动。
- **同步**：本地 SQLite ↔ 远端服务器，双向、可全量/单项、勾选 + 确认；当前档位与服务器地址等本机私有设置**永不被同步覆盖**。
- **版本历史**：服务端按时间戳保留全部快照，可浏览、整体回滚、单文件回滚；本地可从任意历史版本拉取。
- 服务器同步地址可在界面编辑。

## 架构
- **服务端**：Node.js + Express + Redis（前置 nginx，由你自行配置）。负责扫描/切换/重启/快照版本库/同步 API。须与 opencode 同机。
- **客户端**：Electron 桌面应用，本地 SQLite 存配置项与私有设置。

## 快速开始
```bash
npm run install:all          # 安装 server 与 client 依赖

# 服务端（无 Redis 也能跑：自动退回内存存储并告警）
npm run server               # 默认 http://127.0.0.1:7600

# 客户端（Electron）
npm run client
```
可选启用持久化版本库：`brew install redis && brew services start redis`。

### 环境变量（服务端）
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OMO_SWITCHER_PORT` | `7600` | 监听端口 |
| `OPENCODE_DIR` | `~/.config/opencode` | opencode 配置目录 |
| `REDIS_URL` | `redis://127.0.0.1:6379` | Redis 地址 |
| `REDIS_FALLBACK` | `1` | Redis 不可用时退回内存（`0` 禁用） |
| `RESTART_KILL_NEEDLE` | `opencode` | 杀进程匹配关键字（已排除本工具自身） |
| `RESTART_LAUNCH_CMD` | `opencode` | 新终端启动命令 |
| `RESTART_LAUNCH_CWD` | `$HOME` | 新终端工作目录 |

## API 摘要
`GET /api/health` · `GET /api/state` · `POST /api/switch {tier}` · `POST /api/restart {cwd?}`
· `GET /api/config/items` · `GET /api/config/item/:key?snapshot=` · `POST /api/config/push`
· `GET /api/snapshots` · `POST /api/snapshots/:id/rollback` · `POST /api/snapshots/:id/rollback-file`
完整说明见 `doc/design.md §4`。

## 安全
- 服务端只操作白名单文件（`<prefix>.json` 与 8 个 `<prefix>.<index>-<slug>.json` 档位文件），禁止越界写入。
- **不读取、不同步**含凭据的 `opencode.jsonc` / `auth.json`；仓库不包含任何密钥。

## 平台
首要支持 macOS（重启依赖 osascript）。重启模块按平台抽象，其它平台待实现。
