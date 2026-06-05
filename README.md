# omo-switcher

![omo-switcher logo](client/assets/brand/omo_switcher_logo.png)

为本机 [opencode](https://opencode.ai) 在 **omo**（`oh-my-openagent`）与 **omo-slim**（`oh-my-opencode-slim`）
两个插件之间，按统一的「性能/消耗档位」一键切换配置文件，并一键重启 opencode。
另含**本地 ↔ 远端的带版本历史的配置同步**。

> 设计与需求详见 [`doc/requirements.md`](doc/requirements.md) 与 [`doc/design.md`](doc/design.md)。

## 功能
- **档位切换**：下拉框选 1 个性能版本（省钱 / 可预测成本 / 均衡 / 质量优先），同时应用到 omo 与 omo-slim。按字节整文件复制，保留 BOM/格式；失败自动回滚。
- **重启 opencode**：杀掉运行中的 opencode 进程，新开 macOS 终端窗口重新启动。
- **同步**：本地 SQLite ↔ 远端服务器，双向、可全量/单项、勾选 + 确认；当前档位与服务器地址等本机私有设置**永不被同步覆盖**。
- **删除**：常用配置、本地仓库、云端仓库均可删除勾选档位；云端删除通过新快照表达，不破坏历史版本。
- **版本历史**：服务端按时间戳保留全部快照，可浏览、整体回滚、单文件回滚；本地可从任意历史版本拉取。
- 服务器同步地址可在界面编辑。

## 架构
- **服务端**：Node.js + Express + Redis（前置 nginx，由你自行配置）。负责扫描/切换/重启/快照版本库/同步 API。须与 opencode 同机。
- **客户端**：Flutter macOS 桌面应用，本地文件存配置项与私有设置。

## 快速开始
```bash
npm run install:all          # 安装 server 依赖
flutter pub get client       # 安装 Flutter client 依赖

# 服务端（无 Redis 也能跑：自动退回内存存储并告警）
npm run server               # 默认 http://0.0.0.0:7600

# 客户端（Flutter macOS）
npm run client
```
可选启用持久化版本库：`brew install redis && brew services start redis`。

### 安装器
```bash
# Windows: 生成图形界面的 release/installer/omo-switcher-windows-setup.msi
# 需要 .NET SDK；脚本会在 .tools/ 下安装 WiX Toolset。
npm run installer:windows

# macOS: 生成 release/installer/omo-switcher-macos.pkg
# 使用 Xcode Command Line Tools 的 pkgbuild；安装目录为 /Applications。
npm run installer:macos
```

### Docker（服务端 + Redis）
```bash
# 把宿主机的 opencode 配置目录挂入容器；OPENCODE_DIR 可覆盖
OPENCODE_DIR=$HOME/.config/opencode docker compose up -d --build
curl http://127.0.0.1:7600/api/health
```
- 切换档位 / 同步 / 版本历史：容器内完全可用（读写挂载进来的配置目录）。
- **重启 opencode**（`POST /api/restart`）依赖宿主机进程与 macOS osascript，**容器内无法操作宿主 GUI/进程**，请在宿主机手动重启，或仅用容器做「切换 + 同步」。

### 环境变量（服务端）
| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OMO_SWITCHER_PORT` | `7600` | 监听端口 |
| `OMO_SWITCHER_HOST` | `0.0.0.0` | 监听地址；如只允许本机访问可设为 `127.0.0.1` |
| `OPENCODE_DIR` | `~/.config/opencode` | opencode 配置目录 |
| `REDIS_URL` | `redis://127.0.0.1:6379` | Redis 地址 |
| `REDIS_FALLBACK` | `1` | Redis 不可用时退回内存（`0` 禁用） |
| `RESTART_KILL_NEEDLE` | `opencode` | 杀进程匹配关键字（已排除本工具自身） |
| `RESTART_LAUNCH_CMD` | `opencode` | 新终端启动命令 |
| `RESTART_LAUNCH_CWD` | `$HOME` | 新终端工作目录 |

## API 摘要
`GET /api/health` · `GET /api/state` · `POST /api/switch {tier}` · `POST /api/restart {cwd?}`
· `GET /api/config/items` · `GET /api/config/item/:key?snapshot=` · `POST /api/config/push`
· `DELETE /api/config/items`
· `GET /api/snapshots` · `POST /api/snapshots/:id/rollback` · `POST /api/snapshots/:id/rollback-file`
完整说明见 `doc/design.md §4`。

## 安全
- 档位包 key 允许大小写字母、数字、下划线、点、连字符，且必须以字母/数字开头；服务端仍拒绝路径分隔符和越界写入。
- **不读取、不同步**含凭据的 `opencode.jsonc` / `auth.json`；仓库不包含任何密钥。

## 平台
客户端支持 Windows 与 macOS 安装器；重启模块首要支持 macOS（依赖 osascript）。
