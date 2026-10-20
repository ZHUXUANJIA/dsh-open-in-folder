/**
 * dsh-open-in-folder —— Windows 外壳集成自安装器（Host 半边内部模块）
 *
 * 场景：用户不再运行 install.ps1，而是在 DSH「设置 → 插件 → 添加插件」里
 * 直接输入包名/GitHub 地址安装。插件被 pnpm 装进 profile 的 node_modules 后，
 * Host 半边在 DSH 进程内加载；本模块负责把「右键菜单 + 启动器」这一半补上：
 *
 *   1. 把插件运行所需文件复制到稳定目录 %DSH_HOME%\plugins\dsh-open-in-folder
 *      （pnpm 的 node_modules 会被重装/清理，不能直接作为启动器安装位置）；
 *   2. 用 Windows 自带的 .NET Framework csc.exe 编译 DSHOpenInFolder.exe；
 *   3. 写入 %DSH_HOME%\open-in-folder\app-path.txt（DSH 应用绝对路径）；
 *   4. 用 reg.exe import 注册 HKCU 右键菜单（文件夹 / 空白处 / 盘符）；
 *   5. 写 shell-integration.json 标记，版本变化时自动重装。
 *
 * 安全边界：只写当前用户 HKCU 与 %DSH_HOME% 下的文件，不联网、不请求管理员权限。
 * 测试/特殊环境可用环境变量关闭或重定向：
 *   - DSH_OPEN_IN_FOLDER_SKIP_SHELL_INTEGRATION=1  完全跳过
 *   - DSH_OPEN_IN_FOLDER_REGISTRY_ROOT=<subkey>     注册表根改为 HKCU\<subkey>（默认 Software\Classes）
 *   - DSH_APP_EXE=<path>                           指定 DeepSeek Harness.exe
 */
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

/** 稳定安装目录名。 */
const INSTALL_DIR_NAME = 'dsh-open-in-folder'
/** 菜单文案。 */
const MENU_TEXT = '在 DeepSeek Harness 中打开'
/** 模块所在包根需包含的 dsh 字段名。 */
const PACKAGE_NAME = 'dsh-open-in-folder'

function dshHome() {
  return process.env.DSH_HOME || path.join(os.homedir(), '.dsh')
}

function stateDir() {
  return process.env.DSH_OPEN_IN_FOLDER_STATE_DIR || path.join(dshHome(), 'open-in-folder')
}

function stablePluginDir() {
  return path.join(dshHome(), 'plugins', INSTALL_DIR_NAME)
}

function shellIntegrationMarker() {
  return path.join(stateDir(), 'shell-integration.json')
}

/**
 * 从当前模块文件所在目录向上找本包的 package.json（兼容两种布局：
 * 手动安装 = <插件目录>/lib/index.js；npm/GitHub 安装 = <包根>/plugin/lib/index.js）。
 * @returns {{ dir: string, pkg: any } | null}
 */
function findPackageRoot() {
  let dir = path.dirname(fileURLToPath(import.meta.url))
  for (let depth = 0; depth < 6; depth += 1) {
    const manifestPath = path.join(dir, 'package.json')
    if (fs.existsSync(manifestPath)) {
      try {
        const pkg = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
        if (pkg && pkg.name === PACKAGE_NAME && pkg.dsh !== undefined) return { dir, pkg }
      } catch {
        /* 继续向上找 */
      }
    }
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

/** 定位 DSH 应用 exe。 */
function resolveAppExe() {
  const override = process.env.DSH_APP_EXE
  if (typeof override === 'string' && override !== '' && fs.existsSync(override)) return path.resolve(override)
  const execPath = process.execPath
  if (typeof execPath === 'string' && execPath !== '' && /DeepSeek Harness(\.exe)?$/i.test(path.basename(execPath)) && fs.existsSync(execPath)) {
    return path.resolve(execPath)
  }
  if (process.platform === 'win32' && typeof execPath === 'string' && execPath !== '' && /electron/i.test(path.basename(execPath)) && fs.existsSync(execPath)) {
    return path.resolve(execPath)
  }
  try {
    const result = spawnSync('reg.exe', ['query', 'HKCU\\Software\\Classes\\dsh\\shell\\open\\command', '/ve'], {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 5000
    })
    if (result.status === 0 && typeof result.stdout === 'string') {
      const match = /(?:^|\s)"?([A-Za-z]:\\[^"\r\n]+?DeepSeek Harness\.exe)"?/i.exec(result.stdout)
      if (match !== null && fs.existsSync(match[1])) return path.resolve(match[1])
    }
  } catch {
    /* 忽略 */
  }
  return null
}

/** 找 csc.exe（.NET Framework 4.x 自带）。 */
function findCsc() {
  const override = process.env.DSH_OPEN_IN_FOLDER_CSC
  if (typeof override === 'string' && override !== '' && fs.existsSync(override)) return override
  const windir = process.env.WINDIR || process.env.SystemRoot || 'C:\\Windows'
  const candidates = [
    path.join(windir, 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe'),
    path.join(windir, 'Microsoft.NET', 'Framework', 'v4.0.30319', 'csc.exe')
  ]
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate
    } catch {
      /* 忽略 */
    }
  }
  return null
}

/** 复制一个文件（目标存在则覆盖）。 */
function copyFileSafe(source, target) {
  try {
    fs.mkdirSync(path.dirname(target), { recursive: true })
    fs.copyFileSync(source, target)
    return true
  } catch {
    return false
  }
}

/** 递归复制目录。 */
function copyDirSafe(source, target) {
  try {
    fs.mkdirSync(target, { recursive: true })
    for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
      const from = path.join(source, entry.name)
      const to = path.join(target, entry.name)
      if (entry.isDirectory()) copyDirSafe(from, to)
      else fs.copyFileSync(from, to)
    }
    return true
  } catch {
    return false
  }
}

/**
 * 复制「插件包」到稳定目录（package.json / cordis.patch.yml / lib/）。
 * npm 包布局是 <包根>/plugin/*，手动布局是 <插件目录>/*。
 */
function installPluginFiles(packageRoot) {
  const pluginDir = path.dirname(fileURLToPath(import.meta.url)) // …/lib
  const candidates = [path.join(packageRoot, 'plugin'), path.join(pluginDir, '..')]
  const source = candidates.find((candidate) => fs.existsSync(path.join(candidate, 'package.json')) && fs.existsSync(path.join(candidate, 'cordis.patch.yml')))
  if (source === undefined) throw new Error('插件包缺少 plugin/package.json 或 cordis.patch.yml')
  const target = stablePluginDir()
  // 手动安装时插件就运行在稳定目录里：源与目标相同，不能自我复制（否则会先删掉自己）。
  if (path.resolve(source) === path.resolve(target)) return target
  fs.mkdirSync(target, { recursive: true })
  copyFileSafe(path.join(source, 'package.json'), path.join(target, 'package.json'))
  copyFileSafe(path.join(source, 'cordis.patch.yml'), path.join(target, 'cordis.patch.yml'))
  copyFileSafe(path.join(source, 'README.md'), path.join(target, 'README.md'))
  const libSource = path.join(source, 'lib')
  const libTarget = path.join(target, 'lib')
  fs.rmSync(libTarget, { recursive: true, force: true })
  if (!copyDirSafe(libSource, libTarget)) throw new Error('复制 lib/ 到稳定目录失败')
  return target
}

/** 定位启动器 C# 源码（npm 包根 = launcher/…；手动安装时同为仓库 launcher/…）。 */
function resolveLauncherSource(packageRoot) {
  const candidates = [
    path.join(packageRoot, 'launcher', 'DSHOpenInFolder.cs'),
    path.join(packageRoot, '..', 'launcher', 'DSHOpenInFolder.cs')
  ]
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) return candidate
    } catch {
      /* 忽略 */
    }
  }
  return undefined
}

/** 编译启动器；返回 exe 路径。 */
function buildLauncher(launcherSource, stableDir) {
  const csc = findCsc()
  if (csc === undefined) throw new Error('找不到 .NET Framework csc.exe，无法编译启动器')
  const launcherDir = path.join(stableDir, 'launcher')
  fs.mkdirSync(launcherDir, { recursive: true })
  const sourceTarget = path.join(launcherDir, 'DSHOpenInFolder.cs')
  copyFileSafe(launcherSource, sourceTarget)
  const exePath = path.join(launcherDir, 'DSHOpenInFolder.exe')
  const result = spawnSync(csc, [
    '/nologo',
    '/target:winexe',
    '/codepage:65001',
    '/out:' + exePath,
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    sourceTarget
  ], { windowsHide: true, timeout: 180000, encoding: 'utf8' })
  if (result.status !== 0 || !fs.existsSync(exePath)) {
    const detail = [result.stdout, result.stderr].filter(Boolean).join('\n').trim()
    throw new Error('csc 编译启动器失败（exit ' + String(result.status) + '）：' + detail.slice(0, 800))
  }
  return exePath
}

/** .reg 值数据转义：反斜杠需写成双反斜杠，引号写成 \"（否则 reg import 会静默丢弃该值）。 */
function regValue(text) {
  return String(text).replace(/\\/g, '\\\\').replace(/"/g, '\\"')
}

/** 注册表 .reg 内容（HKCU 下，路径与值中的引号按 .reg 语法转义）。 */
function buildRegFileContent(launcherExe, appExe) {
  const registryRoot = process.env.DSH_OPEN_IN_FOLDER_REGISTRY_ROOT || 'Software\\Classes'
  const root = 'HKEY_CURRENT_USER\\' + registryRoot.replace(/^\\+|\\+$/g, '')
  const menuTargets = [
    { key: 'Directory\\shell', placeholder: '%1' },
    { key: 'Directory\\Background\\shell', placeholder: '%V' },
    { key: 'Drive\\shell', placeholder: '%1' }
  ]
  const lines = ['Windows Registry Editor Version 5.00', '']
  for (const target of menuTargets) {
    const keyPath = root + '\\' + target.key + '\\DSH.OpenInFolder'
    const commandLine = '"' + launcherExe + '" "' + target.placeholder + '"'
    lines.push('[' + keyPath + ']')
    lines.push('@="' + regValue(MENU_TEXT) + '"')
    lines.push('"MUIVerb"="' + regValue(MENU_TEXT) + '"')
    lines.push('"Icon"="' + regValue(appExe) + '"')
    lines.push('')
    lines.push('[' + keyPath + '\\command]')
    lines.push('@="' + regValue(commandLine) + '"')
    lines.push('')
  }
  return lines.join('\r\n')
}

/** 用 reg.exe import 注册菜单（UTF-16LE + BOM 的 .reg 文件）。 */
function registerContextMenu(launcherExe, appExe) {
  const regPath = path.join(os.tmpdir(), 'dsh-open-in-folder-' + String(process.pid) + '.reg')
  const content = buildRegFileContent(launcherExe, appExe)
  fs.writeFileSync(regPath, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(content, 'utf16le')]))
  try {
    const result = spawnSync('reg.exe', ['import', regPath], { windowsHide: true, timeout: 30000, encoding: 'utf8' })
    if (result.status !== 0) {
      const detail = [result.stdout, result.stderr].filter(Boolean).join('\n').trim()
      throw new Error('reg import 失败（exit ' + String(result.status) + '）：' + detail.slice(0, 500))
    }
  } finally {
    try {
      fs.rmSync(regPath, { force: true })
    } catch {
      /* 忽略 */
    }
  }
}

/** 写 app-path.txt（启动器用它定位 DSH 应用）。 */
function writeAppPath(appExe) {
  fs.mkdirSync(stateDir(), { recursive: true })
  fs.writeFileSync(path.join(stateDir(), 'app-path.txt'), appExe + '\r\n', 'utf8')
}

/** 校验现有安装是否仍与当前包版本一致。 */
function installationCurrent(markerPath, pluginVersion, launcherExe) {
  try {
    const marker = JSON.parse(fs.readFileSync(markerPath, 'utf8'))
    return marker && marker.version === pluginVersion && fs.existsSync(launcherExe)
  } catch {
    return false
  }
}

/**
 * 确保 Windows 外壳集成已安装（幂等；版本变化时自动重装）。
 * 永不抛异常：失败只记录日志，插件其它能力不受影响。
 *
 * @param {{ log: (level: string, event: string, details?: object) => void, pluginVersion: string }} options
 * @returns {Promise<void>}
 */
export async function ensureShellIntegration(options) {
  const { log, pluginVersion } = options
  try {
    if (process.platform !== 'win32') return
    if (process.env.DSH_OPEN_IN_FOLDER_SKIP_SHELL_INTEGRATION === '1') {
      log('info', 'shell-integration-skipped', { reason: 'DSH_OPEN_IN_FOLDER_SKIP_SHELL_INTEGRATION=1' })
      return
    }
    const launcherExe = path.join(stablePluginDir(), 'launcher', 'DSHOpenInFolder.exe')
    const markerPath = shellIntegrationMarker()
    if (installationCurrent(markerPath, pluginVersion, launcherExe)) return
    // 稳定目录里已经有启动器但本次插件不是从稳定目录运行的：
    // 说明外壳集成由 install.ps1 手动安装过，这里只补标记，避免反复重装。
    if (!fs.existsSync(markerPath) && fs.existsSync(launcherExe)) {
      fs.mkdirSync(stateDir(), { recursive: true })
      fs.writeFileSync(markerPath, JSON.stringify({
        version: pluginVersion,
        installedAt: new Date().toISOString(),
        launcher: launcherExe,
        managedBy: 'install.ps1'
      }, null, 2) + '\n', 'utf8')
      log('info', 'shell-integration-external', { launcher: launcherExe, managedBy: 'install.ps1' })
      return
    }

    const packageRoot = findPackageRoot()
    if (packageRoot === null) throw new Error('无法定位插件包根目录（package.json）')
    const launcherSource = resolveLauncherSource(packageRoot.dir)
    if (launcherSource === undefined) {
      if (fs.existsSync(launcherExe)) {
        fs.mkdirSync(stateDir(), { recursive: true })
        fs.writeFileSync(markerPath, JSON.stringify({
          version: pluginVersion,
          installedAt: new Date().toISOString(),
          launcher: launcherExe,
          managedBy: 'install.ps1'
        }, null, 2) + '\n', 'utf8')
        log('info', 'shell-integration-external', { launcher: launcherExe, managedBy: 'install.ps1' })
        return
      }
      throw new Error('插件包中缺少 launcher/DSHOpenInFolder.cs')
    }
    const appExe = resolveAppExe()
    if (appExe === undefined) {
      log('warn', 'shell-integration-skipped', {
        reason: '无法定位 DeepSeek Harness.exe；可设置环境变量 DSH_APP_EXE，或运行 install.ps1 手动安装'
      })
      return
    }

    const stableDir = installPluginFiles(packageRoot.dir)
    const compiledLauncher = buildLauncher(launcherSource, stableDir)
    writeAppPath(appExe)
    registerContextMenu(compiledLauncher, appExe)

    const marker = {
      version: pluginVersion,
      installedAt: new Date().toISOString(),
      launcher: compiledLauncher,
      appExe,
      pluginRoot: packageRoot.dir
    }
    fs.writeFileSync(markerPath, JSON.stringify(marker, null, 2) + '\n', 'utf8')
    log('info', 'shell-integration-ready', {
      version: pluginVersion,
      launcher: compiledLauncher,
      appExe,
      stableDir
    })
  } catch (error) {
    log('warn', 'shell-integration-failed', {
      message: String((error && error.stack) || error).slice(0, 1500)
    })
  }
}
