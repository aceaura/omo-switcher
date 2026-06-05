# omo-switcher 需求文档 (requirements.md)

> 本文件为**需求事实来源 (source of truth)**。配套 `design.md` 描述如何实现。
> 两份文档力求自包含：任何人（或任何 LLM）读完即可独立继续开发。
> 文档语言为中文，代码标识符 / 路径 / 接口名为英文。

最后更新：2026-06-02

---

## 0. 一句话目标

为本机的 [opencode](https://opencode.ai) 提供一个“**性能/消耗档位切换器**”：在 `omo`（`oh-my-openagent`）和
`omo-slim`（`oh-my-opencode-slim`）两个插件之间，按统一的“性能版本”一键切换配置文件，并一键重启 opencode。
同时提供本地 ↔ 远端的**带版本历史的配置同步**能力。

---

## 1. 术语表 (Glossary)

| 术语 | 含义 |
| --- | --- |
| **opencode** | 本机安装的 AI 编码 Agent（TUI 为主）。二进制：`~/.opencode/bin/opencode`。配置目录：`~/.config/opencode/`。 |
| **omo** | 插件 `oh-my-openagent`。其生效配置文件为 `~/.config/opencode/oh-my-openagent.json`。 |
| **omo-slim** | 插件 `oh-my-opencode-slim`。其生效配置文件为 `~/.config/opencode/oh-my-opencode-slim.json`。 |
| **provider** | 上面两者的统称。本工具内部 id：`omo`、`omo-slim`。 |
| **性能档位 (tier)** | 同一份配置的不同消耗/质量取向。共 4 档，见下表。omo 与 omo-slim 共享同一套档位划分。 |
| **档位文件 (tier file)** | 形如 `<prefix>.<index>-<slug>.json` 的候选配置文件。例：`oh-my-openagent.3-balanced.json`。 |
| **生效文件 (active/base file)** | 形如 `<prefix>.json`，是 opencode 真正读取的文件。切换 = 把某档位文件**整文件覆盖**到它。 |
| **当前配置 (current config)** | “当前生效的是哪个档位”这一**选择状态**（指针 + base 文件内容）。属于本机/客户端私有，**默认不参与同步、不被覆盖**。 |
| **同步 (sync)** | 在本地 SQLite 与远端服务器之间传输“配置项”。可双向、可全量、可单项，均需勾选 + 确认。 |
| **快照/版本 (snapshot/version)** | 服务端按时间戳保留的一次完整配置集合。不可变。 |
| **配置项 (config item)** | 一个可被同步/版本化的单位 = 一个配置文件（以文件名为 key，内容为字节/文本）。 |

### 1.1 性能档位定义（4 档，omo 与 slim 共享）

| index | slug | 展示名 | 含义 |
| --- | --- | --- | --- |
| 1 | `token-saving` | 省钱 · Token Saving | 最省 token / 成本最低 |
| 2 | `predictable-cost` | 可预测成本 · Predictable Cost | 成本稳定可控 |
| 3 | `balanced` | 均衡 · Balanced | 成本与质量折中（推荐默认） |
| 4 | `quality-first` | 质量优先 · Quality First | 质量优先，成本最高 |

> “omo 和 slim 共享只标记性能版本”的含义：**界面下拉框只让用户选 1 个性能档位**（4 选 1）；
> 选定后会**同时**应用到 omo 与 omo-slim 两个 provider（各自复制自己的同档位文件到各自的 base 文件）。

---

## 2. 已确认的环境事实 (Discovered facts)

> 这些是在用户机器上实测得到的，开发时务必以实际扫描为准（文件可能增减）。

- 平台：macOS（Darwin 24.6.0），shell：zsh。
- Node：v25.8.0；npm：11.11.0。
- opencode 二进制：`/Users/<user>/.opencode/bin/opencode`，支持子命令：`tui`(默认)、`serve`、`web`、`run`、`attach` 等。
- opencode 配置目录：`~/.config/opencode/`，其中实测存在：
  - `oh-my-openagent.json`（omo 生效文件）
  - `oh-my-openagent.1-token-saving.json` / `.2-predictable-cost.json` / `.3-balanced.json` / `.4-quality-first.json`
  - `oh-my-opencode-slim.json`（slim 生效文件）
  - `oh-my-opencode-slim.1-token-saving.json` / `.2-predictable-cost.json` / `.3-balanced.json` / `.4-quality-first.json`
  - `opencode.jsonc`（opencode 主配置，含 `"plugin": ["oh-my-openagent@latest", "oh-my-opencode-slim"]` 与 provider 凭据；**本工具不修改它**）
- 档位文件**带 UTF-8 BOM**，且为 PowerShell `ConvertTo-Json` 风格缩进 → **切换必须按字节整文件复制**（`fs.copyFile`），不要做 JSON 解析再序列化，以免破坏格式/BOM。
- 切换的本质：`copy(<prefix>.<index>-<slug>.json) -> <prefix>.json`。
- “当前档位”检测方式：把 base 文件字节与每个档位文件字节逐一比对（`Buffer.equals`），相等者即当前档位；都不等则为 `null`（说明被手动改过）。实测初始状态两个 base 文件均与任何档位文件**不一致**（旧格式），属正常。
- **Redis 未安装**：开发环境需自行 `npm install`；服务端在 Redis 不可用时应能退回内存存储（见非功能需求）。
- 进程：实测当前无 opencode 在跑。重启逻辑需对“无进程”场景健壮。

---

## 3. 总体架构（用户指定）

- **服务端**：Node.js + **Redis**，前置 **nginx**（nginx 由用户自行负责，本项目不实现）。
  - 服务端负责：扫描/读取配置、执行档位切换、重启 opencode、**版本化存储所有配置快照**、提供同步 API。
  - 注意：服务端与 opencode 运行在**同一台机器**上（因为要操作 `~/.config/opencode` 与重启本机 opencode）。
- **客户端**：**Flutter macOS 桌面应用**。
  - 本地配置走客户端文件缓存，隔离本机私有设置与可同步配置项。
  - 提供 UI：性能档位下拉框、重启按钮、同步面板（含可编辑的服务器同步地址）、远端历史版本浏览/回滚。
- **代码托管**：项目需推送到 `github.com`（仓库归属 `aceaura`）。

```
┌────────────────────────┐        HTTP/JSON        ┌───────────────────────────┐
│   Flutter 客户端       │  ───────────────────▶   │   nginx  →  Node 服务端    │
│  - 下拉框/重启/同步UI   │  ◀───────────────────   │  - Express API            │
│  - 本地缓存/私有设置    │                          │  - Redis (状态+版本快照)   │
└────────────────────────┘                          │  - fs 操作 ~/.config/opencode│
                                                     │  - 重启 opencode(本机)     │
                                                     └───────────────────────────┘
```

> 说明：客户端与服务端可能同机也可能异机。文件切换/重启**只能由服务端**执行（它在 opencode 所在机器上）。
> 客户端只是 UI + 本地缓存/历史。

---

## 4. 功能需求 (Functional Requirements)

### FR-1 性能档位切换（核心）
- FR-1.1 界面提供**一个下拉框**，列出 4 个性能档位（按 index 排序，展示中文名）。
- FR-1.2 下拉框只表示“性能版本”，选定后**同时**作用于 omo 与 omo-slim。
- FR-1.3 用户选择并触发切换后，服务端对每个 provider 执行 `copy(tierFile -> baseFile)`。
- FR-1.4 切换必须**原子且可回滚**：先备份原 base 文件，复制失败时回滚已改动的文件，保证不出现“omo 改了 slim 没改”的半成品状态。
- FR-1.5 界面需展示**当前生效档位**（来自服务端字节比对），并在 omo 与 slim 不一致时给出警告（显示各自档位）。
- FR-1.6 切换成功/失败都要有明确反馈，并写入**切换历史**（服务端 Redis 为权威）。

### FR-2 重启 opencode（核心）
- FR-2.1 界面提供“重启 opencode”按钮。
- FR-2.2 点击后服务端执行：**杀掉正在运行的 opencode 进程** → **新开一个 macOS 终端窗口启动 opencode**（osascript / `Terminal`）。
- FR-2.3 杀进程需精确：按命令行关键字匹配 opencode（默认关键字 `opencode`），但**必须排除本工具自身进程**（如命令行含 `omo-switcher`）和当前进程 pid。
- FR-2.4 无进程在跑时不报错，直接进入“新开终端启动”。
- FR-2.5 启动命令、工作目录、kill 关键字均可通过配置/环境变量覆盖。
- FR-2.6 返回执行日志（杀了哪些 pid、启动命令）给界面展示。

### FR-3 配置同步（本地 ↔ 远端，带版本）
- FR-3.1 **隔离本地配置与远端配置**：界面需清晰区分“本地”和“远端”两栏/两区，分别展示各自的配置项及差异。
- FR-3.2 **同步方向可选（双向）**：
  - 拉取 `pull`：远端 → 本地；
  - 推送 `push`：本地 → 远端。
- FR-3.3 **同步粒度可选**：
  - 全部同步（选中所有配置项）；
  - 单个同步（选中某个/某几个配置项）。
- FR-3.4 **所有同步都需先勾选（checkbox）再点确认**，不得静默/自动覆盖。确认前应展示将要发生的变更摘要（新增/覆盖/删除、涉及哪些文件）。
- FR-3.5 **“当前配置 (current config) 隔离、不被覆盖**：用户的“当前生效档位选择”及本机私有设置（如服务器地址）**默认不在同步集合内**，任何同步都不会改动它。
  - （此即早期需求“从服务端拉取配置全盘覆盖本地 SQLite 配置，但当前配置不覆盖”的精确化：可同步集合 = 配置项文件；不可同步集合 = 当前选择 + 本机私有设置。）
- FR-3.6 **服务器同步地址可在界面编辑**并持久化到本机私有设置（不被同步覆盖）。需校验 URL 合法性，提供“测试连接”。

### FR-4 远端版本历史
- FR-4.1 服务端**按时间戳保留所有历史版本**（快照不可变，永不自动删除，除非显式策略）。
- FR-4.2 每次 `push` 到远端都会**生成一个新快照**（含本次推送涉及的完整配置项集合 + 时间戳 + 可选备注）。
- FR-4.3 界面可**浏览远端历史版本列表**（时间戳、备注、包含的文件），并可查看任一版本中**单个文件的内容/差异**。
- FR-4.4 **远端整体回滚**：选择某个历史版本，将远端“当前指针”回滚到该版本（实现为生成一个内容等于旧版本的新快照，保留可追溯性）。
- FR-4.5 **远端单文件回滚**：从某历史版本中选择**单个文件**回滚（只把该文件恢复到旧内容，生成新快照）。
- FR-4.6 **本地同步可指定任意历史版本作为对象**：即 `pull` 时不仅能拉“远端最新”，也能选择拉取“某个历史版本”的全部或单个文件到本地。

### FR-5 GitHub 推送
- FR-5.1 项目作为独立仓库推送到 `github.com`（归属 `aceaura`）。
- FR-5.2 需包含 `README.md`、`.gitignore`、本 `doc/`、可运行的安装与启动说明。
- FR-5.3 不得提交任何密钥/凭据（opencode.jsonc 含 apiKey，**严禁**纳入本仓库或同步集合）。

---

## 5. 非功能需求 (Non-Functional)

- NFR-1 **健壮性/可降级**：Redis 不可用时服务端退回进程内内存存储（带告警），核心切换/重启仍可用。
- NFR-2 **安全**：
  - 切换前备份、失败回滚（见 FR-1.4）。
  - 服务端只允许操作白名单文件（`<prefix>.json` 与 `<prefix>.<index>-<slug>.json`），禁止任意路径写入（防目录穿越）。
  - 不读取/不同步含凭据的 `opencode.jsonc`、`auth.json`。
- NFR-3 **可移植/可配置**：所有路径、端口、Redis、重启命令均可经环境变量覆盖。
- NFR-4 **跨机一致性**：当前档位检测、同步差异计算以**字节内容**为准（保留 BOM）。
- NFR-5 **可观测**：服务端记录操作日志；接口返回结构化结果（成功/失败/日志）。
- NFR-6 **平台**：首要支持 macOS（重启依赖 osascript）。重启模块需可插拔以便将来支持其它平台。

---

## 6. 范围之外 (Out of scope)

- nginx 的安装与配置（用户负责）。
- 修改 `opencode.jsonc` 主配置或 opencode 本身。
- 多用户/权限/鉴权体系（当前假定单用户本机/可信内网；如需鉴权见 design 的“开放问题”）。
- Windows/Linux 的重启实现（预留接口，暂不实现）。

---

## 7. 验收标准 (Acceptance)

1. 启动服务端 + 客户端，下拉框能列出 4 个档位并显示当前生效档位。
2. 选择某档位 → 确认 → 两个 base 文件均被正确覆盖为对应档位文件（字节一致），历史新增一条。
3. 点击“重启 opencode”：若有进程则被杀，随后新终端窗口打开并运行 opencode；界面显示执行日志。
4. 同步面板能分别展示本地/远端配置项；勾选 + 确认后按方向正确传输；当前配置与服务器地址不受影响。
5. 远端历史可浏览；可整体回滚、可单文件回滚；本地可从指定历史版本拉取。
6. 服务器同步地址可在 UI 编辑、持久化、并“测试连接”。
7. 仓库可在 GitHub 打开，按 README 可一键安装运行，且不含任何凭据。

---

## 8. 开放问题 / 待用户确认 (Open questions)

> 标注 **[假设]** 的为当前文档采用的默认决策，可被推翻。

- Q1 同步的“配置项”集合是否仅包含 8 个 tier 文件？**[假设]** 是：仅 `oh-my-openagent.*-*.json` 与 `oh-my-opencode-slim.*-*.json` 这 8 个档位文件。base 文件不同步（属当前配置）。
- Q2 远端快照粒度：全局快照 vs 每文件独立版本链？**[假设]** **全局快照**（每次 push 一个时间戳快照，含完整集合），单文件回滚=从某快照取该文件生成新快照。这同时满足 FR-4.4 与 FR-4.5。
- Q3 客户端本地缓存采用 Flutter 文件存储；如后续需要结构化查询，可再引入 SQLite 插件。
- Q4 是否需要鉴权（token）？**[假设]** 暂不做，预留 `Authorization` 头透传位。
- Q5 “双向同步”冲突如何处理（本地与远端都改过）？**[假设]** 不做自动三路合并；同步是“覆盖式”，由用户勾选方向与文件，确认页展示差异，用户自担覆盖。
- Q6 删除语义：远端有、本地无的项，pull 时是否在本地创建？push 时本地无的项是否删远端？**[已实现]** 同步仍按所选方向写入；删除必须显式操作。常用配置删除 zip，本地仓库删除缓存项，云端仓库以“删除后的剩余集合”生成新快照。

---

## 9. 当前实现进度（截至本文件生成时）

- [x] 项目骨架：根 `package.json`、`.gitignore`、`README.md`
- [x] 服务端 `config.js` / `store.js` / `presets.js`
- [x] 服务端 `switcher.js`（备份+复制+回滚）— curl 验证字节一致
- [x] 服务端 `restart.js`（杀进程 + osascript 新终端）
- [x] 服务端 `versions.js`（Redis 快照版本库、整体/单文件回滚）— curl 验证 head 移动与回滚还原
- [x] 服务端 `sync.js`（配置项扫描 + diff + key 白名单）
- [x] 常用配置 / 本地仓库 / 云端仓库显式删除
- [x] Windows/macOS 客户端安装器脚本
- [x] 服务端 `index.js`（全部 Express 路由）— health/state/switch/snapshots 已实测
- [x] 客户端 Flutter：`client/lib/main.dart` + `client/test/widget_test.dart`（`flutter test` 通过）
- [ ] 客户端 GUI 实跑（需本机 `flutter run -d macos`）
- [ ] GitHub 推送（仓库归属 aceaura，已确认不含凭据）
- [ ] 端到端联调（Flutter ↔ server）与 §7 验收

> 服务端 FR-1/FR-2/FR-3/FR-4 已全部实现并用 curl 冒烟通过（含内存退回）。
> 剩余主要是在有 GUI 的本机实跑 Flutter 客户端、再推 GitHub。
