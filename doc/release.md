# omo-switcher 发布文档 (release.md)

> 本文件描述**如何发布新版本**：从改版本号到自动构建 Windows / macOS 安装包，
> 并发布到 GitHub Releases 供用户直接下载。配套 `requirements.md` / `design.md`。
> 文档语言为中文，代码标识符 / 路径 / 命令为英文。

最后更新：2026-06-09

---

## 0. 一句话流程

**改版本号 → `npm run release` → GitHub 自动构建并发布安装包。**

```bash
# 1. 在 client/pubspec.yaml 把 version 改成新版本（如 1.0.7+8），提交
# 2. 一条命令打标签、推送、触发构建：
npm run release
# 3. 几分钟后，安装包出现在 GitHub Releases 的固定下载地址（见 §4）
```

---

## 1. 原理

- **版本号唯一来源**：`client/pubspec.yaml` 的 `version:` 字段（如 `1.0.6+7`）。
  `+` 后是 build 号，发布时只取 `+` 前的 `1.0.6` 作为标签 `v1.0.6` 和安装包版本。
- **触发器**：推送 `vX.Y.Z` 形式的 git 标签，会触发 [`.github/workflows/release.yml`](../.github/workflows/release.yml)。
- **构建**：在 GitHub 托管的 `windows-latest` / `macos-latest` runner 上分别构建 MSI / PKG，
  复用本地脚本 [`scripts/build-installer-windows.ps1`](../scripts/build-installer-windows.ps1)
  与 [`scripts/build-installer-macos.sh`](../scripts/build-installer-macos.sh)。
- **发布**：构建产物作为 GitHub Release 资产上传，下载地址固定（见 §4）。

---

## 2. 标准发布步骤

### 2.1 前置条件
- 工作目录干净（已提交想发布的改动）；标签指向的是**已提交的 HEAD**，不含未提交的本地修改。
- 有 `origin` 远端的推送权限。
- 本机装有 Node.js（仅触发脚本需要；构建在云端 runner 上完成，本机**无需** Flutter / Xcode / Visual Studio）。

### 2.2 操作
```bash
# ① 改版本号：编辑 client/pubspec.yaml，例如
#      version: 1.0.6+7   ->   version: 1.0.7+8
# ② 提交并推送到 master（务必先让 .github/workflows/release.yml 存在于远端）
git add client/pubspec.yaml
git commit -m "release: v1.0.7"
git push origin master

# ③ 触发发布：从 pubspec 读版本，打 v1.0.7 标签并推送
npm run release
```

`npm run release` 实际调用 [`scripts/trigger-release.mjs`](../scripts/trigger-release.mjs)，
完成后会打印 Actions 链接与下载地址。

### 2.3 观察构建
- 浏览器打开 `https://github.com/aceaura/omo-switcher/actions`，等三个 job 全绿：
  `build-windows` / `build-macos` / `release`。
- 装了 GitHub CLI 的话：`gh run watch`。

---

## 3. 触发脚本选项

`scripts/trigger-release.mjs`（对应 `npm run release`）支持：

| 命令 | 作用 |
| --- | --- |
| `npm run release` | 用 pubspec 版本打 `vX.Y.Z` 标签并推送（标准路径） |
| `npm run release -- --tag v1.2.3` | 自定义标签 |
| `npm run release -- --allow-dirty` | 工作目录有未提交改动时仍继续（标签仍指向 HEAD） |
| `npm run release -- --remote upstream` | 推送到非 `origin` 的远端 |
| `npm run release:dispatch` | 不打标签，直接用 `gh` CLI 手动触发 workflow（需安装并登录 `gh`） |

> 脚本会在标签已存在时报错退出，提醒你先升版本号或删除旧标签——避免重复发布同一版本。

---

## 4. 下载地址（给用户）

构建通过后，二进制可在以下**稳定地址**直接下载（始终指向最新 Release）：

- Windows：`https://github.com/aceaura/omo-switcher/releases/latest/download/omo-switcher-windows-setup.msi`
- macOS：`https://github.com/aceaura/omo-switcher/releases/latest/download/omo-switcher-macos.pkg`

资产文件名跨版本保持不变，因此这两个链接可直接写进应用内的「下载/更新」入口。
指定版本的地址形如 `.../releases/download/v1.0.6/omo-switcher-windows-setup.msi`。

---

## 5. 手动触发（不打标签）

无需新版本、只想跑一次构建时：

- **网页**：Actions 标签页 → 选 `release` 工作流 → `Run workflow`。
  - `tag` 留空：只产出安装包 artifact（在 run 页面下载），**不发布** Release。
  - `tag` 填 `vX.Y.Z`：构建并发布对应 Release。
- **命令行**：`npm run release:dispatch`（用 pubspec 版本作为 tag 触发发布）。

---

## 6. 常见情况

- **构建失败后重跑**：修好问题、推到 master 后，在 Actions 页面对该 run 点 `Re-run jobs`；
  或删除并重推标签：
  ```bash
  git push origin :refs/tags/v1.0.6   # 删远端标签
  git tag -d v1.0.6                    # 删本地标签
  npm run release                      # 重新触发
  ```
  workflow 对已存在的 Release 会用 `gh release upload --clobber` 覆盖同名资产，可安全重跑。
- **预发布版**：标签带连字符（如 `v1.1.0-rc1`）会自动标记为 GitHub **pre-release**，
  不会顶掉 `latest`。
- **本地出包**（不经 CI）：`npm run installer:windows` / `npm run installer:macos`，
  产物在 `release/installer/`（需本机装好 Flutter 等工具链）。

---

## 7. 代码签名（待办）

CI 当前**未做代码签名**（无证书）：

- macOS：`.pkg` 未签名，用户首次需右键 →「打开」绕过 Gatekeeper。
- Windows：`.msi` 未签名，会触发 SmartScreen，用户需选「仍要运行」。

如需正式签名，把 Apple Developer ID / Authenticode 证书配成仓库 Secret，
并在 `release.yml` 的对应 job 增加签名步骤（`productsign` / `signtool`）。
