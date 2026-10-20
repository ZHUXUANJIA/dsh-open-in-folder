/**
 * dsh-open-in-folder —— Host 半边（DSH 插件）
 *
 * 目标：让 Windows 资源管理器右键菜单里的「在 DeepSeek Harness 中打开」能把
 * 任意文件夹作为工作区在 DSH 里打开。Host 半边负责：
 *
 *   1. 在 DSH 自带的 web server 上注册本地 HTTP 路由（只监听回环地址）；
 *   2. 把 Host 实际监听端口与本次进程随机 token 原子写入 state.json，
 *      供外部启动器 DSHOpenInFolder.exe 读取；
 *   3. 维护「待打开文件夹」内存队列：外部启动器 POST 入队，页面内客户端
 *      半边轮询领取，领取结果用 ack 回传并写入 events.log。
 *
 * 客户端半边见 ./client.js（浏览器 bundle，调用 DSH 客户端公开服务
 * ctx.workspaces.create / ctx.uiWorkspace.openWorkspace 完成真正的打开动作）。
 *
 * 与外部启动器的接口契约见仓库根目录 CONTRACT.md。
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import crypto from 'node:crypto'
import { ensureShellIntegration } from './shell-integration.js'

/** Cordis function-plugin 名字（在配置树里唯一即可）。 */
export const name = 'open-in-folder'

/** 依赖的 Host 服务：web server 就绪后才 apply。 */
export const inject = ['webServer']

export const apply = applyPlugin
export default { name, inject, apply: applyPlugin }

/** 插件版本（state.json / health 里回报，便于排障；用于外壳集成自动重装判断）。 */
const PLUGIN_VERSION = '0.2.0'
/** 路由前缀。 */
const ROUTE_BASE = '/dsh-open-in-folder'
/** request 请求体上限。 */
const MAX_BODY_BYTES = 64 * 1024
/** 待打开队列上限（防止外部刷爆内存）。 */
const MAX_PENDING = 20
/** 启动器请求头：必须与 state.json 里的 token 一致。 */
const TOKEN_HEADER = 'x-dsh-open-in-folder-token'
/** events.log 单文件上限；超了轮转为 events.log.1。 */
const LOG_MAX_BYTES = 1024 * 1024

/** 解析 DSH_HOME（与 dsh-home-paths 的缺省一致：$DSH_HOME 或 %USERPROFILE%\.dsh）。 */
function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
}

/** 运行时状态目录（测试可用 DSH_OPEN_IN_FOLDER_STATE_DIR 覆盖）。 */
function stateDir() {
  return process.env.DSH_OPEN_IN_FOLDER_STATE_DIR || path.join(dshHome(), 'open-in-folder')
}

/** 事件日志：只追加 JSON Lines，绝不因为写日志失败影响主流程。 */
function log(level, event, details) {
  try {
    const dir = stateDir()
    fs.mkdirSync(dir, { recursive: true })
    const file = path.join(dir, 'events.log')
    try {
      const stat = fs.statSync(file)
      if (stat.size > LOG_MAX_BYTES) {
        try {
          fs.renameSync(file, path.join(dir, 'events.log.1'))
        } catch {
          /* 轮转失败就继续追加 */
        }
      }
    } catch {
      /* 文件不存在：正常情况 */
    }
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      level,
      event,
      ...(details && typeof details === 'object' ? details : {})
    })
    fs.appendFileSync(file, line + '\n')
  } catch {
    /* 日志永远不是关键路径 */
  }
}

/** JSON 响应（一律 no-store：状态是实时事实）。 */
function sendJson(res, status, payload) {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(payload))
}

/** 405。 */
function sendMethodNotAllowed(res, allow) {
  res.statusCode = 405
  res.setHeader('allow', allow)
  res.end()
}

/** 读取上限内请求体；超限返回 null（并把流读空）。 */
async function readBoundedBody(req) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.byteLength
    if (size > MAX_BODY_BYTES) {
      req.resume()
      return null
    }
    chunks.push(chunk)
  }
  return Buffer.concat(chunks, size).toString('utf8')
}

/** 解析 request 请求体：{ path: string }。 */
function parseRequestBody(text) {
  let body
  try {
    body = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof body !== 'object' || body === null) return null
  const target = body.path
  return typeof target === 'string' ? { path: target } : null
}

/** 解析 ack 请求体。 */
function parseAckBody(text) {
  let body
  try {
    body = JSON.parse(text)
  } catch {
    return null
  }
  if (typeof body !== 'object' || body === null) return null
  if (typeof body.id !== 'string' || typeof body.stage !== 'string') return null
  return {
    id: body.id,
    stage: body.stage,
    workspaceId: typeof body.workspaceId === 'string' ? body.workspaceId : undefined,
    message: typeof body.message === 'string' ? body.message.slice(0, 2000) : undefined
  }
}

/** Host 头是否是回环权威（防止 DNS rebinding 把远端页面带进来）。 */
function hostIsLoopback(hostHeader) {
  if (typeof hostHeader !== 'string' || hostHeader === '') return false
  let hostname
  try {
    hostname = new URL('http://' + hostHeader).hostname.toLowerCase()
  } catch {
    return false
  }
  if (hostname === 'localhost' || hostname.endsWith('.localhost') || hostname === '::1') return true
  const match = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(hostname)
  if (match === null) return false
  if (Number(match[1]) !== 127) return false
  return Number(match[2]) <= 255 && Number(match[3]) <= 255 && Number(match[4]) <= 255
}

/**
 * 页面内客户端（pending/ack）的来源校验：
 * - Host 必须是回环权威（桌面壳转发请求时 Host 就是 127.0.0.1:<port>）；
 * - 拒绝 Sec-Fetch-Site: cross-site；
 * - 有 Origin 时必须与 Host 同源（浏览器 Web 模式的正常同源 fetch 满足；
 *   Electron 桌面壳转发前会剥掉 Origin）。
 */
function pageRequestTrusted(req) {
  if (!hostIsLoopback(req.headers.host)) return false
  const site = String(req.headers['sec-fetch-site'] || '').toLowerCase()
  if (site === 'cross-site') return false
  const origin = req.headers.origin
  if (typeof origin === 'string' && origin !== '' && origin !== 'null') {
    try {
      if (new URL(origin).host.toLowerCase() !== String(req.headers.host).toLowerCase()) return false
    } catch {
      return false
    }
  }
  return true
}

/** 常量时间比较 token。 */
function tokenEquals(received, expected) {
  try {
    const left = Buffer.from(String(received ?? ''))
    const right = Buffer.from(String(expected))
    if (left.length !== right.length) return false
    return crypto.timingSafeEqual(left, right)
  } catch {
    return false
  }
}

/** 插件主体。 */
function applyPlugin(ctx) {
  /** 本次 Host 进程生命周期内有效的随机 token。 */
  const token = crypto.randomBytes(24).toString('hex')
  /** 待打开队列：外部启动器入队，页面内客户端领走。 */
  const pending = []
  /** dispose 后不再写 state.json，避免退出时留下过期状态。 */
  let disposed = false

  const stateFile = () => path.join(stateDir(), 'state.json')

  /** 原子写 state.json（先写 tmp 再 rename 覆盖）。 */
  const publishState = () => {
    if (disposed) return
    const dir = stateDir()
    fs.mkdirSync(dir, { recursive: true })
    const payload = {
      schema: 1,
      pid: process.pid,
      port: Number(ctx.webServer.port),
      host: '127.0.0.1',
      token,
      startedAt: new Date().toISOString(),
      pluginVersion: PLUGIN_VERSION
    }
    const target = stateFile()
    const tmp = target + '.' + String(process.pid) + '.tmp'
    fs.writeFileSync(tmp, JSON.stringify(payload, null, 2) + '\n', { encoding: 'utf8' })
    fs.renameSync(tmp, target)
  }

  /** webServer 端口在少数情况下要等监听完成，失败时短退避重试。 */
  const publishStateWithRetry = (attempt) => {
    if (disposed) return
    try {
      publishState()
      log('info', 'host-ready', {
        port: Number(ctx.webServer.port),
        pid: process.pid,
        stateFile: stateFile(),
        pluginVersion: PLUGIN_VERSION
      })
    } catch (error) {
      if (attempt >= 40) {
        log('error', 'state-write-failed', { message: String((error && error.message) || error) })
        return
      }
      setTimeout(() => publishStateWithRetry(attempt + 1), 250)
    }
  }
  publishStateWithRetry(0)

  // 插件管理器/ npm / GitHub 安装路径下，自动补齐 Windows 外壳集成：
  // 复制启动器源码到稳定目录、编译 exe、写 app-path、注册 HKCU 右键菜单。
  // 已由 install.ps1 安装过时这里只是幂等跳过；失败只记日志，不影响插件本身。
  void ensureShellIntegration({ log, pluginVersion: PLUGIN_VERSION })

  // dispose：删除只属于本次进程的 state.json，并注销登记。
  ctx.effect(() => () => {
    disposed = true
    try {
      const text = fs.readFileSync(stateFile(), 'utf8')
      const parsed = JSON.parse(text)
      if (parsed && parsed.pid === process.pid) fs.unlinkSync(stateFile())
    } catch {
      /* 不存在或已被其它实例覆盖：不动 */
    }
  }, 'open-in-folder: state file cleanup')

  const rejectLauncher = (req, res, status, error, logEvent) => {
    log('warn', logEvent || 'request-rejected', {
      reason: error,
      remote: String((req.socket && req.socket.remoteAddress) || ''),
      host: String(req.headers.host || '')
    })
    sendJson(res, status, { ok: false, error })
  }

  // -------------------------------------------------------------------------
  // 路由 1：GET /dsh-open-in-folder/health —— 启动器探测 DSH 是否就绪。
  // -------------------------------------------------------------------------
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ROUTE_BASE + '/health',
    handler: (req, res) => {
      if (req.method !== 'GET') return sendMethodNotAllowed(res, 'GET')
      if (!hostIsLoopback(req.headers.host)) return sendJson(res, 403, { ok: false, error: 'forbidden' })
      sendJson(res, 200, { ok: true, pid: process.pid, version: PLUGIN_VERSION })
    }
  }), 'open-in-folder: GET ' + ROUTE_BASE + '/health')

  // -------------------------------------------------------------------------
  // 路由 2：POST /dsh-open-in-folder/request —— 外部启动器入队。
  // -------------------------------------------------------------------------
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ROUTE_BASE + '/request',
    handler: async (req, res) => {
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'POST')
      if (!hostIsLoopback(req.headers.host)) return rejectLauncher(req, res, 403, 'forbidden', 'request-rejected-host')
      if (!tokenEquals(req.headers[TOKEN_HEADER], token)) {
        return rejectLauncher(req, res, 403, 'invalid token', 'request-rejected-token')
      }
      let text
      try {
        text = await readBoundedBody(req)
      } catch {
        return rejectLauncher(req, res, 400, 'request body unreadable', 'request-rejected-body')
      }
      if (text === null) return rejectLauncher(req, res, 413, 'request body is too large', 'request-rejected-large')
      const parsed = parseRequestBody(text)
      if (parsed === null) return rejectLauncher(req, res, 400, 'body must be JSON with string "path"', 'request-rejected-body')
      const folder = parsed.path.trim()
      if (folder === '' || folder.length > 32767 || !path.isAbsolute(folder)) {
        return rejectLauncher(req, res, 400, 'path must be an absolute directory path', 'request-rejected-path')
      }
      let isDirectory = false
      try {
        isDirectory = fs.statSync(folder).isDirectory()
      } catch {
        isDirectory = false
      }
      if (!isDirectory) {
        return rejectLauncher(req, res, 404, 'directory does not exist: ' + folder, 'request-rejected-missing')
      }
      const item = {
        id: crypto.randomUUID(),
        path: folder,
        createdAt: new Date().toISOString()
      }
      pending.push(item)
      let dropped = 0
      while (pending.length > MAX_PENDING) {
        pending.shift()
        dropped += 1
      }
      if (dropped > 0) log('warn', 'pending-dropped', { count: dropped, max: MAX_PENDING })
      log('info', 'request-queued', { requestId: item.id, path: item.path, queueLength: pending.length })
      sendJson(res, 200, { ok: true, requestId: item.id, path: item.path })
    }
  }), 'open-in-folder: POST ' + ROUTE_BASE + '/request')

  // -------------------------------------------------------------------------
  // 路由 3：GET /dsh-open-in-folder/pending —— 页面内客户端领取队列。
  // -------------------------------------------------------------------------
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ROUTE_BASE + '/pending',
    handler: (req, res) => {
      if (req.method !== 'GET') return sendMethodNotAllowed(res, 'GET')
      if (!pageRequestTrusted(req)) return sendJson(res, 403, { ok: false, error: 'forbidden' })
      const items = pending.splice(0, pending.length)
      if (items.length > 0) {
        log('info', 'pending-claimed', {
          count: items.length,
          requestIds: items.map((item) => item.id),
          paths: items.map((item) => item.path)
        })
      }
      sendJson(res, 200, { ok: true, items })
    }
  }), 'open-in-folder: GET ' + ROUTE_BASE + '/pending')

  // -------------------------------------------------------------------------
  // 路由 4：POST /dsh-open-in-folder/ack —— 客户端回传打开结果（只记日志）。
  // -------------------------------------------------------------------------
  ctx.effect(() => ctx.webServer.register({
    kind: 'exact',
    path: ROUTE_BASE + '/ack',
    handler: async (req, res) => {
      if (req.method !== 'POST') return sendMethodNotAllowed(res, 'POST')
      if (!pageRequestTrusted(req)) return sendJson(res, 403, { ok: false, error: 'forbidden' })
      let text
      try {
        text = await readBoundedBody(req)
      } catch {
        return sendJson(res, 400, { ok: false, error: 'request body unreadable' })
      }
      if (text === null) return sendJson(res, 413, { ok: false, error: 'request body is too large' })
      const parsed = parseAckBody(text)
      if (parsed === null) return sendJson(res, 400, { ok: false, error: 'body must be JSON with string id and stage' })
      log(parsed.stage === 'opened' ? 'info' : 'warn', 'ack', parsed)
      sendJson(res, 200, { ok: true })
    }
  }), 'open-in-folder: POST ' + ROUTE_BASE + '/ack')
}
