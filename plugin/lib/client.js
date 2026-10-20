/**
 * dsh-open-in-folder —— 客户端半边（浏览器 bundle）
 *
 * DSH 的客户端模块系统会按 package.json 的 `dsh.client` 声明加载本文件：
 * 文件执行时只向 window.__ModuleLoader__ 注册 factory（惰性），真正物化时
 * 才运行 factory 并返回插件导出（name/inject/apply）。
 *
 * 职责（配合 Host 半边的 HTTP 路由，见 ../lib/index.js）：
 *   1. 每 ~1 秒 GET /dsh-open-in-folder/pending 领取「待打开文件夹」；
 *   2. 调用 DSH 客户端公开服务：
 *        ctx.get('workspaces').create({ path })      —— 登记/复用工作区
 *        ctx.get('uiWorkspace').openWorkspace(id)    —— 打开该工作区的空白新会话
 *   3. POST /dsh-open-in-folder/ack 回传结果（Host 写 events.log 便于排障）。
 *
 * 不 import 任何模块：所有能力都从 Cordis 客户端服务的 inject 取得，因此
 * 不需要 dsh.client.external，也不会与宿主版本产生模块表耦合。
 */
window.__ModuleLoader__.load({
  id: 'dsh-open-in-folder',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    /** 与 Host 半边约定的路由前缀。 */
    var ROUTE_BASE = '/dsh-open-in-folder'
    /** 轮询间隔。 */
    var POLL_MS = 1000
    /** 已处理过的 requestId，防止同一请求被重复打开（最多记 200 条）。 */
    var seenIds = []
    var seenSet = Object.create(null)

    function remember(id) {
      if (seenSet[id] === true) return false
      seenSet[id] = true
      seenIds.push(id)
      if (seenIds.length > 200) {
        var old = seenIds.shift()
        delete seenSet[old]
      }
      return true
    }

    /** Host 半边只写 events.log；失败不影响打开流程。 */
    function acknowledge(payload) {
      try {
        fetch(ROUTE_BASE + '/ack', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(payload)
        }).catch(function () {})
      } catch (error) {
        /* ignore */
      }
    }

    /**
     * 打开一条请求：登记工作区 → 打开工作区空白会话 → ack。
     * @param ctx - 客户端根 Context（已 inject workspaces / uiWorkspace）。
     * @param item - { id, path, createdAt }
     */
    async function openFolder(ctx, item) {
      var workspaces = ctx.get('workspaces')
      var uiWorkspace = ctx.get('uiWorkspace')
      if (!workspaces || typeof workspaces.create !== 'function' || !uiWorkspace || typeof uiWorkspace.openWorkspace !== 'function') {
        acknowledge({
          id: item.id,
          stage: 'unavailable',
          message: 'workspaces/uiWorkspace service is unavailable'
        })
        return
      }
      try {
        var workspace = await workspaces.create({ path: item.path })
        if (!workspace || typeof workspace.workspaceId !== 'string') {
          acknowledge({ id: item.id, stage: 'error', message: 'workspaces.create returned no workspace' })
          return
        }
        await uiWorkspace.openWorkspace(workspace.workspaceId)
        acknowledge({ id: item.id, stage: 'opened', workspaceId: workspace.workspaceId, message: item.path })
      } catch (error) {
        var message = String((error && error.message) || error)
        try {
          console.warn('[dsh-open-in-folder] open failed:', item.path, error)
        } catch (ignored) {}
        acknowledge({ id: item.id, stage: 'error', message: message })
      }
    }

    /** 领一轮队列。Host 未就绪 / 页面尚未连上时静默失败，下一轮再试。 */
    async function pollOnce(ctx) {
      var response
      try {
        response = await fetch(ROUTE_BASE + '/pending', { cache: 'no-store' })
      } catch (error) {
        return
      }
      if (!response || !response.ok) return
      var body
      try {
        body = await response.json()
      } catch (error) {
        return
      }
      var items = body && Array.isArray(body.items) ? body.items : []
      for (var index = 0; index < items.length; index += 1) {
        var item = items[index]
        if (!item || typeof item.id !== 'string' || typeof item.path !== 'string') continue
        if (!remember(item.id)) continue
        await openFolder(ctx, item)
      }
    }

    /** 客户端插件导出：Cordis 会等待这两个服务就绪后才调用 apply。 */
    exports.name = 'open-in-folder-client'
    exports.inject = ['workspaces', 'uiWorkspace']

    /**
     * @param ctx - 客户端根 Context。
     */
    exports.apply = function apply(ctx) {
      var stopped = false
      var timer = null
      var running = false

      async function tick() {
        if (stopped || running) return
        running = true
        try {
          await pollOnce(ctx)
        } finally {
          running = false
        }
      }

      ctx.effect(function () {
        timer = setInterval(function () {
          tick()
        }, POLL_MS)
        // 插件激活后立刻探一次，不必等第一个间隔。
        tick()
        return function () {
          stopped = true
          if (timer !== null) clearInterval(timer)
        }
      }, 'open-in-folder: pending poll')
    }

    return module.exports
  }
})
