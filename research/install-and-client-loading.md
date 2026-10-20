# DSH 桌面安装机制与客户端插件加载调研

> 开发期调研记录（asar 源码证据 + 隔离环境实验）
> 结论对象：DSH 0.2.1-rc.2（Electron 桌面版，`<DSH 安装目录>`，asar 内 `dsh/`）
> 证据路径约定：`app.asar!/dsh/...` 表示 `<DSH 安装目录>\resources\app.asar` 内部虚拟路径；行号来自 `asarx.js` 提取出的同名文件（内容与 asar 一致）。
> 验证方式：静态读源码 + **隔离 `DSH_HOME` 真机启动实验**（临时目录，未触碰/重启真实 DSH、未改真实 profile 与 node_modules）。

---

## 0. 结论摘要（TL;DR）

| 问题 | 结论 | 置信度 |
|---|---|---|
| A1 profile bundle 如何解析 | 桌面壳 `main.js` 把 `%DSH_HOME%\profiles\desktop` 交给 `dsh-desktop-host`，后者用 `loadProfileDirectory("dsh", profileDir, installAnchor)` 读 profile `package.json` 的 `dsh.profile.bundles`，逐包按 **installAnchor 优先、profile 目录其次** 的 Node require 解析路径找包，再加载其 `dsh.bundle.patch` | 确认 |
| A2 启动时会不会自动 pnpm install / 校验 lockfile | **不会**。启动链只有只读的 `PluginPackages`（运行时解析表）；`dsh-plugin-manager` 只在显式 install/remove 操作时调用 pnpm；启动不读 `pnpm-lock.yaml`/`.modules.yaml` | 确认（源码+实验） |
| A2 失败会不会破坏启动 | 分三类：bundle 不可解析 → 跳过并 stderr 警告，**应用照常启动**；profile `package.json` 坏（JSON/BOM）→ **启动失败**；插件声明了 `dsh.client` 但 `lib/client.js` 缺失/`dsh.client` 非法 → **`modules` 属 required 条目 → 整体启动失败**（已实测复现） | 确认 |
| A3 最低加载条件 | ① `profile/node_modules/<name>/package.json` 可解析（junction 可行）② `dsh.profile.bundles` 含该名 ③ 包内 `dsh.bundle.patch` 指向存在的 patch ④ patch 里行的 `name` 能解析到包。**不需要** dependencies 登记、不需要 pnpm install、不需要 lockfile/.modules.yaml；要 client 半边则额外要求 `dsh.client.platform="web"`+`exports["./client"]`+**已构建的 client.js** | 确认（多组实验） |
| A3 官方安装路径 | 存在**桌面版自带 CLI**：`<app>\resources\runtime\cli\bin\dsh.cmd` → `dsh-desktop-host/lib/cli.js`，以 `manageDesktopProfile:true` + 自带 pnpm 运行 `dsh plugin --profile desktop …`（公开 `dsh` CLI 才拒绝 desktop）。`plugin add file:<dir>` 会一次性更新 deps、bundles、lockfile、node_modules | 确认（隔离环境实验） |
| A4 推荐 | **保持当前手动方案**（复制到 `%DSH_HOME%\plugins` + junction + 改 package.json），补 3 个硬化点（client.js 存在性校验、UTF-8 无 BOM、DSH 运行中处理）；不跑 pnpm、不改 lockfile。桌面 CLI 作为等价/官方备选与修复手段 | 建议 |
| B1 第三方 `dsh.client` 在桌面应用能否加载 | **能**。链路：client-modules 扫描 Loader 条目 → 组合 `__DSH_BOOT__` 图 → `webserver/index-inject` 行 → desktop-host 经 IPC 交给外壳 → 页面侧 `PZ()` 逐行应用 → `__ModuleLoader__.create({boot:__DSH_BOOT__})`；插件 bundle 由模块系统以 `plugins/??...` 相对 URL 拉取，桌面壳把 `dsh-app://app/<非静态路径>` 转发给 Host 的 `/plugins` | 确认（源码+真机实验） |
| B2 启动图行如何注入 | `ctx.webServer.collectIndexInjections()`（client-modules 订阅 `webserver/index-inject` 推入 queue script + 预加载 + bootstrap script-src + `__DSH_BOOT__` global）→ `process.send({type:"ready",url,injections})` → main 进程缓存 → `DESKTOP_IPC.boot` 返回 → preload 暴露 `dshDesktopBoot.ready()` → 前端 `PZ(injections)` 应用并 resolve `__DSH_BOOT_READY__` | 确认 |
| B3 备选 | 若不用 `dsh.client`：Host 半边用 `webserver/index-inject` 推内联 `script` 行 + 自注册静态资源路由（真实在用的 `dsh-whale-widget` 即此方案）。注意**不要用 `script-src` 行**：页面解释器会 await 且失败会 reject `__DSH_BOOT_READY__` → 应用起不来 | 确认 |

---

## 1. 方法与验证环境

- 解析工具：`%USERPROFILE%\AppData\Local\Temp\asarx.js`，Node 用 DSH 自带 runtime（`%USERPROFILE%\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe`）。
- 关键文件（均位于 `app.asar!/dsh/node_modules/@deepseek-ai/` 下）：`dsh-app-boot/lib/index.js`、`dsh-desktop-host/lib/index.js`、`dsh-client-modules/lib/index.js`、`dsh-client-modules/lib/client.js`、`dsh-host-webserver/lib/index.js`、`dsh-web-frontend/dist/assets/index-CN7NIWNw.js`、`dsh-web-app/cordis.patch.yml`、`dsh-base/cordis.patch.yml`、`dsh-plugin-manager/lib/index.js`；asar 外层 `lib/main.js`、`lib/preload-app.cjs`。
- 真机实验：在 `%TEMP%\dsh-e2e\home`（隔离 `DSH_HOME`）手工复制/构造 profile，用 Electron-as-node 启动**真实 `dsh-desktop-host/lib/index.js`**（与桌面应用同一入口、同一 `loadProfileDirectory`）与真实 `dsh` CLI 路径；用 `curl` 校验 Host 注入行与 `/plugins` 响应，结束后 `taskkill /T /F` 清理。真实 `%USERPROFILE%\.dsh\profiles\desktop` 与真实 `node_modules` 全程只读。
- 真机实验额外发现（对 install.ps1 有直接影响）：Windows PowerShell 5.1 **读取无 BOM 的 .ps1 时按 ANSI 解码**中文字符串（本次实验脚本踩坑）；写 profile `package.json` 必须 UTF-8 **无 BOM**（有 BOM 时 `JSON.parse` 直接失败，见 §2.3）。

---

## 2. A：安装机制

### 2.1 A1 桌面应用启动时如何加载 profile bundle

证据链（自上而下）：

1. 壳计算 profile 路径：`main.js` `resolveDesktopPaths()` → `profile = join(dshHome, "profiles", "desktop")`（`lib/main.js:79-84`）；`activeProject = paths.profile`（`:12048-12051`）。
2. 壳启动 Host 子进程：`new DesktopHostProcess(resources.node, resources.dsh, activeProject, …, primaryRuntime, packageManager…)`（`:12182-12187`），子进程命令为 `Electron.exe --expose-internals <app.asar>/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js <runtimeDir> <projectDir> <primaryRuntime> <pnpm.mjs> <nodeBin>`（`lib/main.js:3793-3811`；`:11896` 定义 pnpm.mjs 路径）；启动前先 `manager.applyRelease()`（`:12310-12315`）。
3. Host 入口：`installAnchor = join(runtimeDir, "node_modules", "@deepseek-ai", "dsh", "package.json")`（`dsh-desktop-host/lib/index.js:223`）→ `loadProfileDirectory("dsh", projectDir, installAnchor)`（`:224`）→ `reportSkippedBundles`（`:225`）→ `runProfile({ profile:"desktop", resolvedProfile:{profile, installAnchor}, … })`（`:226-250`）。
4. `loadProfileDirectory` 解析逻辑（`dsh-app-boot/lib/index.js`）：
   - 读 profile manifest，取 `dsh.profile.bundles`（`:1015-1016`）；
   - 每个包 `resolveBundleDir()`：**先 installAnchor、再 profile/package.json**，用 `createRequire(anchor).resolve.paths(name)` 做 Node node_modules 查找，`existsSync(join(candidate,"package.json"))` 判定（junction/符号链接会被跟随）（`:995-1001`、`:976-981`）；
   - 读包 `package.json` 的 `dsh.bundle`，做版本兼容检查，`bundlePatchPaths()` 得到 patch 绝对路径并加载（`:1020-1034`；`bundlePatchFiles/bundlePatchPaths` `:500-531`）；
   - 任何单包错误只进 `skippedBundles`，不中断（`:1035-1040`）；再读 profile 自己的 `cordis.patch.yml` 用户层（`:1041-1042`）。用户层/根配置错误才会抛。
5. 运行时解析表（只读、不写盘）：`runProfile` → `composeProfile` 里 `createRuntimeResolution({installAnchor, profile})`（`dsh/lib/profile-boot-C14i-8IN.js:236-247`；`dsh-app-boot/lib/index.js:766-799`），随后 `hostCtx.plugin(PluginPackages, { resolution })`（`:302-312`，其中 `:306`）。
   - `PluginPackages` 只是 package 元数据查询/解析拦截服务（`dsh-app-boot/lib/index.js:3492-3556`），**不做安装、不写 node_modules**。
   - 注意：`linkedProfileRoots()` 会把 profile/node_modules 下指向 profiles 树/当前 profile 之外的 junction 识别为 “linked root”（`:664-692`），仅用于解析顺序/peer 查询，不改动链接本身。我们的 junction 指向 `%DSH_HOME%\plugins\...`，会走 linked 分支，但插件 host 半边只用 `node:` 内置模块、不 bare-import 运行时包，因此不受影响（实验已验证，见 §2.5）。

### 2.2 A2 启动期是否跑 pnpm / 校验 lockfile

结论：**不会**。

- 启动链只有 `createRuntimeResolution`（纯计算）与 `PluginPackages`（只读服务），`dsh-app-boot` 全文没有 pnpm/child_process 安装逻辑，也没有读取 `pnpm-lock.yaml` 的代码。
- `dsh-plugin-manager` 服务构造只读 `profileContext`、注册 abort（`dsh-plugin-manager/lib/index.js:1604-1624`），其 pnpm 调用仅出现在 `installBundle`/`removeBundle` 内部的 `runPnpm`（`:2033`、`:2152`、定义 `:2204-2217`）；包操作成功后才 `reconcile()` 更新 `dsh.profile.bundles`（`:762`；reconcile 实现 `dsh-app-boot/lib/index.js:1209-1228`）。
- 桌面壳启动只做 `applyRelease()`：`initProfile()`（只在文件缺失时创建）+ `migrateProfileSettings()` + `removeLinkProjections()`（只删除指向 `<profile>/.dsh-module-fallback/node_modules` 的 symlink，pnpm 安装的包与其他链接保留）（`lib/main.js:3591-3597`、`:3436-3445`、`:3410-3426`；`dsh-app-boot/lib/index.js:637-646`）。
- 实验证明：隔离 profile 里 `dependencies` 登记 `file:` 指向本地插件、node_modules 放 junction，**完全不建 `pnpm-lock.yaml`/`node_modules/.modules.yaml`** → 真实 desktop-host 启动成功、插件 `host-ready`（§2.5）。又一组实验：**不登记 dependencies**、仅 junction + bundles → 也启动成功且客户端行进入启动图。
- 反向实验（profile 已有 lockfile 但缺该依赖）：不会在启动时被检查；`pnpm add` 跑过一次的隔离 profile（手工方案 + 后加另一个插件）中，pnpm 打印 `dsh-e2e-plugin is linked to … from …`，保留手工依赖与 bundles 选择，且不把它写进 lockfile——说明手工方案与后续 pnpm 操作可共存（见 §4 风险）。`plugin-manager` README 也说明失败/取消时只恢复 `package.json` 与 `pnpm-lock.yaml` 快照（`dsh-plugin-manager/README.zh.md:104,155-162`）。

### 2.3 A2 续：启动期各类“坏状态”的实际影响（含实测）

| 状态 | 结果 | 证据 |
|---|---|---|
| bundle 列在 `dsh.profile.bundles` 但 node_modules 不可解析 | **跳过**，stderr `dsh: skipping profile bundle …`，应用照常启动（实测 neg2：正常打印 `dsh web:` URL） | `dsh-app-boot/lib/index.js:1035-1040`；`dsh-app-boot/README.zh.md:50` |
| 包可解析但 host 半边 import/apply 抛错（optional row） | 警告，继续启动（`plugins waiting/failed` 列表） | `dsh-app-boot/README.zh.md:96-113`；required 列表 `dsh-app-boot/lib/index.js:4270-4279` |
| profile `package.json` JSON 非法 / **带 UTF-8 BOM** | `readProfileManifest` 抛错 → `loadProfileDirectory` 抛 → Host fatal → 桌面壳报 “启动失败” 对话框 | `dsh-app-boot/lib/index.js:905-915`；`dsh-desktop-host/lib/index.js:353-369`；实测 BOM 时 `JSON.parse` 报 `Unexpected token '﻿'` |
| 包声明了 `dsh.client` 但 `lib/client.js` 不存在 / 声明非法 | **整个应用启动失败**：`client-modules` 构造时聚合为 `ClientPackageCompositionError` → `modules`（required）FAILED → `StartupError`（实测 neg1：`dsh: startup failed: 1 required plugin did not activate … modules (required) … client bundles not found … path: …\lib\client.js`） | `dsh-client-modules/lib/index.js:560-562,830-841,852-932`；`dsh-web-app/cordis.patch.yml:227-228`（`modules` = `@deepseek-ai/dsh-client-modules`）；required 列表 `dsh-app-boot/lib/index.js:4270-4279`；审计 `:4464-4475`；启动入口 `:4507-4541` |
| 插件 host 半边的行 `apply` 同步 throw | 警告，继续 | `dsh-app-boot/README.zh.md:105` |

> 结论：**普通 host 插件失败是隔离的；但“声明了 dsh.client 而 client bundle 缺失/声明非法”会把 required 条目 `modules` 拖死，等于让桌面应用起不来**。install/uninstall 必须保证这种情况永不出现（见 §2.6 硬化项）。

### 2.4 A3 最低加载条件与依赖/lockfile 的关系

最低条件（实验矩阵，全部在隔离 `DSH_HOME` 下用真实 desktop-host 入口启动）：

| 条件 | 是否必需 | 实验/证据 |
|---|---|---|
| `profile/node_modules/<name>` 可解析（junction 或实目录） | **必需** | `resolveBundleDir` installAnchor→profile 解析；junction 实验通过 |
| `profile/package.json` 的 `dsh.profile.bundles` 含该名 | **必需** | `loadProfileDirectory` 只遍历 bundles 列表；`dsh-app-boot/lib/index.js:1016-1020` |
| 包 `package.json` 的 `dsh.bundle.patch` 指向存在的 patch 文件 | **必需** | `:1022-1028`、`:500-531`；patch 里行 `name` 从 profile 目录可解析（Loader baseUrl=profile 目录） |
| `dependencies["<name>"]` 登记 | **加载不需要**（建议登记） | 实验 testprof3：仅 junction+bundles，无 dependencies，启动成功且 boot 图含插件行；但若无此登记，插件管理器 UI/后续 pnpm 生命周期不会把它当已安装依赖 |
| `pnpm install` | **不需要** | 手工方案未跑 pnpm，启动成功 |
| `pnpm-lock.yaml` / `node_modules/.modules.yaml` 一致 | **不需要** | testprof 无 lockfile/.modules.yaml 也能启动并加载 |
| `dsh.client` 半边（可选） | 需要时：`dsh.client.platform==="web"` + `exports["./client"]` + **已构建 client.js 存在** | `dsh-client-modules/lib/index.js:62-76,172-182,720-750`；缺失即 §2.3 致命 |
| 包版本兼容（`engines.dsh` / `@deepseek-ai/dsh*` peer） | 有声明就必须匹配 0.2.1-rc.2 | `dsh-app-boot/lib/index.js:1025-1026`；`dsh-app-boot/README.zh.md:52`；本插件无声明，不触发 |

**插件包 `package.json` 必须是合法 JSON 且无 BOM**（`dsh.client` 扫描与 bundle 读取都用 `JSON.parse`）：有 BOM 时通常表现为“bundle 被跳过”（不致命）或 client 扫描异常；profile `package.json` 有 BOM 则致命。

**官方等价路径（桌面自带 CLI）**：公开 CLI `dsh`（`dsh/lib/bin.js`）对 `--profile desktop` 会 `program.error("profile \"desktop\" is managed exclusively by the Electron application")`（`dsh/lib/bin.js:35-37`，boot 与 plugin 两处 `:112,119`）。但桌面安装自带 `resources\runtime\cli\bin\dsh.cmd`，它调用 `dsh-desktop-host/lib/cli.js` → `runCli({ manageDesktopProfile: true, packageManager: { command: Electron.exe, args:["--expose-internals", <supportDir>/primary-runtime/dependencies/pnpm/bin/pnpm.mjs], env:{ELECTRON_RUN_AS_NODE:1, DSH_DESKTOP_NODE_EXECUTABLE, PATH:<supportDir>/bin;…} } })`（`dsh-desktop-host/lib/cli.js:94-116`；`dsh/lib/bin.js:98,119-120`）。因此：

```
<app>\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop add    "file:<PLUGIN_DIR 正斜杠路径>"
<app>\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop remove dsh-open-in-folder
```

隔离环境实测（DSH_HOME=临时目录）结果：
- `add file:…` 成功（实测耗时 <1s，pnpm 输出 `reused 1, downloaded 0`；未做断网验证，但仅涉及本地目录，不下载包），随后：
  - `package.json`：`dependencies["dsh-e2e-plugin"] = "file:C:/…"`，`dsh.profile.bundles` **自动追加**（reconcile）；
  - `pnpm-lock.yaml`：importer `specifier: file:C:/…`、`version: file:../../../…`，并新增 `packages/snapshots` 条目；
  - `node_modules/<name>`：hoisted 模式下是**硬链接实目录**（非 junction）；
  - `node_modules/.modules.yaml` 等 pnpm 元数据生成；
- 重复 `add` 幂等（`Already up to date`，exit 0，不重复追加 bundles）；`remove` 会删除依赖、bundles 项、node_modules 目录与 lockfile 条目（实测 exit 0，importer 清空）。
- 注意：因为 `node_modules` 里是**硬链接副本**，更新插件源码后重新 `add` 可能 `Already up to date`，需要 `remove` 再 `add`（或重建）。

### 2.5 真机实验证据（隔离 DSH_HOME，真实 desktop-host 入口）

- 实验 A（手工方案 + 真实插件）：临时 profile `...\home3\profiles\desktop\package.json`：`dependencies` 登记 `file:`，`bundles=[@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app, dsh-open-in-folder]`，`node_modules\dsh-open-in-folder` 为 **junction → `<仓库目录>\plugin`**；无 `pnpm-lock.yaml`/`.modules.yaml`。启动 `dsh-desktop-host/lib/index.js` 后：
  - stdout `dsh web: http://127.0.0.1:3420/?token=…`（启动成功）；
  - `GET /dsh-open-in-folder/health` → `{"ok":true,"pid":7768,"version":"0.1.0"}`；`GET /dsh-open-in-folder/pending` → `{"ok":true,"items":[]}`（Host 路由工作）；
  - 临时 `DSH_HOME\open-in-folder\state.json` 与 `events.log`（`host-ready`）正常写出；
  - index HTML 中启动图行：`{"id":"dsh-open-in-folder","url":"plugins/??dsh-open-in-folder/client.js&rev=98016d852c69","rev":"98016d852c69","inject":["@deepseek-ai/dsh-api-workspace-controller","@deepseek-ai/dsh-client-ui-workspace"]}`（client 半边已进入 `__DSH_BOOT__`）。
- 实验 B（普通样例插件，验证 `/plugins` 实际响应）：启动图中 `{"id":"dsh-e2e-plugin","url":"plugins/??dsh-e2e-plugin/client.js&rev=…"}`；`GET http://127.0.0.1:<port>/plugins/??dsh-e2e-plugin/client.js&rev=…` 返回 335 字节、内容为
  `window.__ModuleLoader__.load({ id: 'dsh-e2e-plugin', factory: (require) => { … } })`，与本地 `lib/client.js` 一致。
- 实验 C（失败隔离）：bundle 不可解析 → 仅 stderr `skipping profile bundle`，应用正常；`dsh.client` 声明但删掉 `lib/client.js` → 启动失败（见 §2.3 表）。

### 2.6 A4 推荐安装方案（给 install.ps1）

**主推荐：保持“手动文件安装”，不跑 pnpm。** 当前 `install.ps1` 的顺序（复制插件 → 建 junction → 改 profile package.json，`install.ps1` 步骤 2/5/6）是对的：所有前置动作完成后才写 manifest，窗口期内 HMR 不会看到不完整插件。理由：
1. 启动完全不需要 pnpm/lockfile（§2.2/§2.4 实验），手动方案可 100% 离线；
2. 不改 `node_modules` 其余部分、不动 `pnpm-lock.yaml`/`.modules.yaml` → 回滚最简单（恢复一个备份 JSON + 删 junction）；
3. 与后续 plugin-manager 的 pnpm 操作兼容（实测 pnpm 保留手工 link 并打印 notice，不剪除）。

必须加的硬化项（按优先级）：

1. **client.js 存在性/合法性校验（最高优先级，否则会 brick 应用）**：解析插件 `package.json`；若 `dsh.client !== undefined`，则要求
   - `dsh.client.platform === "web"`、`dsh.client.inject`/`external` 若存在必须是字符串数组；
   - `exports["./client"]` 存在且其指向文件（如 `lib/client.js`）存在、可读、非空；
   - 建议用 DSH 自带 Node 做语法检查：`& "$app\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" --check "<PLUGIN_DIR>\lib\client.js"`（host 半边 `lib/index.js` 同理），失败→在产生任何副作用前终止。
2. **BOM 校验与无 BOM 写回**：写 profile `package.json` 用 `[IO.File]::WriteAllText(path, text, New-Object Text.UTF8Encoding($false))`（当前 `install.ps1:438-440` 已如此）；同时校验插件与 profile 现有 JSON 首字节无 BOM，`JSON.parse` 语义验证（PS `ConvertFrom-Json` 容错，不能只信它）。
3. **DSH 运行中处理**：桌面 profile 的 `hmr` 行在 `profileContext` 存在时启用（`dsh-base/cordis.patch.yml:27-32`；`dsh-desktop-host/lib/index.js:224` 传 profileContext），运行中改 `package.json` 会触发 live recompose。建议检测目标 exe 的进程（按 `$appPath` 全路径匹配）→ 默认中止并提示“先完全退出 DSH（含托盘）”；`-Force` 时才继续。注意即使继续，也要保证 client.js 校验在最前、manifest 最后写。
4. **幂等/回滚**：junction 已存在时验证 target 等于 `PLUGIN_DIR`（不同则重建）；`package.json.bak-open-in-folder` 只首次备份（现状），中途失败应恢复备份 + 删除本次新建 junction（当前 `Set-PluginJunction` 把普通目录 move 成 `.bak-<ts>`，但后续失败没有恢复逻辑，建议加 try/finally 回滚）。
5. **uninstall 顺序风险**：当前 `uninstall.ps1` 顺序为 删注册表 → 删 junction → **从 `.bak-open-in-folder` 整体恢复 package.json** → 删插件目录。若用户在安装后通过 UI 又装了别的插件，整体恢复会丢掉后来的依赖/bundles 变更。建议优先“外科手术式”移除本插件条目，仅当 `package.json` 损坏时才用备份恢复；并保证“先移除 bundle 项（可容忍缺包）→ 再删文件”，避免留下“包可加载但 client.js 被删”的致命组合（若先删 junction 则不会致命，现状可接受）。
6. **升级插件**：junction 指向 `PLUGIN_DIR`，重跑 install.ps1 覆盖目录即可；DSH 运行中不会热更 host 代码，需重启。若改用 CLI 方案则需 `remove` 再 `add`。

**备选/修复手段：桌面自带 CLI**（§2.4）。适用场景：用户希望 profile 状态被 pnpm 完全接管、或手动安装后要修复/卸载。注意：① 运行前应完全退出 DSH（避免 Windows 文件锁与并发 HMR）；② 会复制/硬链接一份插件进 `node_modules`（与 `PLUGIN_DIR` 可能分叉）；③ 失败时 plugin-manager 恢复 `package.json`+`pnpm-lock.yaml` 快照（`dsh-plugin-manager/README.zh.md:104,155-162`），但已下载文件可能残留；④ 不要与手动 junction 方案混用同一次安装（CLI 会把 junction 替换成自己的实目录）。

**不要做**：不要手工编辑 `pnpm-lock.yaml`/`.modules.yaml`（启动不读，收益为零、格式易错）；不需要 `pnpm install`（若坚持要“让 lockfile 一致”，可离线用 `node <runtime>\…\pnpm.mjs install --lockfile-only`，但本次未验证，不作为推荐）。

**最坏情况恢复**：
1. 应用启动失败时，桌面壳 fatal 对话框有第三个按钮“禁用第三方插件”（`lib/main.js:8353-8362`）→ 执行 `DesktopProjectManager.disableAllPlugins()`（`:3585-3586`）→ `sanitizeProfile("dsh", profileDir, [@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app])`：把 `cordis.patch.yml` 备份为 `.bak-<ts>`，把 bundles 重置为 base+web-app（`lib/main.js:3531-3546`；`dsh-app-boot/lib/index.js` 同名实现 `:1242-1257`），然后重启。
2. 手动：恢复 `profile\package.json.bak-open-in-folder` → 删除 `profile\node_modules\dsh-open-in-folder`（junction）→ 删除 `%DSH_HOME%\plugins\dsh-open-in-folder`。手动方案未改 lockfile，无需清理 pnpm 状态。
3. 若 profile `package.json` 本身损坏（如被写成 BOM/半截文件）：直接恢复备份并确认 UTF-8 无 BOM；必要时把整个 profile 目录改名（下次启动 `createPluginProfile` 会重建 `package.json`/`cordis.patch.yml`/`pnpm-workspace.yaml`，`lib/main.js:3636-3638`、`:3410-3426`），但会丢失 bundle 选择。

---

## 3. B：客户端插件加载（桌面壳）

### 3.1 B1 第三方 `dsh.client` 包会不会被加载：会。完整链路

**Host 侧组合（client-modules 的 Node 半）**

1. 服务 `ClientModuleRegistry`（service 名 `clientModules`）在构造时：
   - 订阅 `internal/plugin` → 增量扫描 `ctx.loader.entries()`（`dsh-client-modules/lib/index.js:545-558,852-892`）；
   - 对每个活动 Loader 条目：`locatePkgJson()` 用 Loader 的 `internal.resolveSync` 解析出包目录/package.json（`:762-809`），读 `dsh.client`（`parseDshClient` 校验 platform/inject/external/immediately，`:62-76`），**只接受 `platform === "web"`**（`:720-750`），再用 `exports["./client"]` 求 client 文件路径（`:172-182`），读取文件并记录 revision；文件缺失→`MissingClientBundleError`→ 聚合抛错（`:830-841,560-562`）。
   - 组合启动图：按模块图排序后分 `bootstrap`（仅 `@deepseek-ai/dsh-client-modules` 自己）与 `application` 批次，生成 combo URL `/plugins/??<id>/client.js,…&rev=<rev>`（`:667-712,202-219`）。
   - 启动图行结构：`{id, url: (无前导 / 的文档相对形式), rev, inject, immediately, external}`（`:402-410,217-219`）。
2. 注册资源路由：`ctx.inject(["webServer"], …)` → `webServer.register({kind:"prefix", path:"/plugins", handler: serveBundle})`（`:563-569`；路由常量 `:202`；`serveBundle/bundleResource` `:977-997`；`fetchBundle()` 供 shell 载体的等价入口 `:598-605`）；同时订阅 `webserver/index-inject`，把启动行推进注入表（`:571-573`）。
3. 注入行内容 `bootInjections(graph)`（`:450-505`）：内联 queue facade（`window.__ModuleLoader__` 排队模式）→ application 批次的 `<link rel=preload as=script>` → bootstrap 批次的 `<script src>` → `global __DSH_BOOT__ = graph`。
   - 页面装载内核：`window.__ModuleLoader__.create({boot, staticModules})` 物化 bootstrap，再把 facade 切到 live registration（README `dsh-client-modules/README.zh.md:69,85`）。
   - 插件 bundle 的加载：`ClientModuleSystem` 对每个图行用 **默认 `loadBundle`**：`document.createElement("script")`、`el.src = row.url`（文档相对 URL）、append 到 head（`dsh-client-modules/lib/client.js:581-594`）；`dsh.client.inject` 只影响“先让其提供方行 arrive”（`:776-794`），即图顺序，不是 Cordis 服务注入（服务注入来自插件导出 `inject`）。

**桌面壳侧（把 Host 的行送到页面、并把 `/plugins` 请求转回 Host）**

4. 外壳的页面是 `dsh-app://app/`（custom scheme 注册为 standard/secure/fetch/CORS/stream/codeCache，`lib/main.js:11880-11890`）。Host 把 `ready.injections` 经 IPC 交给外壳：`process.send({type:"ready", url, injections: ctx.webServer.collectIndexInjections()})`（`dsh-desktop-host/lib/index.js:342-349`）；外壳 child `message` 处理 `ready` 时缓存 `injections`（`lib/main.js:3824-3827,12193-12194`）。
5. 页面装载：`protocol.handle("dsh-app")` 对 `/`、`/index.html`、`/assets/*`、favicon、manifest **直接从 `app.asar/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist` 读盘返回**（`lib/main.js:12406-12410`），其余路径 `forwardWebRequest(request, hostUrl, hostCookie)` 转发给 Host（`:12411-12412`）；`/plugins/*` 额外把 `cache-control` 改为 `no-store`（`PLUGIN_BUNDLE_PATH = /^\/plugins\//`，`:8257,8294`）。转发时剥掉 `host/origin/cookie/sec-fetch-site` 再补 Host 的认证 cookie（`:8275-8282`）。
6. index HTML 注入：外壳在返回的 index.html `<head>` 里注入 `globalThis.__DSH_BOOT_READY__ = Promise.withResolvers()`（`lib/main.js:8221`）；随后 `DESKTOP_IPC.boot` handler 返回 `{ injections, streamBaseUrl }`（`:12424-12432`），preload 暴露 `window.dshDesktopBoot = { ready: () => ipcRenderer.invoke("dsh-desktop:boot"), failed: … }`（`lib/preload-app.cjs:863-866`）。
7. 前端 boot（`dsh-web-frontend/dist/assets/index-CN7NIWNw.js`，单行压缩，约 char 918,500–921,071 的文件尾）：
   - `const Ms = globalThis.dshDesktopBoot`；若存在，则 `Ms.ready().then(({injections, streamBaseUrl}) => { __DSH_TRANSPORT__ = {ownsHost:true, streamBaseUrl}; await PZ(injections, src => loadScript(src)); __DSH_BOOT_READY__.resolve() })`；
   - 然后 `new TZ(root)` 的 `run()`：`await __DSH_BOOT_READY__.promise` → 取 `window.__ModuleLoader__` → `create({boot: globalThis.__DSH_BOOT__, staticModules, …})`。
   - `PZ` 对各 kind 的处理：`global → globalThis[name]=value`；`script → createElement+textContent+append`（无 await，不会失败）；`script-src → await loadScript(src)`（失败会 reject 整个 boot）；`script-preload → 忽略`；`style/html` 追加。
8. 因此：桌面页面里 `__DSH_BOOT__` 包含第三方插件行 → 模块系统用相对 URL `plugins/??<id>/client.js&rev=…` 建 `<script>` → 解析为 `dsh-app://app/plugins/…` → 外壳转发到 Host `/plugins` → client-modules 返回该 bundle → `window.__ModuleLoader__.load({id, factory})` 注册 → 按图/依赖物化。**第三方 `dsh.client` 包在桌面应用可正常加载。**

补充：`dsh.client.external` 用于声明“基座表之外的模块请求”，基座表为前端硬编码的 `staticModules`（react、react-dom、cordis、zod、tanstack virtual、dsh-client-store、ui-slots、ui-primitives、dockkit 等，见前端 `SZ()` 定义）；`<id>/client` 与裸 id 等价（`stripClientSuffix`，`dsh-client-modules/lib/index.js:99-101`）。

### 3.2 B2 `/plugins` 转发与启动图注入：证据小结

- `/plugins` 的 Host 路由：`dsh-client-modules/lib/index.js:202,563-569,977-997`；`fetchBundle()`（`:598-605`）是“shell 自有载体”的替代入口，但**桌面壳走的是 webServer 路由 + HTTP 转发**（`main.js` 中无 `fetchBundle` 调用）。
- 外壳转发：`lib/main.js:8257,8268-8298,12406-12415`。
- 注入行收集：`dsh-host-webserver/lib/index.js:522-526`（`collectIndexInjections()` 每次 emit 现取）；渲染进 index 的版本见 `:29-98,533-535`（Web 模式用），桌面模式走 IPC（第 4-7 步）。
- `__DSH_BOOT_READY__` 的“宿主持有/页面解释”双通道设计与实现：`dsh-host-webserver/lib/index.js:62-70,79-98`；桌面壳注入 deferred 见 `lib/main.js:8221`。

**真机实验**（§2.5 实验 A/B 同一次记录）：
- 真实 `dsh-desktop-host/lib/index.js`（桌面应用同一入口）在隔离 `DSH_HOME` 启动后，其 `webServer` 渲染的 index 注入表中包含 application combo（含 `dsh-open-in-folder/client.js`）与 `globalThis["__DSH_BOOT__"]` 行；图行含 `inject:["@deepseek-ai/dsh-api-workspace-controller","@deepseek-ai/dsh-client-ui-workspace"]`；
- 对 `/plugins/??<id>/client.js&rev=…` 的 HTTP GET 返回的正是插件 `lib/client.js` 原文（含 `window.__ModuleLoader__.load`），说明 Host 组合与路由正常。
- 结论：从 Host 行到桌面壳页面解释器的每一步都有源码证据，且“行内容/路由响应”已在真实入口实测；唯一未做的是真实 Electron 窗口内目视验证（本机 DSH 运行中，禁止重启）。

### 3.3 B3 若不想用 dsh.client：可行替代（已有真实先例）

真实第三方插件 `%DSH_HOME%\profiles\desktop\node_modules\dsh-whale-widget`（已在用）就是“Host 半边 + 结构化注入行”方案，可直接作为参考：
- 桌面壳 index.html 从安装包静态 dist 直出，`tapIndex()`（字符串变换）**永远不生效**；唯一通道是 `webserver/index-inject` 的结构化行（`dsh-whale-widget/lib/index.js:706-721,725-746,4903-4917`）。
- 它推的是 `{kind:"script", placement:"body", text:"...创建<script src=/dsh-whale/widget.js>并吞掉 onerror..."}` 内联行，并由 Host 半边注册 `/dsh-whale/widget.js` 等路由（`:4891-4908`）。
- 重要提醒：**不要用 `script-src` 行**——页面解释器会 `await loadScript`，加载失败会 reject `__DSH_BOOT_READY__` 导致应用起不来（`:709-717`）；并且注入表是**宿主启动时一次性收集**，运行期新增/关闭插件后表不会刷新（`:713-715,725-730`）。
- 对本项目：若只想“页面里跑一段轮询脚本”，B3 方案更简单（不需要 `dsh.client`/factory 格式/`exports["./client"]`），但需要自行处理脚本路由与失败静默；若想走官方模块系统（推荐，便于 UI/生命周期），用 `dsh.client`（当前 Lead 的实现）。

### 3.4 客户端 API 核对（针对当前 `plugin/lib/client.js`）

- `dsh.client.inject` 值必须是**启动图里的 package id**：`["@deepseek-ai/dsh-api-workspace-controller","@deepseek-ai/dsh-client-ui-workspace"]` 正确（client-modules 用 `graphRows.get(packageName)` 做先行 arrive，`dsh-client-modules/lib/client.js:789-792`）。
- 客户端插件导出 `inject = ["workspaces","uiWorkspace"]`（Cordis 服务名）与宿主匹配：
  - `workspaces` 服务：`dsh-api-workspace-controller/lib/client.js:381-397`（`super(ctx,"workspaces")`；`create(input)` 失败抛错、成功返回 `result.value.workspace`）；
  - `uiWorkspace` 服务：`dsh-client-ui-workspace/lib/client.js:1360-1380`（`super(ctx,"uiWorkspace")`），`openWorkspace(workspaceId)` 存在（`:1473-1490`）；
  - `workspaces.create({path})` 的 `path` 字段与返回的 `workspaceId`：Host 侧 `workspaceView` 返回 `{workspaceId, path, …}`（`dsh-api-workspace-controller/lib/index.js:17-26`），`create(request)` 读取 `request.path`（`:207-226`）。
- 页面内 `fetch('/dsh-open-in-folder/…')` 在桌面壳可用：相对 URL → `dsh-app://app/dsh-open-in-folder/…` → 外壳转发（`main.js:12406-12415`）；插件 `pageRequestTrusted()` 的检查（Host 头必须回环、拒绝 `sec-fetch-site: cross-site`、有 Origin 则必须同源）在桌面壳转发场景下满足（外壳剥掉 Origin/sec-fetch-site，Host 由 fetch 设为 `127.0.0.1:<port>`），源码见 `plugin/lib/index.js:146-181`；这也与 whale-widget 在桌面端用 fetch 访问自注册路由的成功实践一致。

---

## 4. 剩余风险

1. **致命性风险（最高）**：插件一旦声明 `dsh.client`，任何“bundle 可加载但 client.js 缺失/损坏/`dsh.client` 字段非法”的状态都会使 `modules`（required）失败 → 桌面应用无法启动（实测）。因此 install/uninstall 必须把“client.js 存在 + 插件 package.json 合法”作为硬前置，并保证卸载时先移除 bundle 选择再删除文件（或直接删 junction，让包不可解析→跳过）。DSH 升级后 client 机制若变化，同样可能以启动失败呈现；建议在 README 标明目标版本 0.2.1-rc.2 并提示升级后先验证。
2. **真实 GUI 未目视验证**：本机 DSH 运行中不可重启，故“Electron 窗口内 client 插件实际运行、工作区打开”只用等价链路（desktop-host 启动 + 注入行/路由实测）验证；建议 verifier 在可控重启后做一次端到端：退出 DSH → 安装 → 启动 → 观察 `state.json`/health、`pending` 客户端轮询（Host `events.log` 出现 `pending-claimed`、`ack`）→ 右键打开文件夹 → 卸载。Lead 已用隔离环境验证“web UI 里客户端半边能打开工作区”，与本文结论一致。
3. **HMR 与“运行中安装”**：桌面 profile 的 `hmr` 在 `profileContext` 存在时启用（`dsh-base/cordis.patch.yml:27-32`），install.ps1 在 DSH 运行时改 `package.json` 会触发 live recompose（本次实验的 desktop-host 启动也启用了 HMR）。虽然 live 失败通常只警告、不终止运行中的应用，但为了让下一次启动处于确定状态，建议 install.ps1 默认要求 DSH 已退出。
4. **UTF-8/JSON 纪律**：profile `package.json` 带 BOM 或非法 JSON = 应用启动失败；插件 `package.json` 带 BOM = 插件被跳过（stderr 警告，不致命）。PowerShell 5.1 写/读非 ASCII 还需注意脚本本身 BOM 与 `UTF8Encoding($false)`。
5. **手工方案与 pnpm 的一致性**：启动不需要 lockfile 一致（已证），pnpm `add/remove` 也会保留手工 link（实测打印 `… is linked to … from …`，不改写 lockfile 条目）。但这是 pnpm 的“容忍”行为而非契约；DSH 升级携带的新 pnpm 版本若改变该行为，可能在用户用插件管理器装/卸其他插件时清掉 junction 或产生 lockfile 差异。缓解：document “重跑 install.ps1 可修复”；或改用桌面 CLI 方案让 pnpm 全权接管。
6. **uninstall 的整体恢复风险**：`package.json.bak-open-in-folder` 是首次安装快照；若安装后用户又通过 UI 装了其他插件，直接恢复备份会回退后来的依赖/bundles 变更（文件仍在，仅选择丢失，非致命）。建议改为优先精确删除本插件条目。
7. **客户端功能的软失败**：`exports.inject=["workspaces","uiWorkspace"]` 若未来 DSH 改名/移除服务，客户端插件会永久等待、静默不工作（host 半边与 launcher 仍正常，health 仍可用）。建议在 client `apply` 里加一次性 `console.warn` 超时提示，便于排障（可选）。
8. **插件升级/缓存**：桌面壳对 `/plugins` 设 `no-store`，无缓存问题；但 host 代码升级必须重启 DSH（manifest 未变时 HMR 不重载模块）。CLI 方案因硬链接副本存在，升级需 `remove`+`add`。

---

## 5. 对 Lead 的建议（决策项）

1. **安装方案**：保留 `install.ps1` 的手动方案（复制 + junction + 安全改 JSON），**不需要 pnpm install、不要改 lockfile**；补 §2.6 的 6 个硬化项（其中 client.js 校验与 DSH 运行检测为必做）。
2. **官方等价路径**作为文档化备选/修复手段：`<app>\resources\runtime\cli\bin\dsh.cmd plugin --profile desktop add|remove …`（`manageDesktopProfile:true` 的桌面自带 CLI，隔离环境实测可用、幂等、自动维护 deps+bundles+lockfile）；不要与手动 junction 混用。
3. **客户端方案**：当前 `dsh.client` 双半边实现是正确且被支持的（桌面壳会加载）；但要严守 §4.1 的致命组合，并在 verifier 阶段做一次受控重启后的端到端验证。若想降低风险，可再把“页面注入一段轮询脚本”的 B3 方案作为 fallback 设计（host 半边已有 HTTP 路由，两种半边可共存，但只需选一种）。

---

## 附录：复现实验命令（隔离环境，勿在真实 profile 上执行）

```powershell
# 0) 变量
$res = "<DSH 安装目录>\resources"; $exe = "<DSH 安装目录>\DeepSeek Harness.exe"
$home = "$env:TEMP\dsh-e2e\home"; $prof = "$home\profiles\desktop"
$plugin = "<仓库目录>\plugin"
# 1) 构造 profile（UTF-8 无 BOM！）+ junction
[IO.File]::WriteAllText("$prof\package.json", $json, (New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Junction -Path "$prof\node_modules\dsh-open-in-folder" -Target $plugin | Out-Null
# 2) 用真实 desktop-host 入口启动（等价桌面应用 Host 进程）
$env:DSH_HOME=$home; $env:ELECTRON_RUN_AS_NODE="1"; $env:DSH_CLIENT_VERSION="0.2.1-rc.2"
& $exe --expose-internals "$res\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\index.js" `
  "$res\app.asar\dsh" "$prof" "$res\runtime\primary-runtime" `
  "$res\runtime\primary-runtime\dependencies\pnpm\bin\pnpm.mjs" "$res\runtime\bin"
# 3) 校验（启动日志出现 dsh web: http://127.0.0.1:<port>/?token=…）
curl.exe -s "http://127.0.0.1:<port>/dsh-open-in-folder/health"
# 4) 官方 CLI（备选方案）在隔离 DSH_HOME 的实验
$env:DSH_HOME=$home
& "$res\runtime\cli\bin\dsh.cmd" plugin --profile desktop add "file:$($plugin.Replace('\','/'))"
& "$res\runtime\cli\bin\dsh.cmd" plugin --profile desktop remove dsh-open-in-folder
```

> 说明：桌面壳 `dsh-app://` 页面自身无法用普通浏览器打开（依赖 preload/IPC），故 GUI 内验证需在真实窗口中做；上表的 `/plugins`、index 注入行已用 Host 的 HTTP 端点实测等价。
