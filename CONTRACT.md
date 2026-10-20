# DSH「右键打开文件夹」项目 — 内部接口契约（v1）

> 本文件是插件、启动器、安装脚本之间的接口约定。改动接口请同步更新本文件与相关实现。

## 目标

Windows 资源管理器里右键一个文件夹 → 菜单「在 DeepSeek Harness 中打开」→ DeepSeek Harness（下称 DSH）窗口出现/前置，并把该文件夹作为工作区打开（侧栏出现该工作区 + 主区域进入该工作区的空白新会话）。

实现分两部分：
1. **DSH 插件** `dsh-open-in-folder`：在 DSH Host 里注册本地 HTTP 路由、维护待打开队列、写状态文件；客户端半边轮询队列并调用 DSH 客户端 API 创建工作区 + 打开。
2. **Windows 集成**：资源管理器右键菜单注册 + GUI 启动器 exe（读状态文件 → POST 请求 → 必要时启动 DSH 并等待）。

## 运行环境事实（本机）

- DSH 桌面应用 exe：`<DSH 安装目录>\DeepSeek Harness.exe`（不同机器路径可能不同，必须可配置/自动发现）
- DSH_HOME：`%USERPROFILE%\.dsh`（进程环境变量 `DSH_HOME`，缺省 `%USERPROFILE%\.dsh`）
- 桌面 profile：`%DSH_HOME%\profiles\desktop`（`package.json` 的 `dsh.profile.bundles` 决定加载哪些插件 bundle）
- 已安装的第三方插件样例：`%DSH_HOME%\profiles\desktop\node_modules\dsh-whale-widget`（通过 junction/目录放入 node_modules 即可被 loader 解析）
- 系统：Windows 11 23H2 中文；C# 编译器 `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`（v4.8，**只支持 C# 5 语法**）
- 资源管理器现有第三方菜单样例（ZCode）：
  - `HKCU\Software\Classes\Directory\shell\ZCode.OpenInZCode`，`(Default)`/`MUIVerb` = `在ZCode中打开`，`Icon` = 应用 exe，`command\(Default)` = `"<ZCode 安装目录>\ZCode.exe" --open-workspace "%1"`
  - 本项目采用同样的 HKCU legacy 右键菜单方式（Win11 下与 ZCode 展示位置一致）。

## 固定路径

```
PLUGIN_DIR   = %DSH_HOME%\plugins\dsh-open-in-folder          # 插件安装副本（含 launcher\DSHOpenInFolder.exe）
STATE_DIR    = %DSH_HOME%\open-in-folder                       # 运行时状态目录
STATE_FILE   = %DSH_HOME%\open-in-folder\state.json            # 插件 Host 半边写，launcher 读
EVENTS_LOG   = %DSH_HOME%\open-in-folder\events.log            # 插件写调试日志（JSON Lines）
APP_PATH_FILE= %DSH_HOME%\open-in-folder\app-path.txt          # installer 写：DSH 应用 exe 绝对路径（一行）
ICON_FILE    = %DSH_HOME%\plugins\dsh-open-in-folder\assets\icon.ico
PROFILE_DIR  = %DSH_HOME%\profiles\desktop
```

可选环境变量覆盖（测试用，两边都要支持）：
- `DSH_HOME`：覆盖 DSH home
- `DSH_APP_EXE`：覆盖 DSH 应用 exe 路径
- `DSH_OPEN_IN_FOLDER_STATE_DIR`：覆盖 STATE_DIR（插件与 launcher 都读）

## state.json（插件 Host 半边写；launcher 读）

写入方式：先写 `state.json.tmp` 再 `File.Replace/Move` 原子替换（同目录）。UTF-8 无 BOM。示例：

```json
{
  "schema": 1,
  "pid": 10224,
  "port": 5531,
  "host": "127.0.0.1",
  "token": "64位以内 hex 随机串",
  "startedAt": "2026-10-20T13:00:00.000Z",
  "pluginVersion": "0.1.0"
}
```

- `port`：DSH Host 实际监听端口（每次启动可能变化）
- `token`：每次 Host 进程生命周期内随机生成；launcher POST 请求必须带 `X-DSH-Open-In-Folder-Token` 头
- 插件 dispose 时尽力删除 state.json（仅当 pid 匹配）
- launcher 解析容错：允许空白/上下文字段；用正则取 `"port"\s*:\s*(\d+)`、`"token"\s*:\s*"([^"]+)"` 即可

## HTTP 路由（插件 Host 注册在 DSH 自带 web server 上，均绑定 127.0.0.1）

基础路径 `/dsh-open-in-folder`。所有响应 `application/json; charset=utf-8`。

### `GET /dsh-open-in-folder/health`
- 无需 token；仅回环来源可访问。
- 200 `{"ok":true,"pid":10224,"version":"0.1.0"}`

### `POST /dsh-open-in-folder/request`
- 请求头：`Content-Type: application/json`、`X-DSH-Open-In-Folder-Token: <token>`
- 请求体：`{"path":"D:\\项目\\示例"}`
- 行为：校验 token（精确匹配，常量时间比较即可）、path 为非空绝对路径且存在且为目录；把请求放入内存队列（上限 20 条，超出丢最旧并记日志）。
- 200 `{"ok":true,"requestId":"<uuid>","path":"..."}`
- 错误：400（body/token 不对、路径不存在）、405（方法不对）、413（body > 64KiB）

### `GET /dsh-open-in-folder/pending`
- 客户端半边（DSH 页面内）轮询调用；仅回环/同源来源可访问（**不校验 token**：页面内拿不到 token）。
- 行为：返回并清空队列。
- 200 `{"ok":true,"items":[{"id":"<uuid>","path":"D:\\...","createdAt":"ISO"}]}`

### `POST /dsh-open-in-folder/ack`
- 客户端调用，回传打开结果，Host 只写 EVENTS_LOG。
- Body：`{"id":"<uuid>","stage":"opened|error|unavailable","workspaceId":"...","message":"..."}`
- 200 `{"ok":true}`

## events.log（插件写，排障用）

JSON Lines，每行 `{"ts":"ISO","level":"info|warn|error","event":"...","...":...}`。至少记录：
- `host-ready`（含 port/pid）
- `request-queued`（requestId、path）
- `pending-claimed`（count、ids）
- `ack`（客户端回传）
- `request-rejected`（原因）
- 队列上限丢弃时 `pending-dropped`

launcher 不读 events.log。

## launcher exe 契约

- 交付位置：`PLUGIN_DIR\launcher\DSHOpenInFolder.exe`（installer 用 csc 编译，需 `/target:winexe`，无控制台窗口）
- 命令行：
  ```
  DSHOpenInFolder.exe "<folder>" [--no-activate] [--state-dir <dir>] [--app <dsh-exe>]
  ```
  - `"<folder>"` 必填；`%1`（Directory 菜单）或 `%V`（Background 菜单）传入。相对路径/不存在的目录 → 弹错误框，退出码 2。
  - `--no-activate`：只发请求，不前置窗口（自动化测试用）
  - `--state-dir`：覆盖 STATE_DIR（测试用）
  - `--app`：覆盖 DSH 应用 exe
- 流程：
  1. 解析参数，规范化文件夹路径（`Path.GetFullPath`，去掉末尾 `\`，根盘符保留）。
  2. 定位 state dir（flag → env `DSH_OPEN_IN_FOLDER_STATE_DIR` → `DSH_HOME\open-in-folder`，DSH_HOME env 或 `%USERPROFILE%\.dsh`）。
  3. 读 state.json；若不存在或 `GET health` 失败：定位并 `Start-Process` DSH exe，然后每 500ms 轮询 health，最长 90 秒。
  4. `POST request`（带 token 头 + UTF-8 JSON body）；连接失败时每 600ms 重试，最长 90 秒；HTTP 4xx 时直接失败并显示服务端 `error` 信息。
  5. 成功且非 `--no-activate` 且启动前 DSH 已在运行 → 再 `Start-Process` DSH exe 一次以触发单实例聚焦；启动前未运行则不再重复启动。
  6. 成功静默退出 0。
- 失败：MessageBox（System.Windows.Forms）中文错误摘要 + 退出码 1；不弹控制台窗口。
- 定位 DSH exe 顺序：`--app` → env `DSH_APP_EXE` → `%STATE_DIR%\app-path.txt` → 注册表 `HKCU\Software\Classes\dsh\shell\open\command`（取第一个带引号/不带引号的 exe 路径）→ 固定候选（仅本机默认 `<DSH 安装目录>\DeepSeek Harness.exe`）。
- 编译：`csc.exe /nologo /target:winexe /codepage:65001 /out:... /r:System.Windows.Forms.dll /r:System.Drawing.dll DSHOpenInFolder.cs`。源码 UTF-8 **带 BOM**（csc 4.8 需要，否则中文乱码）；C# 5 语法（无 `$""`、无 `?.`、无 `nameof`）。

## 右键菜单注册（installer 写 HKCU，幂等）

```
HKCU\Software\Classes\Directory\shell\DSH.OpenInFolder
  (Default)  = 在 DeepSeek Harness 中打开     (REG_SZ)
  MUIVerb    = 在 DeepSeek Harness 中打开
  Icon       = <ICON_FILE>
  \command\(Default) = "<PLUGIN_DIR>\launcher\DSHOpenInFolder.exe" "%1"

HKCU\Software\Classes\Directory\Background\shell\DSH.OpenInFolder
  (Default)  = 在 DeepSeek Harness 中打开
  MUIVerb    = 在 DeepSeek Harness 中打开
  Icon       = <ICON_FILE>
  \command\(Default) = "<PLUGIN_DIR>\launcher\DSHOpenInFolder.exe" "%V"
```
- 用 `[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey` 或 `New-Item -Path ... -Force` 写；值名 `(Default)` 用 `SetValue($null, ...)`（REG_SZ）。
- 图标：installer 从 DSH exe 提取：`[System.Drawing.Icon]::ExtractAssociatedIcon($appExe).ToBitmap()` 保存为 ico（可用 `[System.Drawing.Icon]::ExtractAssociatedIcon(...).Save($fileStream)`），失败则 Icon 用 DSH exe 路径兜底。
- uninstall 删除这两个键子树。

## installer 契约（install.ps1）

参数：`-AppExe <path>`（可选）、`-PluginSource <dir>`（默认 `$PSScriptRoot\plugin`）、`-Profile desktop`、`-NoRegistry`、`-NoLauncher`、`-Quiet`。

步骤（幂等，可重复运行）：
1. 解析 DSH_HOME / app exe（同上顺序）。
2. 创建 `PLUGIN_DIR`，把 `-PluginSource` 内容复制进去（保留 `lib\`、`package.json`、`cordis.patch.yml`、`README.md`）。
3. 编译 launcher（除非 `-NoLauncher`）到 `PLUGIN_DIR\launcher\DSHOpenInFolder.exe`；编译失败直接报错终止。
4. 写 `APP_PATH_FILE`（UTF-8 无 BOM，单行绝对路径）。
5. 建立 profile 解析：`PROFILE_DIR\node_modules\dsh-open-in-folder` → 指向 `PLUGIN_DIR` 的 junction（`New-Item -ItemType Junction`，无需管理员；已存在则先删除旧 junction）。
6. 备份 `PROFILE_DIR\package.json` → `package.json.bak-open-in-folder`（仅首次）；用 PowerShell JSON 编辑：
   - `dependencies["dsh-open-in-folder"] = "file:<PLUGIN_DIR 正斜杠路径>"`（若已有等价项则不重复改）
   - `dsh.profile.bundles` 数组末尾追加 `"dsh-open-in-folder"`（若不存在）
   - 用 UTF8 无 BOM 写回，保持 2 空格缩进（ConvertTo-Json -Depth 20 可接受）
7. 注册右键菜单（除非 `-NoRegistry`），提取图标。
8. 输出摘要 + 提示：需要**完全退出 DSH（托盘/窗口退出）后重新打开**才会加载插件；`install.ps1` 本身不重启 DSH。

## uninstall.ps1

- 删除注册表两项、删除 junction、从 profile package.json 移除依赖与 bundles 项（从 `.bak-open-in-folder` 恢复更稳）、删除 `PLUGIN_DIR`、删除 `STATE_DIR`（保留 `-KeepState` 参数则不删）。幂等。

## 自测要求（开发/提交前）

1. `launcher/test-launcher.ps1`：用 `System.Net.HttpListener` 在随机端口起 mock Host，写临时 state dir 的 state.json（带随机 token），调用 `DSHOpenInFolder.exe <临时目录> --state-dir <临时> --no-activate --app <不存在的exe但前面已 health 成功>`；断言 mock 收到 1 个 POST `/dsh-open-in-folder/request`、JSON path 正确、token 头正确、退出码 0。再测：token 错（mock 返回 400）→ 退出码非 0；目录不存在 → 退出码 2。
2. `install.ps1 -NoRegistry -NoLauncher` 在**临时 DSH_HOME**（`$env:DSH_HOME` 指向 temp，并提前创建 `profiles\desktop\package.json` 模板）上演练：断言 junction 建立、package.json 出现依赖与 bundle 项、不污染真实 profile。
3. 语法检查：`powershell.exe -NoProfile -Command "[scriptblock]::Create((Get-Content -Raw install.ps1)) | Out-Null"`（PS5.1 兼容）。

## 建议交付清单

```
launcher/DSHOpenInFolder.cs
launcher/build-launcher.ps1
launcher/test-launcher.ps1
install.ps1
uninstall.ps1
```
所有 .ps1 / .cs 以 **UTF-8 BOM** 保存（中文）。不要修改 `plugin/`、`CONTRACT.md`、`README.md`、`tests/`。
