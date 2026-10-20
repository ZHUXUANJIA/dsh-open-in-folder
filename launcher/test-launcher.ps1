# test-launcher.ps1
# DSHOpenInFolder.exe 自动化自测：用 System.Net.HttpListener 起本地 mock Host，
# 覆盖成功路径 / token 不匹配(400) / 目录不存在 / 相对路径 / health 不可达 /
# state 过期(端口已关闭) / 成功后触发聚焦 / 盘符根路径 / 末尾反斜杠规范化 共 9 个场景。
#
# 用法：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\test-launcher.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\test-launcher.ps1 -KeepTemp
#
# 可选参数：
#   -LauncherExe <path>  指定被测 exe（默认 <本脚本目录>\DSHOpenInFolder.exe，不存在则先编译）
#   -SkipBuild           不改编译，直接用现有 exe
#   -KeepTemp            保留临时测试目录（排障用）
#
# 退出码：0 全部 PASS；1 有 FAIL 或测试脚本自身异常。

[CmdletBinding()]
param(
    [string]$LauncherExe,
    [switch]$SkipBuild,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
$script:CheckCount = 0
$script:FailureCount = 0
$script:Requests = New-Object System.Collections.ArrayList
$script:MockExpectedToken = $null
$script:MockPostMode = 'ok'
$script:TestRoot = $null

# ---------------------------------------------------------------- 输出/断言

function Write-Scenario {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Add-CheckResult {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $script:CheckCount++
    if ($Passed) {
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:FailureCount++
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
    if ($null -eq $Expected -and $null -eq $Actual) { $passed = $true }
    elseif ($null -ne $Expected -and $null -ne $Actual) { $passed = ($Expected -eq $Actual) }
    Add-CheckResult -Name $Name -Passed $passed -Detail ("期望 [" + [string]$Expected + "]，实际 [" + [string]$Actual + "]")
}

# ---------------------------------------------------------------- 基础工具

function Get-PowerShellExe {
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    return 'powershell.exe'
}

function Invoke-BuildLauncher {
    param([string]$Source, [string]$OutFile)
    $buildScript = Join-Path $PSScriptRoot 'build-launcher.ps1'
    if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
        throw "缺少 build-launcher.ps1：$buildScript"
    }
    $psExe = Get-PowerShellExe
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $buildScript,
        '-Source', $Source, '-OutFile', $OutFile, '-Quiet'
    )
    & $psExe @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "编译失败（build-launcher.ps1 退出码 $LASTEXITCODE）：$OutFile"
    }
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        throw "编译未生成文件：$OutFile"
    }
}

function Quote-Argument {
    param([string]$Value)
    if ($null -eq $Value) {
        return '""'
    }
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

function Build-LauncherArguments {
    param([string]$Folder, [string[]]$ExtraArgs)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add((Quote-Argument $Folder))
    if ($null -ne $ExtraArgs) {
        foreach ($argument in $ExtraArgs) {
            [void]$parts.Add((Quote-Argument ([string]$argument)))
        }
    }
    return ($parts -join ' ')
}

function Wait-ForFile {
    param([string]$Path, [int]$TimeoutMilliseconds = 5000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return (Test-Path -LiteralPath $Path)
}

# ---------------------------------------------------------------- mock Host

function New-MockListener {
    $lastError = $null
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $port = Get-Random -Minimum 32000 -Maximum 60000
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$port/")
        try {
            $listener.Start()
            return [pscustomobject]@{ Listener = $listener; Port = $port }
        } catch {
            $lastError = $_.Exception.Message
            try { $listener.Close() } catch { }
        }
    }
    throw "无法启动 mock HttpListener（127.0.0.1 随机端口）：$lastError"
}

function Close-MockListener {
    param($Mock)
    if ($null -eq $Mock) {
        return
    }
    try { $Mock.Listener.Stop() } catch { }
    try { $Mock.Listener.Close() } catch { }
}

function Get-UnusedTcpPort {
    $tcpListener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $tcpListener.Start()
    $port = ([System.Net.IPEndPoint]$tcpListener.LocalEndpoint).Port
    $tcpListener.Stop()
    return $port
}

function Write-MockResponse {
    param($Context, [int]$StatusCode, [string]$JsonText)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($JsonText)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    try { $Context.Response.OutputStream.Close() } catch { }
    try { $Context.Response.Close() } catch { }
}

function Write-MockJsonError {
    param($Context, [int]$StatusCode, [string]$Message)
    $payload = @{ ok = $false; error = $Message } | ConvertTo-Json -Compress
    Write-MockResponse -Context $Context -StatusCode $StatusCode -JsonText $payload
}

function Handle-MockRequest {
    param($Context)
    $path = $Context.Request.Url.AbsolutePath
    $method = $Context.Request.HttpMethod
    $bodyText = ''
    if ($Context.Request.HasEntityBody) {
        $memory = New-Object System.IO.MemoryStream
        try {
            $Context.Request.InputStream.CopyTo($memory)
            $bodyText = [System.Text.Encoding]::UTF8.GetString($memory.ToArray())
        } finally {
            $memory.Dispose()
        }
    }
    $token = $Context.Request.Headers['X-DSH-Open-In-Folder-Token']
    $bodyJson = $null
    if (-not [string]::IsNullOrEmpty($bodyText)) {
        try { $bodyJson = $bodyText | ConvertFrom-Json } catch { $bodyJson = $null }
    }

    $record = [pscustomobject]@{
        Method      = $method
        Path        = $path
        Token       = $token
        ContentType = $Context.Request.ContentType
        Body        = $bodyText
        Json        = $bodyJson
    }
    [void]$script:Requests.Add($record)

    try {
        if ($path -eq '/dsh-open-in-folder/health') {
            Write-MockResponse -Context $Context -StatusCode 200 -JsonText '{"ok":true,"pid":4242,"version":"mock-test"}'
            return
        }
        if ($path -eq '/dsh-open-in-folder/request' -and $method -eq 'POST') {
            if ($null -eq $bodyJson -or $null -eq $bodyJson.path) {
                Write-MockJsonError -Context $Context -StatusCode 400 -Message 'mock: 请求 body 不是合法 JSON 或缺少 path'
                return
            }
            if ($script:MockPostMode -eq 'reject-path') {
                Write-MockJsonError -Context $Context -StatusCode 400 -Message 'mock: 路径不存在（测试用拒绝）'
                return
            }
            if ([string]$token -ne [string]$script:MockExpectedToken) {
                Write-MockJsonError -Context $Context -StatusCode 400 -Message 'invalid token'
                return
            }
            $okBody = @{
                ok        = $true
                requestId = 'mock-request-0001'
                path      = [string]$bodyJson.path
            } | ConvertTo-Json -Compress
            Write-MockResponse -Context $Context -StatusCode 200 -JsonText $okBody
            return
        }
        Write-MockJsonError -Context $Context -StatusCode 404 -Message 'mock: 未知路由'
    } catch {
        # 客户端可能已断开，忽略。
    }
}

# ---------------------------------------------------------------- 运行被测程序

function Invoke-Launcher {
    param(
        [string]$Folder,
        [string[]]$ExtraArgs,
        $Mock,
        [string]$ExpectedToken,
        [int]$WaitTimeoutSeconds = 60
    )
    $script:Requests = New-Object System.Collections.ArrayList
    $script:MockExpectedToken = $ExpectedToken

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:LauncherExe
    $startInfo.Arguments = Build-LauncherArguments -Folder $Folder -ExtraArgs $ExtraArgs
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $script:TestRoot
    $process = [System.Diagnostics.Process]::Start($startInfo)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pending = $null
    if ($null -ne $Mock) {
        $pending = $Mock.Listener.BeginGetContext($null, $null)
    }
    $killed = $false
    while (-not $process.HasExited) {
        if ($stopwatch.Elapsed.TotalSeconds -gt $WaitTimeoutSeconds) {
            $killed = $true
            break
        }
        if ($null -ne $pending) {
            if ($pending.AsyncWaitHandle.WaitOne(30)) {
                $context = $null
                try { $context = $Mock.Listener.EndGetContext($pending) } catch { }
                try { $pending = $Mock.Listener.BeginGetContext($null, $null) } catch { $pending = $null }
                if ($null -ne $context) {
                    Handle-MockRequest -Context $context
                }
            }
        } else {
            Start-Sleep -Milliseconds 20
        }
    }
    if ($killed) {
        try { $process.Kill() } catch { }
    }
    try { $process.WaitForExit(5000) | Out-Null } catch { }
    $stopwatch.Stop()

    $exitCode = $null
    if (-not $killed) {
        try { $exitCode = $process.ExitCode } catch { $exitCode = $null }
    }
    Close-MockListener -Mock $Mock

    return [pscustomobject]@{
        ExitCode       = $exitCode
        ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
        Killed         = $killed
        Arguments      = $startInfo.Arguments
    }
}

function Write-StateFile {
    param([string]$StateDir, [int]$Port, [string]$Token, [string]$StateHost = '127.0.0.1')
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $json = '{"schema":1,"pid":4242,"port":' + $Port + ',"host":"' + $StateHost + '","token":"' + $Token + '","startedAt":"2026-10-20T13:00:00.000Z","pluginVersion":"0.1.0"}'
    $statePath = Join-Path $StateDir 'state.json'
    [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function New-ScenarioDirectory {
    param([string]$Name)
    $directory = Join-Path $script:TestRoot $Name
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function New-TargetFolder {
    param([string]$Name)
    $folder = Join-Path $script:TestRoot $Name
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }
    return $folder
}

# ---------------------------------------------------------------- 准备环境

function Initialize-TestEnvironment {
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dsh-open-in-folder-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    Write-Host "临时目录：$script:TestRoot" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($LauncherExe)) {
        $script:LauncherExe = Join-Path $PSScriptRoot 'DSHOpenInFolder.exe'
        $source = Join-Path $PSScriptRoot 'DSHOpenInFolder.cs'
        if (-not $SkipBuild -or -not (Test-Path -LiteralPath $script:LauncherExe -PathType Leaf)) {
            Write-Host '[准备] 编译 launcher …'
            Invoke-BuildLauncher -Source $source -OutFile $script:LauncherExe
        }
    } else {
        if (-not (Test-Path -LiteralPath $LauncherExe -PathType Leaf)) {
            throw "指定的 -LauncherExe 不存在：$LauncherExe"
        }
        $script:LauncherExe = (Resolve-Path -LiteralPath $LauncherExe).Path
    }
    if (-not (Test-Path -LiteralPath $script:LauncherExe -PathType Leaf)) {
        throw "被测启动器不存在：$script:LauncherExe"
    }
    Write-Host "被测 exe：$script:LauncherExe" -ForegroundColor DarkGray

    # 测试用「无害假 DSH 应用」：被启动时写 witness 文件（用于断言启动/聚焦行为）。
    $noopSource = Join-Path $script:TestRoot 'NoopApp.cs'
    $noopCode = @'
using System;
using System.IO;

internal static class NoopApp
{
    private static void Main()
    {
        try
        {
            string witness = Environment.GetEnvironmentVariable("DSH_TEST_NOOP_WITNESS");
            if (!string.IsNullOrEmpty(witness))
            {
                File.WriteAllText(witness, DateTime.UtcNow.ToString("o"));
            }
        }
        catch
        {
        }
    }
}
'@
    [System.IO.File]::WriteAllText($noopSource, $noopCode, (New-Object System.Text.UTF8Encoding($true)))
    $script:NoopAppExe = Join-Path $script:TestRoot 'NoopApp.exe'
    Invoke-BuildLauncher -Source $noopSource -OutFile $script:NoopAppExe
}

# ---------------------------------------------------------------- 测试场景

function Test-SuccessPath {
    Write-Scenario '场景 1：成功路径（health OK → POST 成功 → 静默退出 0）'
    $scenarioDir = New-ScenarioDirectory 'scenario-1-success'
    $mock = New-MockListener
    $token = 'success-' + [guid]::NewGuid().ToString('N')
    Write-StateFile -StateDir $scenarioDir -Port $mock.Port -Token $token
    $folder = New-TargetFolder '工作区 中文 名称'
    $missingApp = Join-Path $script:TestRoot 'no-such-dsh-app.exe'
    $result = Invoke-Launcher -Folder $folder `
        -ExtraArgs @('--state-dir', $scenarioDir, '--no-activate', '--app', $missingApp) `
        -Mock $mock -ExpectedToken $token

    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 0' 0 $result.ExitCode
    Assert-True '耗时合理（< 20 秒）' ($result.ElapsedSeconds -lt 20) ("实际 " + [math]::Round($result.ElapsedSeconds, 2) + " 秒")

    $posts = @($script:Requests | Where-Object { $_.Method -eq 'POST' })
    $healths = @($script:Requests | Where-Object { $_.Path -eq '/dsh-open-in-folder/health' })
    Assert-Equal '收到 1 个 POST 请求' 1 $posts.Count
    Assert-True '至少收到 1 个 health 请求' ($healths.Count -ge 1) ("实际 " + $healths.Count)
    if ($posts.Count -ge 1) {
        $post = $posts[0]
        Assert-Equal 'POST 路径正确' '/dsh-open-in-folder/request' $post.Path
        Assert-Equal 'POST token 请求头正确' $token ([string]$post.Token)
        Assert-Equal 'POST JSON path 与中文文件夹完全一致' $folder ([string]$post.Json.path)
        Assert-True 'Content-Type 为 application/json' ((($post.ContentType) -as [string]) -like 'application/json*') ("实际 [" + [string]$post.ContentType + "]")
    }
    Assert-True 'health 已成功时不会启动 --app 指定的（不存在）应用（无事件可断，仅确认快速成功）' ($result.ElapsedSeconds -lt 20)
}

function Test-TokenMismatch {
    Write-Scenario '场景 2：token 不匹配（mock 返回 400 → 退出码非 0，且不重试等待）'
    $scenarioDir = New-ScenarioDirectory 'scenario-2-bad-token'
    $mock = New-MockListener
    $expectedToken = 'correct-' + [guid]::NewGuid().ToString('N')
    $wrongToken = 'wrong-' + [guid]::NewGuid().ToString('N')
    Write-StateFile -StateDir $scenarioDir -Port $mock.Port -Token $wrongToken
    $folder = New-TargetFolder 'scenario-2-target'
    $result = Invoke-Launcher -Folder $folder `
        -ExtraArgs @('--state-dir', $scenarioDir, '--no-activate', '--no-dialog') `
        -Mock $mock -ExpectedToken $expectedToken

    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-True '退出码非 0（4xx 立即失败）' ($null -ne $result.ExitCode -and $result.ExitCode -ne 0) ("实际 [" + [string]$result.ExitCode + "]")
    Assert-True '4xx 不重试：耗时应 < 20 秒' ($result.ElapsedSeconds -lt 20) ("实际 " + [math]::Round($result.ElapsedSeconds, 2) + " 秒")

    $posts = @($script:Requests | Where-Object { $_.Method -eq 'POST' })
    Assert-Equal '收到 1 个 POST 请求（未无限重试）' 1 $posts.Count
    if ($posts.Count -ge 1) {
        Assert-Equal 'POST 携带 state.json 中的（错误）token' $wrongToken ([string]$posts[0].Token)
    }
}

function Test-MissingFolder {
    Write-Scenario '场景 3：文件夹不存在（退出码 2，快速失败）'
    $scenarioDir = New-ScenarioDirectory 'scenario-3-missing'
    $missingFolder = Join-Path $script:TestRoot ('missing-folder-' + [guid]::NewGuid().ToString('N'))
    $result = Invoke-Launcher -Folder $missingFolder `
        -ExtraArgs @('--state-dir', $scenarioDir, '--no-dialog') -Mock $null -ExpectedToken $null
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 2' 2 $result.ExitCode
    Assert-True '快速失败（< 10 秒）' ($result.ElapsedSeconds -lt 10) ("实际 " + [math]::Round($result.ElapsedSeconds, 2) + " 秒")
}

function Test-RelativeFolder {
    Write-Scenario '场景 4：相对路径（退出码 2）'
    $result = Invoke-Launcher -Folder 'relative\folder' -ExtraArgs @('--no-dialog') -Mock $null -ExpectedToken $null
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 2' 2 $result.ExitCode
}

function Test-HealthUnreachable {
    Write-Scenario '场景 5：health 不可达（启动假应用后短超时等待，退出码 1）'
    $scenarioDir = New-ScenarioDirectory 'scenario-5-no-plugin'
    $witness = Join-Path $scenarioDir 'app-started.txt'
    $folder = New-TargetFolder 'scenario-5-target'
    $env:DSH_TEST_NOOP_WITNESS = $witness
    try {
        $result = Invoke-Launcher -Folder $folder `
            -ExtraArgs @('--state-dir', $scenarioDir, '--app', $script:NoopAppExe, '--timeout', '3', '--no-dialog') `
            -Mock $null -ExpectedToken $null
    } finally {
        Remove-Item Env:\DSH_TEST_NOOP_WITNESS -ErrorAction SilentlyContinue
    }
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 1' 1 $result.ExitCode
    Assert-True '--timeout 3 生效（耗时不接近 90 秒）' ($result.ElapsedSeconds -ge 2.0 -and $result.ElapsedSeconds -lt 30) ("实际 " + [math]::Round($result.ElapsedSeconds, 2) + " 秒")
    Assert-True '启动过假 DSH 应用（witness 文件存在）' (Wait-ForFile -Path $witness -TimeoutMilliseconds 5000)
}

function Test-StaleState {
    Write-Scenario '场景 6：state.json 过期（端口已关闭 → 启动应用并短超时等待，退出码 1）'
    $scenarioDir = New-ScenarioDirectory 'scenario-6-stale'
    $deadPort = Get-UnusedTcpPort
    Write-StateFile -StateDir $scenarioDir -Port $deadPort -Token 'stale-token'
    $witness = Join-Path $scenarioDir 'app-started.txt'
    $folder = New-TargetFolder 'scenario-6-target'
    $env:DSH_TEST_NOOP_WITNESS = $witness
    try {
        $result = Invoke-Launcher -Folder $folder `
            -ExtraArgs @('--state-dir', $scenarioDir, '--app', $script:NoopAppExe, '--timeout', '3', '--no-dialog') `
            -Mock $null -ExpectedToken $null
    } finally {
        Remove-Item Env:\DSH_TEST_NOOP_WITNESS -ErrorAction SilentlyContinue
    }
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 1' 1 $result.ExitCode
    Assert-True '短超时生效（< 30 秒）' ($result.ElapsedSeconds -ge 2.0 -and $result.ElapsedSeconds -lt 30) ("实际 " + [math]::Round($result.ElapsedSeconds, 2) + " 秒")
    Assert-True '启动过假 DSH 应用（witness 文件存在）' (Wait-ForFile -Path $witness -TimeoutMilliseconds 5000)
}

function Test-SuccessActivate {
    Write-Scenario '场景 7：成功后触发单实例聚焦（DSH 启动前已在运行 → 再次启动应用）'
    $scenarioDir = New-ScenarioDirectory 'scenario-7-activate'
    $mock = New-MockListener
    $token = 'activate-' + [guid]::NewGuid().ToString('N')
    Write-StateFile -StateDir $scenarioDir -Port $mock.Port -Token $token
    $witness = Join-Path $scenarioDir 'focus-started.txt'
    $folder = New-TargetFolder 'scenario-7-target'
    $env:DSH_TEST_NOOP_WITNESS = $witness
    try {
        $result = Invoke-Launcher -Folder $folder `
            -ExtraArgs @('--state-dir', $scenarioDir, '--app', $script:NoopAppExe) `
            -Mock $mock -ExpectedToken $token
    } finally {
        Remove-Item Env:\DSH_TEST_NOOP_WITNESS -ErrorAction SilentlyContinue
    }
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 0' 0 $result.ExitCode
    $posts = @($script:Requests | Where-Object { $_.Method -eq 'POST' })
    Assert-Equal '收到 1 个 POST 请求' 1 $posts.Count
    Assert-True '成功静默不弹成功框（进程正常退出）' (-not $result.Killed)
    Assert-True '成功后再次启动 DSH 应用以触发聚焦（witness 文件存在）' (Wait-ForFile -Path $witness -TimeoutMilliseconds 5000)
}

function Test-DriveRootPath {
    Write-Scenario '场景 8：盘符根目录（C:\）规范化与 JSON 转义'
    $scenarioDir = New-ScenarioDirectory 'scenario-8-drive-root'
    $mock = New-MockListener
    $token = 'drive-root-' + [guid]::NewGuid().ToString('N')
    Write-StateFile -StateDir $scenarioDir -Port $mock.Port -Token $token
    $result = Invoke-Launcher -Folder 'C:\' `
        -ExtraArgs @('--state-dir', $scenarioDir, '--no-activate') `
        -Mock $mock -ExpectedToken $token
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 0' 0 $result.ExitCode
    $posts = @($script:Requests | Where-Object { $_.Method -eq 'POST' })
    Assert-Equal '收到 1 个 POST 请求' 1 $posts.Count
    if ($posts.Count -ge 1) {
        Assert-Equal '盘符根路径保持为 C:\（不丢末尾分隔符）' 'C:\' ([string]$posts[0].Json.path)
    }
}

function Test-TrailingSlashNormalization {
    Write-Scenario '场景 9：末尾反斜杠规范化（普通目录去掉末尾 \）'
    $scenarioDir = New-ScenarioDirectory 'scenario-9-trailing-slash'
    $mock = New-MockListener
    $token = 'trailing-' + [guid]::NewGuid().ToString('N')
    Write-StateFile -StateDir $scenarioDir -Port $mock.Port -Token $token
    $folder = New-TargetFolder 'scenario-9-target'
    $result = Invoke-Launcher -Folder ($folder + '\') `
        -ExtraArgs @('--state-dir', $scenarioDir, '--no-activate') `
        -Mock $mock -ExpectedToken $token
    Assert-Equal '未超时（进程自行退出）' $false $result.Killed
    Assert-Equal '退出码为 0' 0 $result.ExitCode
    $posts = @($script:Requests | Where-Object { $_.Method -eq 'POST' })
    Assert-Equal '收到 1 个 POST 请求' 1 $posts.Count
    if ($posts.Count -ge 1) {
        Assert-Equal 'POST JSON path 已去掉末尾反斜杠' $folder ([string]$posts[0].Json.path)
    }
}

# ---------------------------------------------------------------- 主流程

$exitCode = 0
try {
    Write-Host ''
    Write-Host '############################################################' -ForegroundColor Cyan
    Write-Host '#  DSHOpenInFolder.exe 自测（HttpListener mock Host）       #' -ForegroundColor Cyan
    Write-Host '############################################################' -ForegroundColor Cyan

    Initialize-TestEnvironment
    Test-SuccessPath
    Test-TokenMismatch
    Test-MissingFolder
    Test-RelativeFolder
    Test-HealthUnreachable
    Test-StaleState
    Test-SuccessActivate
    Test-DriveRootPath
    Test-TrailingSlashNormalization

    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($script:FailureCount -eq 0) {
        Write-Host ("  自测结果：全部 PASS（{0} 项检查）" -f $script:CheckCount) -ForegroundColor Green
        Write-Host '============================================================' -ForegroundColor Cyan
        $exitCode = 0
    } else {
        Write-Host ("  自测结果：{0} 项 FAIL / 共 {1} 项检查" -f $script:FailureCount, $script:CheckCount) -ForegroundColor Red
        Write-Host '============================================================' -ForegroundColor Cyan
        $exitCode = 1
    }
} catch {
    Write-Host ''
    Write-Host "  [FAIL] 测试脚本自身异常：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 1
} finally {
    if ($null -ne $script:TestRoot -and (Test-Path -LiteralPath $script:TestRoot)) {
        if ($KeepTemp) {
            Write-Host "临时目录已保留：$script:TestRoot" -ForegroundColor Yellow
        } else {
            try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Stop } catch {
                Write-Host "清理临时目录失败（可忽略）：$script:TestRoot" -ForegroundColor Yellow
            }
        }
    }
}
exit $exitCode
