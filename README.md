# dsh-open-in-folder

> 在 Windows 资源管理器里**右键一个文件夹** → **「在 DeepSeek Harness 中打开」** →
> DSH 窗口前置，并自动把该文件夹作为工作区打开（已有工作区则复用，并进入其空白新会话）。
>
> 灵感来自 ZCode 的「在 ZCode 中打开」；本项目是第三方社区插件，**非 DeepSeek 官方项目**。

![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![dsh](https://img.shields.io/badge/DeepSeek%20Harness-0.2.x-4B6EF5)
![license](https://img.shields.io/badge/license-MIT-green)

---

## 功能特性

- **右键即开**：文件夹、文件夹内空白处、盘符根目录三处右键菜单。
- **一键安装**：支持在 DSH「设置 → 插件 → 添加插件」里输入包名或 GitHub 地址直接安装；插件首次加载会自动装好右键菜单与启动器。
- **自动前置**：DSH 没开就启动它；已经开着就把窗口调到最前。
- **真正设置工作区**：不只是打开 DSH，而是创建/复用该文件夹的工作区，并打开其空白新会话。
- **无需常驻后台**：没有额外的托盘进程，点击时才运行一个 ~18KB 的静默启动器。
- **不修改 DSH 安装包**：只用 DSH 官方的 profile 插件机制（Host 半边）+ 客户端插件机制（`dsh.client`）；可随时卸载。
- **热加载友好**：新版 DSH 通常安装后立即生效，不必重启；重启后也会自动加载。
- **可审计**：插件全部源码在这个仓库里；通信只走本机回环 HTTP + 每次启动随机 token。

## 环境要求

| 项 | 要求 |
| --- | --- |
| 系统 | Windows 10 / 11 |
| DSH | DeepSeek Harness **桌面版**（开发验证版本：0.2.1-rc.2；桌面 profile 名 `desktop`） |
| PowerShell | 5.1（系统自带） |
| 编译启动器 | .NET Framework 4.x 自带的 `csc.exe`（Windows 通常自带；缺失时安装脚本会明确报错） |

> 仅支持 **Windows 桌面版 + 本机 desktop profile**。WSL、远程 Web 部署、多人共用主机不在支持范围。

## 安装（三种方式任选其一，不要混用）

### 方式 A：DSH 插件管理器一键安装（推荐）

打开 DeepSeek Harness → **设置 → 插件 → 添加插件**，在输入框里输入：

```
dsh-open-in-folder
```

点「安装」即可。安装后插件会进入当前 profile 的插件列表并默认启用；**首次加载时自动**：

- 把启动器源码复制到 `%DSH_HOME%\plugins\dsh-open-in-folder` 并用 Windows 自带的 csc 编译 `DSHOpenInFolder.exe`；
- 注册 `HKCU\Software\Classes` 下的三处右键菜单（文件夹 / 空白处 / 盘符）；
- 写 `%DSH_HOME%\open-in-folder\app-path.txt` 与 `shell-integration.json` 标记。

> 网络较慢时，对话框里的「安装源」可切到「中国大陆镜像源」（插件管理器默认会回退 npmmirror）。

### 方式 B：GitHub 仓库地址安装（不需要 npm 账号）

同样的「添加插件」对话框，粘贴本仓库地址：

```
https://github.com/ZHUXUANJIA/dsh-open-in-folder
```

> 需要本机装有 Git。插件管理器安装前会用 `git ls-remote` 做一次连通性检查（默认 5 秒超时）。

### 方式 C：下载 ZIP / 本地安装脚本（离线、完整）

1. 下载本仓库 ZIP，或 `git clone https://github.com/ZHUXUANJIA/dsh-open-in-folder.git` 并解压；
2. 进入目录运行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

   可选参数：`-AppExe "<DeepSeek Harness.exe 路径>"`（自动发现失败时）、`-NoRegistry`、`-NoLauncher`。

安装后通常**立即生效**（DSH 会热加载 profile 变更）；若未生效，请**完全退出 DSH**（窗口 + 系统托盘）后重新打开。
然后在资源管理器里右键任意文件夹，点 **「在 DeepSeek Harness 中打开」**。

### 关于「自动安装外壳集成」（方式 A/B 的说明）

插件 Host 半边启动时会检查 `%DSH_HOME%\open-in-folder\shell-integration.json`：文件缺失或插件版本变化时，会自动补齐启动器 + 右键菜单。相关事件写在 `%DSH_HOME%\open-in-folder\events.log`（`shell-integration-ready` / `shell-integration-failed` / `shell-integration-external`）。

- 需要 .NET Framework 4.x 的 `csc.exe`（Windows 通常自带）；缺失时自动安装会失败并记录日志，此时改用**方式 C** 手动安装即可。
- 已用 `install.ps1` 安装过的机器会被识别为外部管理并跳过（`shell-integration-external`），不会重复安装。
- 可用环境变量 `DSH_OPEN_IN_FOLDER_SKIP_SHELL_INTEGRATION=1` 关闭自动安装。
- 自动安装只写当前用户的 `HKCU` 与 `%DSH_HOME%`，不联网、不需要管理员权限。

> **Windows 11 提示**：本插件使用经典（legacy）右键菜单注册，与 ZCode 等工具的
> 「在 ZCode 中打开」位置一致。如果主菜单里没看到，点 **「显示更多选项」**
> （或 `Shift + 右键` / `Shift + F10`）即可。
>
> 若要在 Win11 新版主菜单直接显示，需要额外的 `IExplorerCommand` COM 扩展 + MSIX
> 稀疏包（需代码签名），本项目暂未提供。

## 卸载

**方式 A/B（插件管理器安装）**：先在「设置 → 插件」里删除 `dsh-open-in-folder`，再运行一次本仓库的 `uninstall.ps1` 清理残留（右键菜单、`%DSH_HOME%\plugins` 安装目录、运行状态目录）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

**方式 C（install.ps1 安装）**：直接运行 `uninstall.ps1`。

- 只移除本插件相关条目，**不会**影响你后来安装的其它 DSH 插件配置；
- profile 备份 `package.json.bak-open-in-folder` 会保留，确认不需要可手动删除；
- 加 `-KeepState` 可保留 `%DSH_HOME%\open-in-folder` 下的日志状态目录。

## 自检与排障

一键自检：

```powershell
# 检查安装、profile 登记、右键菜单、插件是否已加载、最近日志
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1

# 额外做一次真实打开链路测试（会观察 request-queued → pending-claimed → ack opened）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -OpenFolder "D:\path\to\your-project"
```

常用日志：

| 文件 | 内容 |
| --- | --- |
| `%DSH_HOME%\open-in-folder\events.log` | 插件 Host 事件（`host-ready` / `request-queued` / `pending-claimed` / `ack` / `shell-integration-*`） |
| `%DSH_HOME%\open-in-folder\launcher.log` | 启动器事件与错误 |
| `%DSH_HOME%\open-in-folder\state.json` | 当前 DSH Host 端口 / token / pid |

| 现象 | 处理 |
| --- | --- |
| 右键没有菜单项 | 先点「显示更多选项」；`reg query "HKCU\Software\Classes\Directory\shell\DSH.OpenInFolder"` 确认注册；重跑 `install.ps1` |
| 点击没反应或弹错误框 | 看 `launcher.log`；错误框里会带服务端返回的错误文本 |
| 弹「插件未就绪」/ 打开后没切换 | 插件还没被当前 DSH 进程加载：完全退出 DSH 后重开；或看 `events.log` 是否有 `host-ready` |
| 有 `request-queued` 但没打开 | 看 `events.log` 是否有 `pending-claimed`：没有 = 客户端半边未加载（重启 DSH）；有 `ack error` 看 message |
| 菜单图标空白 | 删除 `%DSH_HOME%\plugins\dsh-open-in-folder\assets\icon.ico` 后重跑 `install.ps1` |
| DSH 升级后失效 | 插件没有声明版本约束；升级后若接口变化可能需更新插件，请提 issue |

## 工作原理

```
资源管理器右键菜单
   │  "…\DSHOpenInFolder.exe" "D:\某个文件夹"
   ▼
启动器（C# WinExe，静默，无控制台）
   │  1. 读取 %DSH_HOME%\open-in-folder\state.json（port + 随机 token）
   │  2. GET  /dsh-open-in-folder/health       ← DSH 在运行吗？端口还活着吗？
   │     否 → 启动 DeepSeek Harness.exe 并轮询 health（默认最长 90s）
   │  3. POST /dsh-open-in-folder/request     ← token 头 + UTF-8 JSON { path }
   │  4. DSH 原本已运行 → 再启动一次 exe 触发单实例「前置窗口」
   ▼
DSH 插件 Host 半边（plugin/lib/index.js，运行在 DSH Host 进程内）
   │  校验回环来源 + token + 目录存在 → 入内存队列
   ▼
DSH 插件客户端半边（plugin/lib/client.js，标准 dsh.client 浏览器 bundle）
   │  每 ~1s GET /dsh-open-in-folder/pending 领取
   │  ctx.get('workspaces').create({ path })      → 登记/复用工作区
   │  ctx.get('uiWorkspace').openWorkspace(id)    → 打开该工作区的空白新会话
   │  POST /dsh-open-in-folder/ack                → Host 记录 events.log
   ▼
DSH 界面切换到该文件夹的工作区
```

安全设计：

- 所有 HTTP 路由只接受**回环地址**请求；写入口 `/request` 还要求 `state.json` 里的随机 token；
- `/pending`、`/ack` 拒绝跨站来源，只接受 DSH 页面同源/回环请求；
- 插件以当前用户权限运行，不提升权限，不修改 DSH 安装目录（`app.asar`）；
- 不注入任意脚本：客户端半边是标准 `dsh.client` 模块，由 DSH 自己的模块系统加载。

## 项目结构

```
dsh-open-in-folder/
├─ package.json                # npm/GitHub 安装入口（dsh.bundle.patch + dsh.client 声明）
├─ plugin/                     # DSH 插件（手动安装时复制到 %DSH_HOME%\plugins\dsh-open-in-folder）
│  ├─ package.json             # 插件自身的 package.json（手动安装用）
│  ├─ cordis.patch.yml         # bundle patch：把插件插入 profile 配置树
│  ├─ lib/index.js             # Host 半边：health/request/pending/ack + state.json + events.log
│  ├─ lib/client.js            # 客户端半边：轮询 → 创建工作区 → 打开工作区
│  ├─ lib/shell-integration.js # 首次加载自动安装右键菜单/启动器（方式 A/B）
│  └─ README.md                # 插件实现细节
├─ launcher/
│  ├─ DSHOpenInFolder.cs       # 启动器源码（C# 5 / .NET Framework 4.x，WinExe）
│  ├─ build-launcher.ps1       # 编译脚本（系统 csc）
│  ├─ test-launcher.ps1        # 启动器 mock 自测（41 项）
│  └─ test-installer.ps1       # 安装/卸载回归套件（132 项，隔离 DSH_HOME + 隔离注册表根）
├─ install.ps1                 # 安装（幂等，预检插件源）
├─ uninstall.ps1               # 卸载（幂等，保留其它插件配置）
├─ verify.ps1                  # 一键自检
├─ CONTRACT.md                 # 组件接口契约（launcher ↔ 插件 ↔ 客户端）
└─ research/
   └─ install-and-client-loading.md   # DSH 插件加载机制调研（源码级证据）
```

## 开发与测试

```powershell
# 启动器 mock 自测（不需要真实 DSH）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\test-launcher.ps1

# 安装/卸载回归（隔离 %TEMP% DSH_HOME + 隔离注册表根，不碰真实环境）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\test-installer.ps1

# 编译启动器
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\build-launcher.ps1
```

- 修改 `plugin/` 后重跑 `install.ps1` 即部署（DSH 通常热加载生效）；
- 修改 `launcher/DSHOpenInFolder.cs` 后重跑 `install.ps1` 会重新编译并覆盖已安装 exe；
- 想了解 DSH 桌面版如何加载 profile 插件与外部 `dsh.client` bundle，见
  [research/install-and-client-loading.md](research/install-and-client-loading.md)。

## 已知限制

- 仅 Windows；仅本机 desktop profile（不支持 WSL / 远程 Web 部署）。
- Win11 上走经典右键菜单（「显示更多选项」）；新版主菜单直显需要 MSIX + COM 扩展，暂未实现。
- 同时运行多个 DSH 实例时，`state.json` 以最后启动的 Host 为准；正常使用只有一个实例。
- 安装脚本会修改 `%DSH_HOME%\profiles\desktop\package.json`（首次修改会备份），并把插件目录加入 profile 的 `node_modules`（junction）。
- 若 DSH 未来大版本改动插件/客户端 API，可能需要更新本插件。

## 安全说明

本插件需要修改当前用户的 profile 配置与 `HKCU` 注册表，并编译一个本地启动器 exe。
请只从本仓库获取源码并自行审阅后安装；不要安装来路不明的第三方修改版。
安装脚本不会启动/关闭正在运行的 DSH，也不会联网下载任何内容。

## License

[MIT](LICENSE)。非官方项目，与 DeepSeek 官方无隶属关系。

---

## English (short)

A Windows Explorer context-menu plugin for **DeepSeek Harness desktop**:
right-click a folder → **Open in DeepSeek Harness** → DSH comes to front and opens
that folder as a workspace (reusing the existing one when possible).

Requirements: Windows 10/11, DeepSeek Harness desktop (tested with 0.2.1-rc.2),
PowerShell 5.1. Easiest install: DSH **Settings → Plugins → Add plugin** and enter
`dsh-open-in-folder` (npm) or this repository URL; the plugin auto-installs its
Windows launcher and context-menu entries on first load. Offline install with
`install.ps1`, uninstall with `uninstall.ps1`, self-check with `verify.ps1`.
It does not modify the DSH installation (`app.asar`).
On Windows 11 the item appears under **Show more options** (same as ZCode-style
legacy entries). Licensed under MIT. Not affiliated with DeepSeek.
