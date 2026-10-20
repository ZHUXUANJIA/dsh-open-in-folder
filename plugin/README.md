# dsh-open-in-folder（DSH 插件）

> 让 Windows 资源管理器右键菜单里的「在 DeepSeek Harness 中打开」把任意文件夹作为
> DSH 工作区打开——ZCode「在 ZCode 中打开」的 DSH 等价功能。

本包是完整的 DSH 插件（Host 半边 + 客户端半边），由仓库根目录的 `install.ps1` 安装；
普通用户请看仓库根目录 [`README.md`](../README.md)，本文件只记录插件自身的实现与排障。

## 目录结构

```
package.json        # dsh.bundle.patch + dsh.client 声明
cordis.patch.yml    # bundle patch：把本插件插入 DSH profile 配置树
lib/index.js        # Host 半边（Node / Cordis host）：HTTP 路由、队列、state.json、events.log
lib/client.js       # 客户端半边（浏览器 bundle，window.__ModuleLoader__ 格式）
```

## 运行时接口（与 launcher 的契约见仓库根 `CONTRACT.md`）

- `GET  /dsh-open-in-folder/health`   启动器探测 Host 是否就绪
- `POST /dsh-open-in-folder/request`  启动器入队一个待打开文件夹（需 `X-DSH-Open-In-Folder-Token`）
- `GET  /dsh-open-in-folder/pending`  页面内客户端领取队列
- `POST /dsh-open-in-folder/ack`      客户端回传打开结果

状态文件：`%DSH_HOME%\open-in-folder\state.json`（端口、token、pid）。
事件日志：`%DSH_HOME%\open-in-folder\events.log`（JSON Lines，排障用）。

## 客户端半边做什么

插件激活后每 1 秒轮询一次 `pending`，拿到路径后调用 DSH 客户端公开服务：

```js
const workspace = await ctx.get('workspaces').create({ path })
await ctx.get('uiWorkspace').openWorkspace(workspace.workspaceId)
```

即「登记/复用工作区 → 打开该工作区的空白新会话」，等价于用户手动在侧栏「添加工作区」。
不 import 任何模块，所有能力都从 Cordis 客户端服务按名注入，因此不需要
`dsh.client.external`，也不受宿主版本模块表影响。

## 排障

1. 右键打开没有反应：先看 `%DSH_HOME%\open-in-folder\events.log` 是否有
   `host-ready`（插件是否加载）与 `request-queued`（启动器是否成功 POST）。
2. 有 `request-queued` 但没有 `pending-claimed`：DSH 页面没有加载客户端半边，
   通常是插件装好后没有**完全退出并重新打开** DSH。
3. 有 `ack stage:"error"`：看 `message`，常见是路径不存在或客户端服务未就绪。
4. 想看菜单是否装好：`reg query "HKCU\Software\Classes\Directory\shell\DSH.OpenInFolder"`。
5. 插件完全禁用：把 `%DSH_HOME%\profiles\desktop\package.json` 里
   `dsh.profile.bundles` 的 `dsh-open-in-folder` 删掉（或运行 `uninstall.ps1`）后重启 DSH。

## 安全边界

- HTTP 路由只接受回环 Host；`/request` 还要求 state.json 里的随机 token；
  `/pending`、`/ack` 只允许页面同源/回环请求。
- 能执行右键菜单的本机用户本来就能读写自己的文件，插件不会提升权限。
- token 每次 DSH Host 启动随机生成，写在当前用户目录下的 state.json 里。
