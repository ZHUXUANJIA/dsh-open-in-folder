#Requires -Version 5.1
<#
.SYNOPSIS
    「在 DeepSeek Harness 中打开」一键自检。
.DESCRIPTION
    检查插件安装、profile 登记、右键菜单、运行中 DSH Host 的 state.json/health 与事件日志。
    可选 -OpenFolder 做一次真实打开链路自检（会观察 events.log 是否出现 request-queued → pending-claimed → ack opened）。
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -OpenFolder "D:\path\to\your-project"
#>
[CmdletBinding()]
param(
    [string]$DshHome = '',
    [string]$OpenFolder = ''
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($DshHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $DshHome = $env:DSH_HOME }
    else { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
}

$script:Pass = 0
$script:Fail = 0
$script:Warn = 0
$script:Failures = @()

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:Pass++
        if ($Detail) { Write-Host ("  [PASS] {0}  {1}" -f $Name, $Detail) -ForegroundColor Green }
        else { Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green }
    } else {
        $script:Fail++
        $script:Failures += $Name
        if ($Detail) { Write-Host ("  [FAIL] {0}  {1}" -f $Name, $Detail) -ForegroundColor Red }
        else { Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red }
    }
}

function Check-Warn {
    param([string]$Name, [string]$Detail = '')
    $script:Warn++
    Write-Host ("  [WARN] {0}  {1}" -f $Name, $Detail) -ForegroundColor Yellow
}

function Read-TextFile {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return $null }
}

function Get-JsonProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-BundleList {
    param($Package)
    $dshNode = Get-JsonProperty $Package 'dsh'
    $profileNode = Get-JsonProperty $dshNode 'profile'
    $bundles = Get-JsonProperty $profileNode 'bundles'
    if ($null -eq $bundles) { return @() }
    return @($bundles)
}

function Get-RegistryValue {
    param([string]$KeyPath, [string]$Name)
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($KeyPath)
        if ($null -eq $key) { return $null }
        try {
            $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return $value
        } finally { $key.Close() }
    } catch { return $null }
}

function Get-HttpJson {
    param([string]$Url, [int]$TimeoutSec = 3)
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $request.Proxy = $null
        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            return $text
        } finally { $response.Close() }
    } catch { return $null }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' DeepSeek Harness「右键打开文件夹」自检' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host (" DSH_HOME: {0}" -f $DshHome)
Write-Host ''

$pluginDir = Join-Path (Join-Path $DshHome 'plugins') 'dsh-open-in-folder'
$stateDir = Join-Path $DshHome 'open-in-folder'
$profileDir = Join-Path (Join-Path $DshHome 'profiles') 'desktop'
$packagePath = Join-Path $profileDir 'package.json'
$launcherExe = Join-Path (Join-Path $pluginDir 'launcher') 'DSHOpenInFolder.exe'

Write-Host '== 1. 文件与安装状态 ==' -ForegroundColor Cyan
Check 'DSH_HOME 存在' (Test-Path -LiteralPath $DshHome -PathType Container) $DshHome
Check '插件目录存在' (Test-Path -LiteralPath $pluginDir -PathType Container) $pluginDir
foreach ($relative in @('package.json', 'cordis.patch.yml', 'lib\index.js', 'lib\client.js')) {
    $path = Join-Path $pluginDir $relative
    Check ("插件文件 " + $relative) (Test-Path -LiteralPath $path -PathType Leaf) $path
}
Check '启动器 exe 存在' (Test-Path -LiteralPath $launcherExe -PathType Leaf) $launcherExe
Check 'profile package.json 存在' (Test-Path -LiteralPath $packagePath -PathType Leaf) $packagePath

$junctionPath = Join-Path $profileDir 'node_modules\dsh-open-in-folder'
if (Test-Path -LiteralPath $junctionPath) {
    $junctionItem = Get-Item -LiteralPath $junctionPath -Force
    $isReparse = (($junctionItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    Check 'profile node_modules 解析项是链接' $isReparse ([string]$junctionItem.Target)
    Check '链接指向插件目录' ([string]$junctionItem.Target -ieq $pluginDir) ([string]$junctionItem.Target)
} else {
    Check 'profile node_modules 解析项存在' $false $junctionPath
}

Write-Host ''
Write-Host '== 2. profile 登记 ==' -ForegroundColor Cyan
$packageText = Read-TextFile $packagePath
if ($packageText) {
    try {
        $package = $packageText | ConvertFrom-Json
        $dependencies = Get-JsonProperty $package 'dependencies'
        $dependency = Get-JsonProperty $dependencies 'dsh-open-in-folder'
        Check 'dependencies 含 dsh-open-in-folder' (-not [string]::IsNullOrWhiteSpace([string]$dependency)) ([string]$dependency)
        if (-not [string]::IsNullOrWhiteSpace([string]$dependency)) {
            $expected = 'file:' + ($pluginDir -replace '\\', '/')
            Check '依赖指向插件目录' ([string]$dependency -ieq $expected) ([string]$dependency)
        }
        $bundles = Get-BundleList $package
        Check 'dsh.profile.bundles 含 dsh-open-in-folder' ($bundles -contains 'dsh-open-in-folder') ("bundles: " + ($bundles -join ', '))
    } catch {
        Check 'profile package.json 可解析' $false $_.Exception.Message
    }
} else {
    Check 'profile package.json 可读取' $false $packagePath
}

Write-Host ''
Write-Host '== 3. 资源管理器右键菜单（HKCU）==' -ForegroundColor Cyan
$menuTargets = @(
    @{ KeyPath = 'Software\Classes\Directory\shell\DSH.OpenInFolder'; Placeholder = '%1' },
    @{ KeyPath = 'Software\Classes\Directory\Background\shell\DSH.OpenInFolder'; Placeholder = '%V' },
    @{ KeyPath = 'Software\Classes\Drive\shell\DSH.OpenInFolder'; Placeholder = '%1' }
)
foreach ($target in $menuTargets) {
    $menuVerb = Get-RegistryValue -KeyPath $target.KeyPath -Name 'MUIVerb'
    $command = Get-RegistryValue -KeyPath ($target.KeyPath + '\command') -Name ''
    $shortKey = $target.KeyPath -replace '^Software\\Classes\\', ''
    Check ("菜单项 " + $shortKey) (-not [string]::IsNullOrWhiteSpace([string]$menuVerb)) ([string]$menuVerb)
    $commandOk = (-not [string]::IsNullOrWhiteSpace([string]$command)) -and ([string]$command).Contains('DSHOpenInFolder.exe') -and ([string]$command).Contains($target.Placeholder)
    Check ("命令 " + $shortKey) $commandOk ([string]$command)
}

Write-Host ''
Write-Host '== 4. 运行中 DSH Host（插件是否已加载）==' -ForegroundColor Cyan
$statePath = Join-Path $stateDir 'state.json'
$state = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $stateText = Read-TextFile $statePath
    if ($stateText) {
        try { $state = $stateText | ConvertFrom-Json } catch { $state = $null }
    }
}
if ($null -eq $state) {
    Check 'state.json 存在且可解析' $false ($statePath + '（DSH 未加载插件：完全退出 DSH 后重开，或检查 events.log）')
} else {
    Check 'state.json 存在且可解析' $true ("pid=" + $state.pid + " port=" + $state.port)
    $running = $null
    try { $running = Get-Process -Id ([int]$state.pid) -ErrorAction Stop } catch { $running = $null }
    Check 'state.json 的进程仍在运行' ($null -ne $running) ("pid=" + $state.pid)
    $healthUrl = ('http://127.0.0.1:' + [string]$state.port + '/dsh-open-in-folder/health')
    $healthText = Get-HttpJson -Url $healthUrl
    if ($healthText) {
        Check 'Host /health 可达' $true $healthUrl
        try {
            $health = $healthText | ConvertFrom-Json
            Check 'health ok=true' ([bool]$health.ok) ($healthText.Trim())
            Check 'health pid 与 state 一致' ([int]$health.pid -eq [int]$state.pid) ([string]$healthText.Trim())
        } catch {
            Check 'health 响应可解析' $false $healthText
        }
    } else {
        Check 'Host /health 可达' $false ($healthUrl + '（插件未加载或 DSH 已退出）')
    }
}

$eventsPath = Join-Path $stateDir 'events.log'
Write-Host ''
Write-Host '== 5. 日志 ==' -ForegroundColor Cyan
if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
    $events = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8 -ErrorAction SilentlyContinue)
    $hostReady = @($events | Where-Object { $_ -match '"event":"host-ready"' })
    $queued = @($events | Where-Object { $_ -match '"event":"request-queued"' })
    $claimed = @($events | Where-Object { $_ -match '"event":"pending-claimed"' })
    $acked = @($events | Where-Object { $_ -match '"stage":"opened"' })
    Check 'events.log 有 host-ready（插件已加载）' ($hostReady.Count -gt 0) ("host-ready 次数: " + $hostReady.Count)
    Write-Host ("  统计：request-queued={0}  pending-claimed={1}  ack(opened)={2}" -f $queued.Count, $claimed.Count, $acked.Count)
    if ($events.Count -gt 0) {
        Write-Host '  最近 3 条事件：'
        $events | Select-Object -Last 3 | ForEach-Object { Write-Host ('    ' + $_) }
    }
} else {
    Check 'events.log 存在' $false $eventsPath
}

$launcherLogPath = Join-Path $stateDir 'launcher.log'
if (Test-Path -LiteralPath $launcherLogPath -PathType Leaf) {
    Write-Host '  最近 3 条启动器日志：'
    Get-Content -LiteralPath $launcherLogPath -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 3 | ForEach-Object { Write-Host ('    ' + $_) }
}

if (-not [string]::IsNullOrWhiteSpace($OpenFolder)) {
    Write-Host ''
    Write-Host '== 6. 真实打开链路自检（-OpenFolder）==' -ForegroundColor Cyan
    $openFolder = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OpenFolder.Trim().Trim('"')))
    Check '目标文件夹存在' (Test-Path -LiteralPath $openFolder -PathType Container) $openFolder
    if ((Test-Path -LiteralPath $launcherExe -PathType Leaf) -and (Test-Path -LiteralPath $openFolder -PathType Container)) {
        $before = 0
        if (Test-Path -LiteralPath $eventsPath -PathType Leaf) { $before = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8).Count }
        Write-Host ("  调用启动器打开：{0}" -f $openFolder)
        $arguments = @(('"' + $openFolder + '"'), '--no-activate', '--no-dialog')
        $launcherProcess = Start-Process -FilePath $launcherExe -ArgumentList $arguments -PassThru -Wait
        Check '启动器退出码为 0' ([int]$launcherProcess.ExitCode -eq 0) ("exit=" + $launcherProcess.ExitCode)
        $deadline = (Get-Date).AddSeconds(20)
        $opened = $false
        $newEvents = @()
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $eventsPath -PathType Leaf) {
                $all = @(Get-Content -LiteralPath $eventsPath -Encoding UTF8)
                if ($all.Count -gt $before) { $newEvents = @($all | Select-Object -Skip $before) }
                $newAck = @($newEvents | Where-Object { $_ -match '"stage":"opened"' })
                if ($newAck.Count -gt 0) { $opened = $true; break }
            }
            Start-Sleep -Milliseconds 500
        }
        Check '出现 request-queued' (@($newEvents | Where-Object { $_ -match '"event":"request-queued"' }).Count -gt 0)
        Check '客户端领取 pending-claimed' (@($newEvents | Where-Object { $_ -match '"event":"pending-claimed"' }).Count -gt 0)
        Check '工作区打开成功 ack opened' $opened
        foreach ($line in $newEvents) { Write-Host ('    ' + $line) }
    }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
if ($script:Fail -eq 0) {
    Write-Host (" 自检结果：全部通过（{0} 项检查，{1} 条警告）" -f $script:Pass, $script:Warn) -ForegroundColor Green
    Write-Host ' 提示：右键文件夹 →「在 DeepSeek Harness 中打开」（Win11 若主菜单没有，点「显示更多选项」）。' -ForegroundColor Green
} else {
    Write-Host (" 自检结果：{0} 项失败 / {1} 项通过 / {2} 条警告" -f $script:Fail, $script:Pass, $script:Warn) -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host ('   - ' + $failure) -ForegroundColor Red }
    Write-Host ' 建议：先运行 install.ps1 修复安装；仍失败请把本输出与 %DSH_HOME%\open-in-folder\events.log 发给开发者。' -ForegroundColor Yellow
}
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

if ($script:Fail -gt 0) { exit 1 }
exit 0
