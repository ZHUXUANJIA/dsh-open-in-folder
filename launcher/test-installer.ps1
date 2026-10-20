# test-installer.ps1
# install.ps1 / uninstall.ps1 自动化自测（全部在隔离 DSH_HOME + 隔离注册表根下执行，
# 不触碰真实 profile / 真实右键菜单）。
#
# 覆盖：
#   A. 副作用前插件源预检（新增硬约束）：缺 lib/client.js、缺 lib/index.js、缺 cordis.patch.yml、
#      有 dsh.client 但缺 exports["./client"]、client bundle 过小、platform 非 web、
#      package.json 带 BOM、client bundle 语法错误（装有 node 时）—— 全部必须 exit 1 且零副作用；
#   B. 正常安装（预检通过 → 复制 / 编译 / junction / package.json 备份与登记）；
#   C. 卸载外科式删除：用户后来加的第三方插件条目必须保留，备份文件必须保留；
#   D. 卸载后再次安装仍幂等成功，并保住第三方插件条目；
#   E. 完整安装含右键菜单（-RegistryRoot 指向测试根）+ 卸载后注册表干净；
#   F. 无 dsh.client 的 host-only 插件可正常安装；
#   G. -NoLauncher 回归；
#   H. -KeepState 回归；
#   I. 交付脚本 PS5.1 语法 + UTF-8 BOM 检查；
#   J. 真实环境（真实 profile / 真实 HKCU 菜单）在测试前后未被改动。
#
# 用法：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\test-installer.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\test-installer.ps1 -KeepRoot
#
# 退出码：0 全部 PASS；1 有 FAIL 或脚本异常。
# 注意：测试期间请勿对真实 DSH 环境并行执行 install.ps1 / uninstall.ps1。

[CmdletBinding()]
param(
    [switch]$KeepRoot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Workspace = Split-Path -Parent $PSScriptRoot
$script:InstallScript = Join-Path $script:Workspace 'install.ps1'
$script:UninstallScript = Join-Path $script:Workspace 'uninstall.ps1'
$script:Checks = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:Root = $null
$script:Template = $null
$script:RealProfileBefore = $null
$script:RealMenuBefore = $null
$script:OriginalDshHome = $env:DSH_HOME
$script:TestRegistryRoot = 'Software\DSHOpenInFolderTest\Classes'

# ---------------------------------------------------------------- 输出/断言

function Write-Scenario {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:Checks++
    if ($Passed) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        [void]$script:Failures.Add($Name)
        if ([string]::IsNullOrEmpty($Detail)) {
            Write-Host "  [FAIL] $Name" -ForegroundColor Red
        } else {
            Write-Host "  [FAIL] $Name   ($Detail)" -ForegroundColor Red
        }
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail)
    Add-CheckResult -Name $Name -Passed $Condition -Detail $Detail
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $passed = $false
    if ($null -eq $Expected -and $null -eq $Actual) {
        $passed = $true
    } elseif ($null -ne $Expected -and $null -ne $Actual) {
        $passed = ($Expected -eq $Actual)
    }
    Add-CheckResult -Name $Name -Passed $passed -Detail ("期望 [" + [string]$Expected + "]，实际 [" + [string]$Actual + "]")
}

# ---------------------------------------------------------------- 通用辅助

function Get-PowerShellExe {
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    return 'powershell.exe'
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-TextFileNoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-FileUtf8Bom {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    } catch {
        return $false
    }
}

function Get-ObjectPropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-ProfilePackage {
    $raw = Read-TextFile -Path $script:PackagePath
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function Read-BundleList {
    param($Package)
    $bundles = @()
    if ($null -ne $Package) {
        $bundlesValue = Get-ObjectPropertyValue -Object $Package.dsh -Name 'profile'
        if ($null -ne $bundlesValue) {
            $bundlesArray = Get-ObjectPropertyValue -Object $bundlesValue -Name 'bundles'
            if ($null -ne $bundlesArray) {
                $bundles = @($bundlesArray)
            }
        }
    }
    return $bundles
}

# ---------------------------------------------------------------- 注册表（仅测试根与真实签名）

function Get-RegistryValueString {
    param([string]$KeyPath, [string]$Name)
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath, $false)
        if ($null -eq $key) {
            return '<missing>'
        }
        try {
            if ([string]::IsNullOrEmpty($Name)) {
                return [string]$key.GetValue($null)
            }
            return [string]$key.GetValue($Name)
        } finally {
            $key.Close()
        }
    } catch {
        return '<error>'
    }
}

function Test-RegistryKeyExists {
    param([string]$KeyPath)
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath, $false)
        if ($null -eq $key) {
            return $false
        }
        $key.Close()
        return $true
    } catch {
        return $false
    }
}

function Remove-TestRegistryRoot {
    try {
        $parent = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software', $true)
        if ($null -ne $parent) {
            try {
                $parent.DeleteSubKeyTree('DSHOpenInFolderTest', $false)
            } finally {
                $parent.Close()
            }
        }
    } catch {
        # 清理失败不影响结论，最后会提示。
    }
}

function Get-RealMenuSignature {
    $keys = @(
        'Software\Classes\Directory\shell\DSH.OpenInFolder',
        'Software\Classes\Directory\Background\shell\DSH.OpenInFolder',
        'Software\Classes\Drive\shell\DSH.OpenInFolder'
    )
    $parts = New-Object System.Collections.ArrayList
    foreach ($keyPath in $keys) {
        $defaultValue = Get-RegistryValueString -KeyPath $keyPath -Name ''
        $muiverb = Get-RegistryValueString -KeyPath $keyPath -Name 'MUIVerb'
        $icon = Get-RegistryValueString -KeyPath $keyPath -Name 'Icon'
        $command = Get-RegistryValueString -KeyPath ($keyPath + '\command') -Name ''
        [void]$parts.Add(($keyPath + '|' + $defaultValue + '|' + $muiverb + '|' + $icon + '|' + $command))
    }
    return ($parts -join "`n")
}

function Get-TestMenuKeyPath {
    param([string]$RelativePath)
    return ($script:TestRegistryRoot + '\' + $RelativePath)
}

# ---------------------------------------------------------------- node 探测（仅用于判断是否测语法错误用例）

function Find-NodeForTest {
    try {
        $command = Get-Command -Name 'node' -CommandType Application -ErrorAction Stop
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source) -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return $command.Source
        }
    } catch {
        # 继续。
    }
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        [void]$candidates.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $runtimesRoot = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
    if (Test-Path -LiteralPath $runtimesRoot -PathType Container) {
        try {
            $found = Get-ChildItem -LiteralPath $runtimesRoot -Recurse -Filter 'node.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $found) {
                return $found.FullName
            }
        } catch {
            # 忽略。
        }
    }
    return $null
}

# ---------------------------------------------------------------- 调用被测脚本

function Invoke-DshScript {
    param([string]$ScriptPath, [string[]]$Arguments, [string]$Label)
    $psExe = Get-PowerShellExe
    $logPath = Join-Path $script:Root ('log-' + [guid]::NewGuid().ToString('N') + '.txt')
    & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath @Arguments *> $logPath
    $exitCode = $LASTEXITCODE
    $logText = ''
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        try {
            $logText = [System.IO.File]::ReadAllText($logPath)
        } catch {
            $logText = ''
        }
    }
    if ($exitCode -ne 0) {
        Write-Host ("      [{0}] 退出码={1}（日志：{2}）" -f $Label, $exitCode, $logPath) -ForegroundColor DarkGray
        if (-not [string]::IsNullOrWhiteSpace($logText)) {
            $lines = @($logText -split "`r?`n")
            foreach ($line in ($lines | Select-Object -Last 12)) {
                Write-Host ("        | " + $line) -ForegroundColor DarkGray
            }
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; LogPath = $logPath; LogText = $logText }
}

function Invoke-Installer {
    param([string[]]$Arguments, [string]$Label)
    return (Invoke-DshScript -ScriptPath $script:InstallScript -Arguments $Arguments -Label ("install:" + $Label))
}

function Invoke-Uninstaller {
    param([string[]]$Arguments, [string]$Label)
    return (Invoke-DshScript -ScriptPath $script:UninstallScript -Arguments $Arguments -Label ("uninstall:" + $Label))
}

# ---------------------------------------------------------------- 测试夹具

function Write-ProfileTemplate {
    param([string]$ProfileDir)
    if (-not (Test-Path -LiteralPath $ProfileDir)) {
        New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ProfileDir 'node_modules'))) {
        New-Item -ItemType Directory -Path (Join-Path $ProfileDir 'node_modules') -Force | Out-Null
    }
    $template = @'
{
  "name": "dsh-profile-desktop",
  "private": true,
  "dependencies": {
    "dsh-whale-widget": "^0.4.2"
  },
  "dsh": {
    "profile": {
      "bundles": [
        "@deepseek-ai/dsh-base",
        "dsh-whale-widget"
      ]
    }
  }
}
'@
    Write-TextFileNoBom -Path (Join-Path $ProfileDir 'package.json') -Text $template
    return $template
}

function Write-FakePluginSource {
    param([string]$Target, [string]$Variant)
    if (Test-Path -LiteralPath $Target) {
        Remove-Item -LiteralPath $Target -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Target 'lib') -Force | Out-Null

    $indexCode = @'
export const name = 'dsh-open-in-folder';

export function apply(ctx) {
    ctx.on('dispose', () => {});
}
'@
    $clientCode = @'
window.__ModuleLoader__.load({
    id: 'dsh-open-in-folder',
    factory: (require) => {
        const marker = 'dsh-open-in-folder installer test client bundle';
        return { apply() { return marker; } };
    }
});
'@
    $patchYaml = @'
- id: dsh-open-in-folder
  name: dsh-open-in-folder
'@
    if ($Variant -ne 'missing-index') {
        Write-TextFileNoBom -Path (Join-Path $Target 'lib\index.js') -Text ($indexCode -replace "`r`n", "`n")
    }
    if ($Variant -ne 'missing-patch') {
        Write-TextFileNoBom -Path (Join-Path $Target 'cordis.patch.yml') -Text ($patchYaml -replace "`r`n", "`n")
    }
    Write-TextFileNoBom -Path (Join-Path $Target 'README.md') -Text "# dsh-open-in-folder (installer test fake plugin)`n"

    $clientContent = $clientCode -replace "`r`n", "`n"
    if ($Variant -eq 'tiny-client') {
        $clientContent = "export default 1;`n"
    }
    if ($Variant -eq 'client-syntax-error') {
        # 保留 >100 字节（先过大小校验），再追加语法错误行，用于验证 node --check 生效。
        $clientContent = $clientContent + "`nexport const broken = (((;`n"
    }
    if ($Variant -ne 'missing-client') {
        Write-TextFileNoBom -Path (Join-Path $Target 'lib\client.js') -Text $clientContent
    }

    $manifest = [ordered]@{
        name = 'dsh-open-in-folder'
        version = '0.1.0-test'
        description = 'fake plugin for installer preflight tests'
        type = 'module'
        main = 'lib/index.js'
        exports = [ordered]@{
            '.' = [ordered]@{ default = './lib/index.js' }
            './client' = [ordered]@{ default = './lib/client.js' }
            './package.json' = './package.json'
        }
        files = @('lib', 'cordis.patch.yml', 'README.md')
        dsh = [ordered]@{
            bundle = [ordered]@{ patch = './cordis.patch.yml' }
            client = [ordered]@{
                platform = 'web'
                inject = @('@deepseek-ai/dsh-api-workspace-controller', '@deepseek-ai/dsh-client-ui-workspace')
            }
        }
        license = 'MIT'
    }
    switch ($Variant) {
        'bad-exports' {
            $manifest.exports.Remove('./client')
        }
        'bad-platform' {
            $manifest.dsh.client.platform = 'node'
        }
        'no-client' {
            $manifest.dsh.Remove('client')
            $manifest.exports.Remove('./client')
        }
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    $manifestPath = Join-Path $Target 'package.json'
    if ($Variant -eq 'bom-manifest') {
        [System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($true)))
    } else {
        Write-TextFileNoBom -Path $manifestPath -Text $manifestJson
    }
}

function Assert-NoInstallSideEffects {
    param([string]$Label)
    Assert-True ("{0}：未创建插件目录" -f $Label) (-not (Test-Path -LiteralPath $script:PluginDir))
    Assert-True ("{0}：未创建状态目录" -f $Label) (-not (Test-Path -LiteralPath $script:StateDir))
    Assert-True ("{0}：未创建 junction" -f $Label) (-not (Test-Path -LiteralPath $script:JunctionPath))
    Assert-True ("{0}：未生成 package.json 备份" -f $Label) (-not (Test-Path -LiteralPath $script:BackupPath))
    Assert-True ("{0}：profile package.json 未被修改" -f $Label) ((Read-TextFile -Path $script:PackagePath) -eq $script:Template)
}

function Get-JunctionTarget {
    if (-not (Test-Path -LiteralPath $script:JunctionPath)) {
        return $null
    }
    $item = Get-Item -LiteralPath $script:JunctionPath -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        return $null
    }
    return [string]$item.Target
}

# ---------------------------------------------------------------- 测试用例

function Test-PreflightFailures {
    Write-Scenario 'A. 副作用前插件源预检（硬约束：失败必须 exit 1 且零副作用）'
    $cases = @(
        [pscustomobject]@{ Variant = 'missing-client'; Keyword = 'client bundle'; Label = '缺 lib/client.js' },
        [pscustomobject]@{ Variant = 'missing-index'; Keyword = 'index.js'; Label = '缺 lib/index.js' },
        [pscustomobject]@{ Variant = 'missing-patch'; Keyword = 'cordis.patch.yml'; Label = '缺 cordis.patch.yml' },
        [pscustomobject]@{ Variant = 'bad-exports'; Keyword = 'exports'; Label = '有 dsh.client 但缺 exports["./client"]' },
        [pscustomobject]@{ Variant = 'tiny-client'; Keyword = 'client bundle'; Label = 'client bundle 小于 100 字节' },
        [pscustomobject]@{ Variant = 'bad-platform'; Keyword = 'platform'; Label = 'dsh.client.platform 非 web' },
        [pscustomobject]@{ Variant = 'bom-manifest'; Keyword = 'BOM'; Label = '插件 package.json 带 BOM' }
    )
    foreach ($case in $cases) {
        $sourceDir = Join-Path (Join-Path $script:Root 'sources') $case.Variant
        Write-FakePluginSource -Target $sourceDir -Variant $case.Variant
        $result = Invoke-Installer -Arguments @('-PluginSource', $sourceDir, '-NoRegistry', '-NoLauncher') -Label ("preflight-" + $case.Variant)
        Assert-Equal ("预检失败 [{0}]：exit 1" -f $case.Label) 1 $result.ExitCode
        Assert-True ("预检失败 [{0}]：错误信息含关键字" -f $case.Label) ($result.LogText -like ("*" + $case.Keyword + "*")) ("关键字 " + $case.Keyword)
        Assert-NoInstallSideEffects -Label ("预检失败 [{0}]" -f $case.Label)
    }

    $nodePath = Find-NodeForTest
    if ($null -ne $nodePath) {
        $sourceDir = Join-Path (Join-Path $script:Root 'sources') 'client-syntax-error'
        Write-FakePluginSource -Target $sourceDir -Variant 'client-syntax-error'
        $result = Invoke-Installer -Arguments @('-PluginSource', $sourceDir, '-NoRegistry', '-NoLauncher') -Label 'preflight-client-syntax-error'
        Assert-Equal '预检失败 [client bundle 语法错误]：exit 1' 1 $result.ExitCode
        Assert-True '预检失败 [client bundle 语法错误]：node --check 生效' ($result.LogText -like '*node --check*') ("node: " + $nodePath)
        Assert-NoInstallSideEffects -Label '预检失败 [client bundle 语法错误]'
        Write-Host ("      （node --check 用例使用：{0}）" -f $nodePath) -ForegroundColor DarkGray
    } else {
        Write-Host '  [SKIP] 未找到 node 可执行文件，跳过 client bundle 语法错误用例' -ForegroundColor Yellow
    }
}

function Test-ValidInstall {
    Write-Scenario 'B. 正常安装（预检通过 → 复制 / 编译 / junction / package.json）'
    $result = Invoke-Installer -Arguments @('-PluginSource', $script:ValidSource, '-NoRegistry', '-RegistryRoot', $script:TestRegistryRoot) -Label 'install-valid'
    Assert-Equal '正常安装 exit 0' 0 $result.ExitCode
    Assert-True '插件 package.json 已复制' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'package.json') -PathType Leaf)
    Assert-True '插件 lib/index.js 已复制' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'lib\index.js') -PathType Leaf)
    Assert-True '插件 lib/client.js 已复制' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'lib\client.js') -PathType Leaf)
    Assert-True '插件 cordis.patch.yml 已复制' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'cordis.patch.yml') -PathType Leaf)
    Assert-True '启动器已编译' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'launcher\DSHOpenInFolder.exe') -PathType Leaf)
    Assert-True 'app-path.txt 已写入' (Test-Path -LiteralPath (Join-Path $script:StateDir 'app-path.txt') -PathType Leaf)
    $appText = Read-TextFile -Path (Join-Path $script:StateDir 'app-path.txt')
    Assert-True 'app-path.txt 指向真实存在的 DSH exe' (-not [string]::IsNullOrWhiteSpace($appText) -and (Test-Path -LiteralPath ([string]$appText).Trim() -PathType Leaf)) ("内容：" + [string]$appText)
    $target = Get-JunctionTarget
    Assert-True 'junction 已建立且为 reparse point' ($null -ne $target) ("target=" + [string]$target)
    Assert-True 'junction 指向插件目录' ($null -ne $target -and ([string]$target).TrimEnd('\') -ieq $script:PluginDir.TrimEnd('\')) ("target=" + [string]$target)
    $package = Get-ProfilePackage
    $expectedDependency = 'file:' + ($script:PluginDir -replace '\\', '/')
    Assert-Equal 'dependencies 已写入 file: 依赖' $expectedDependency ([string]$package.dependencies.'dsh-open-in-folder')
    $bundles = @(Read-BundleList -Package $package)
    $hits = @($bundles | Where-Object { [string]$_ -eq 'dsh-open-in-folder' })
    Assert-Equal 'dsh.profile.bundles 含本插件且仅一次' 1 $hits.Count
    Assert-True 'package.json 备份已生成' (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)
    Assert-Equal '备份内容为安装前快照' $script:Template (Read-TextFile -Path $script:BackupPath)
}

function Test-ThirdPartyPreservation {
    Write-Scenario 'C. 卸载外科式删除（保留第三方插件条目，备份文件保留）'
    # 模拟“安装之后用户又通过 UI 装了别的插件”
    $package = Get-ProfilePackage
    if ($null -eq $package) {
        Assert-True '模拟第三方插件：profile package.json 可解析' $false
        return
    }
    $package.dependencies | Add-Member -MemberType NoteProperty -Name 'dsh-example-plugin' -Value '1.0.0' -Force
    $bundles = @(Read-BundleList -Package $package)
    $package.dsh.profile.bundles = @($bundles + 'dsh-example-plugin')
    Write-TextFileNoBom -Path $script:PackagePath -Text ((($package | ConvertTo-Json -Depth 20)) + "`r`n")

    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-third-party'
    Assert-Equal '卸载 exit 0' 0 $result.ExitCode
    $after = Get-ProfilePackage
    Assert-True '卸载后 package.json 仍可解析' ($null -ne $after)
    if ($null -ne $after) {
        Assert-Equal '第三方依赖 dsh-example-plugin 被保留' '1.0.0' ([string]$after.dependencies.'dsh-example-plugin')
        Assert-True '本插件依赖已被移除' ($null -eq $after.dependencies.PSObject.Properties['dsh-open-in-folder'])
        $afterBundles = @(Read-BundleList -Package $after)
        Assert-True '第三方 bundle dsh-example-plugin 被保留' ($afterBundles -contains 'dsh-example-plugin')
        Assert-True '本插件 bundle 已被移除' (-not ($afterBundles -contains 'dsh-open-in-folder'))
    }
    Assert-True '备份文件仍存在（未被删除）' (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)
    Assert-Equal '备份内容仍是首次安装前快照' $script:Template (Read-TextFile -Path $script:BackupPath)
    Assert-True 'junction 已删除' (-not (Test-Path -LiteralPath $script:JunctionPath))
    Assert-True '插件目录已删除' (-not (Test-Path -LiteralPath $script:PluginDir))
    Assert-True '状态目录已删除' (-not (Test-Path -LiteralPath $script:StateDir))
}

function Test-ReinstallAfterUninstall {
    Write-Scenario 'D. 卸载后再次安装仍幂等成功，且保住第三方插件条目'
    $result = Invoke-Installer -Arguments @('-PluginSource', $script:ValidSource, '-NoRegistry', '-RegistryRoot', $script:TestRegistryRoot) -Label 'reinstall'
    Assert-Equal '卸载后再次安装 exit 0' 0 $result.ExitCode
    $package = Get-ProfilePackage
    $bundles = @(Read-BundleList -Package $package)
    Assert-True '本插件依赖已重新加入' ($null -ne $package.dependencies.PSObject.Properties['dsh-open-in-folder'])
    Assert-Equal '第三方依赖仍在' '1.0.0' ([string]$package.dependencies.'dsh-example-plugin')
    Assert-True '本插件 bundle 已重新加入' ($bundles -contains 'dsh-open-in-folder')
    Assert-True '第三方 bundle 仍在' ($bundles -contains 'dsh-example-plugin')
    Assert-True 'junction 已重建' ($null -ne (Get-JunctionTarget))
    Assert-True 'package.json 备份仍存在' (Test-Path -LiteralPath $script:BackupPath -PathType Leaf)
    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-reinstall'
    Assert-Equal '再次卸载 exit 0' 0 $result.ExitCode
    $after = Get-ProfilePackage
    $afterBundles = @(Read-BundleList -Package $after)
    Assert-True '再次卸载后第三方 bundle 仍在' ($afterBundles -contains 'dsh-example-plugin')
    Assert-True '再次卸载后本插件 bundle 已移除' (-not ($afterBundles -contains 'dsh-open-in-folder'))
}

function Test-FullInstallWithRegistry {
    Write-Scenario 'E. 完整安装含右键菜单（隔离注册表根）+ 卸载后注册表干净'
    $result = Invoke-Installer -Arguments @('-PluginSource', $script:ValidSource, '-RegistryRoot', $script:TestRegistryRoot) -Label 'install-with-registry'
    Assert-Equal '含注册表安装 exit 0' 0 $result.ExitCode
    $keyPaths = @(
        (Get-TestMenuKeyPath 'Directory\shell\DSH.OpenInFolder'),
        (Get-TestMenuKeyPath 'Directory\Background\shell\DSH.OpenInFolder'),
        (Get-TestMenuKeyPath 'Drive\shell\DSH.OpenInFolder')
    )
    foreach ($keyPath in $keyPaths) {
        Assert-True ("测试注册表键存在：{0}" -f $keyPath) (Test-RegistryKeyExists -KeyPath $keyPath)
    }
    $directoryKey = $keyPaths[0]
    Assert-True '菜单文本含 DeepSeek Harness' ((Get-RegistryValueString -KeyPath $directoryKey -Name '') -like '*DeepSeek Harness*')
    $commandValue = Get-RegistryValueString -KeyPath ($directoryKey + '\command') -Name ''
    $launcherPath = Join-Path $script:PluginDir 'launcher\DSHOpenInFolder.exe'
    Assert-True 'Directory 命令指向启动器 exe' ($commandValue -like ('*' + $launcherPath + '*')) ("实际：" + $commandValue)
    Assert-True 'Directory 命令使用 %1' ($commandValue -like '*%1*')
    $backgroundCommand = Get-RegistryValueString -KeyPath ($keyPaths[1] + '\command') -Name ''
    Assert-True 'Background 命令使用 %V' ($backgroundCommand -like '*%V*')
    $driveCommand = Get-RegistryValueString -KeyPath ($keyPaths[2] + '\command') -Name ''
    Assert-True 'Drive 命令使用 %1' ($driveCommand -like '*%1*')
    $iconPath = Join-Path $script:PluginDir 'assets\icon.ico'
    Assert-True '图标已提取' (Test-Path -LiteralPath $iconPath -PathType Leaf)
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        $iconBytes = [System.IO.File]::ReadAllBytes($iconPath)
        $validIco = ($iconBytes.Length -gt 4 -and $iconBytes[0] -eq 0 -and $iconBytes[1] -eq 0 -and $iconBytes[2] -eq 1 -and $iconBytes[3] -eq 0)
        Assert-True '图标为合法 ICO 头' $validIco
        $iconValue = Get-RegistryValueString -KeyPath $directoryKey -Name 'Icon'
        Assert-True '测试注册表 Icon 指向提取的 ico' ($iconValue -ieq $iconPath) ("实际：" + $iconValue)
    }

    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-with-registry'
    Assert-Equal '卸载 exit 0' 0 $result.ExitCode
    foreach ($keyPath in $keyPaths) {
        Assert-True ("测试注册表键已删除：{0}" -f $keyPath) (-not (Test-RegistryKeyExists -KeyPath $keyPath))
    }
}

function Test-HostOnlyPlugin {
    Write-Scenario 'F. 无 dsh.client 的 host-only 插件可正常安装/卸载'
    $sourceDir = Join-Path (Join-Path $script:Root 'sources') 'no-client'
    Write-FakePluginSource -Target $sourceDir -Variant 'no-client'
    $result = Invoke-Installer -Arguments @('-PluginSource', $sourceDir, '-NoRegistry', '-RegistryRoot', $script:TestRegistryRoot) -Label 'install-host-only'
    Assert-Equal 'host-only 插件安装 exit 0' 0 $result.ExitCode
    Assert-True 'host-only 插件目录已复制' (Test-Path -LiteralPath (Join-Path $script:PluginDir 'package.json') -PathType Leaf)
    Assert-True 'host-only 插件 junction 已建立' ($null -ne (Get-JunctionTarget))
    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-host-only'
    Assert-Equal 'host-only 插件卸载 exit 0' 0 $result.ExitCode
}

function Test-NoLauncherRegression {
    Write-Scenario 'G. -NoLauncher 回归'
    $result = Invoke-Installer -Arguments @('-PluginSource', $script:ValidSource, '-NoRegistry', '-NoLauncher', '-RegistryRoot', $script:TestRegistryRoot) -Label 'install-nolauncher'
    Assert-Equal '-NoLauncher 安装 exit 0' 0 $result.ExitCode
    Assert-True '-NoLauncher 未编译启动器' (-not (Test-Path -LiteralPath (Join-Path $script:PluginDir 'launcher\DSHOpenInFolder.exe')))
    Assert-True '-NoLauncher 仍建立 junction' ($null -ne (Get-JunctionTarget))
    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-nolauncher'
    Assert-Equal '-NoLauncher 卸载 exit 0' 0 $result.ExitCode
}

function Test-KeepStateRegression {
    Write-Scenario 'H. -KeepState 回归'
    $result = Invoke-Installer -Arguments @('-PluginSource', $script:ValidSource, '-NoRegistry', '-RegistryRoot', $script:TestRegistryRoot) -Label 'install-keepstate'
    Assert-Equal '安装 exit 0' 0 $result.ExitCode
    $result = Invoke-Uninstaller -Arguments @('-KeepState', '-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-keepstate'
    Assert-Equal '-KeepState 卸载 exit 0' 0 $result.ExitCode
    Assert-True '-KeepState 保留状态目录' (Test-Path -LiteralPath $script:StateDir -PathType Container)
    $result = Invoke-Uninstaller -Arguments @('-RegistryRoot', $script:TestRegistryRoot) -Label 'uninstall-clean-state'
    Assert-Equal '清理状态目录卸载 exit 0' 0 $result.ExitCode
    Assert-True '状态目录已删除' (-not (Test-Path -LiteralPath $script:StateDir))
}

function Test-ScriptSyntaxAndBom {
    Write-Scenario 'I. 交付脚本 PS5.1 语法 + UTF-8 BOM'
    $psFiles = @(
        (Join-Path $script:Workspace 'install.ps1'),
        (Join-Path $script:Workspace 'uninstall.ps1'),
        (Join-Path $script:Workspace 'launcher\build-launcher.ps1'),
        (Join-Path $script:Workspace 'launcher\test-launcher.ps1')
    )
    foreach ($psFile in $psFiles) {
        Assert-True ("UTF-8 BOM：{0}" -f (Split-Path -Leaf $psFile)) (Test-FileUtf8Bom -Path $psFile)
        $psExe = Get-PowerShellExe
        $escapedPath = $psFile -replace "'", "''"
        $command = "try { [scriptblock]::Create([System.IO.File]::ReadAllText('$escapedPath')) | Out-Null; exit 0 } catch { exit 1 }"
        & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command *> $null
        $syntaxExit = $LASTEXITCODE
        Assert-Equal ("PS5.1 语法：{0}" -f (Split-Path -Leaf $psFile)) 0 $syntaxExit
    }
    $csFile = Join-Path $script:Workspace 'launcher\DSHOpenInFolder.cs'
    Assert-True 'UTF-8 BOM：launcher\DSHOpenInFolder.cs' (Test-FileUtf8Bom -Path $csFile)
}

function Test-RealEnvironmentUntouched {
    Write-Scenario 'J. 真实环境（真实 profile / 真实 HKCU 菜单）未被改动'
    $realProfileAfter = Read-TextFile -Path $script:RealProfilePath
    Assert-True '真实 desktop profile package.json 未变' ($realProfileAfter -eq $script:RealProfileBefore)
    $realMenuAfter = Get-RealMenuSignature
    Assert-True '真实 HKCU 右键菜单注册表未变' ($realMenuAfter -eq $script:RealMenuBefore)
    Remove-TestRegistryRoot
    Assert-True '测试注册表根已清理' (-not (Test-RegistryKeyExists -KeyPath $script:TestRegistryRoot))
}

# ---------------------------------------------------------------- 主流程

$exitCode = 0
try {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Cyan
    Write-Host '#  install.ps1 / uninstall.ps1 自测（隔离 DSH_HOME + 隔离注册表根）' -ForegroundColor Cyan
    Write-Host '############################################################' -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $script:InstallScript -PathType Leaf)) {
        throw "缺少 install.ps1：$($script:InstallScript)"
    }
    if (-not (Test-Path -LiteralPath $script:UninstallScript -PathType Leaf)) {
        throw "缺少 uninstall.ps1：$($script:UninstallScript)"
    }

    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-installer-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    $script:TestHome = Join-Path $script:Root 'home'
    $profileDir = Join-Path $script:TestHome 'profiles\desktop'
    $script:PluginDir = Join-Path $script:TestHome 'plugins\dsh-open-in-folder'
    $script:StateDir = Join-Path $script:TestHome 'open-in-folder'
    $script:JunctionPath = Join-Path $profileDir 'node_modules\dsh-open-in-folder'
    $script:PackagePath = Join-Path $profileDir 'package.json'
    $script:BackupPath = Join-Path $profileDir 'package.json.bak-open-in-folder'
    $script:ValidSource = Join-Path (Join-Path $script:Root 'sources') 'valid'
    $script:RealProfilePath = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\package.json'
    Write-Host "临时目录：$($script:Root)" -ForegroundColor DarkGray

    # 真实环境快照（只读）
    $script:RealProfileBefore = Read-TextFile -Path $script:RealProfilePath
    $script:RealMenuBefore = Get-RealMenuSignature

    # 隔离 DSH_HOME + 隔离注册表根
    New-Item -ItemType Directory -Path $script:TestHome -Force | Out-Null
    $script:Template = Write-ProfileTemplate -ProfileDir $profileDir
    Write-FakePluginSource -Target $script:ValidSource -Variant 'valid'
    $env:DSH_HOME = $script:TestHome
    Remove-TestRegistryRoot

    Test-PreflightFailures
    Test-ValidInstall
    Test-ThirdPartyPreservation
    Test-ReinstallAfterUninstall
    Test-FullInstallWithRegistry
    Test-HostOnlyPlugin
    Test-NoLauncherRegression
    Test-KeepStateRegression
    Test-ScriptSyntaxAndBom
    Test-RealEnvironmentUntouched

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($script:Failures.Count -eq 0) {
        Write-Host ("  自测结果：全部 PASS（{0} 项检查）" -f $script:Checks) -ForegroundColor Green
    } else {
        Write-Host ("  自测结果：{0} 项 FAIL / 共 {1} 项检查" -f $script:Failures.Count, $script:Checks) -ForegroundColor Red
        foreach ($failureName in $script:Failures) {
            Write-Host ("   - " + $failureName) -ForegroundColor Red
        }
        $exitCode = 1
    }
    Write-Host '============================================================' -ForegroundColor Cyan
} catch {
    Write-Host ''
    Write-Host "  [FAIL] 测试脚本自身异常：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 1
} finally {
    if ($null -eq $script:OriginalDshHome) {
        Remove-Item Env:\DSH_HOME -ErrorAction SilentlyContinue
    } else {
        $env:DSH_HOME = $script:OriginalDshHome
    }
    Remove-TestRegistryRoot
    if ($null -ne $script:Root -and (Test-Path -LiteralPath $script:Root)) {
        if ($KeepRoot) {
            Write-Host "临时目录已保留：$($script:Root)" -ForegroundColor Yellow
        } else {
            try {
                Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction Stop
            } catch {
                Write-Host "清理临时目录失败（可忽略）：$($script:Root)" -ForegroundColor Yellow
            }
        }
    }
}
exit $exitCode
