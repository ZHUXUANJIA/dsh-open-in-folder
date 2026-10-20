<#
.SYNOPSIS
  安装 DeepSeek Harness「右键打开文件夹」集成（资源管理器右键菜单 + 启动器 + DSH 插件）。

.DESCRIPTION
  做的事情（幂等，可安全重复运行）：
    1. 解析 DSH_HOME 与 DeepSeek Harness.exe 路径（并检测 DSH 是否正在运行，仅提示不阻塞）；
    2. 预检插件源：必需文件（package.json / cordis.patch.yml / lib/index.js）、manifest、
       dsh.bundle.patch、dsh.client 的 exports["./client"] 与 client bundle、node --check 语法。
       该步骤【在产生任何副作用之前】完成：插件声明了 dsh.client 而 client bundle 缺失/损坏
       会让整个 DSH 应用无法启动，所以校验失败直接终止，不做任何修改；
    3. 复制插件到 %DSH_HOME%\plugins\dsh-open-in-folder；
    4. 用 .NET Framework 4.8 的 csc 编译启动器到 <插件目录>\launcher\DSHOpenInFolder.exe；
    5. 写入 %DSH_HOME%\open-in-folder\app-path.txt（供启动器定位 DSH 应用）；
    6. 在 profile 的 node_modules 下建立 junction → 插件目录；
    7. 修改 profile package.json（dependencies + dsh.profile.bundles），首次修改前自动备份；
    8. 提取图标并注册 HKCU 右键菜单（文件夹 / 文件夹空白处 / 盘符）；
    9. 输出中文摘要。

  注意：本脚本【不会】重启或关闭正在运行的 DeepSeek Harness。
        检测到 DSH 正在运行时只输出提示：新版 DSH 通常热加载插件、安装后一般立即生效；
        若未生效，请完全退出 DSH（含系统托盘）后重新打开。

.PARAMETER AppExe
  DeepSeek Harness.exe 的绝对路径。省略时依次尝试：环境变量 DSH_APP_EXE、
  %DSH_HOME%\open-in-folder\app-path.txt、注册表 HKCU\Software\Classes\dsh\shell\open\command。

.PARAMETER PluginSource
  插件源目录，默认 <本脚本目录>\plugin。

.PARAMETER Profile
  DSH profile 名称，默认 desktop。

.PARAMETER RegistryRoot
  注册表根路径（HKCU 下），默认 Software\Classes。
  仅高级/测试使用：指向测试根可避免改动真实右键菜单。

.PARAMETER NoRegistry
  跳过图标提取与 HKCU 右键菜单注册。

.PARAMETER NoLauncher
  跳过启动器编译（已在别处编译好或仅演练安装流程时使用）。

.PARAMETER Quiet
  减少过程输出（仍输出摘要、警告与错误）。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1 -AppExe "D:\你的安装路径\DeepSeek Harness.exe" -NoRegistry

.NOTES
  退出码：0 成功；1 失败。
#>

[CmdletBinding()]
param(
    [string]$AppExe,
    [string]$PluginSource,
    [string]$Profile = 'desktop',
    [string]$RegistryRoot,
    [switch]$NoRegistry,
    [switch]$NoLauncher,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Quiet = [bool]$Quiet
$script:Actions = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList
if ([string]::IsNullOrWhiteSpace($RegistryRoot)) {
    $RegistryRoot = 'Software\Classes'
}
$RegistryRoot = $RegistryRoot.Trim().Trim('\')

# =====================================================================
# 输出辅助
# =====================================================================

function Write-Step {
    param([string]$Message)
    if (-not $script:Quiet) {
        Write-Host ''
        Write-Host "==> $Message" -ForegroundColor Cyan
    }
}

function Write-Detail {
    param([string]$Message)
    if (-not $script:Quiet) {
        Write-Host "    $Message" -ForegroundColor DarkGray
    }
}

function Write-Ok {
    param([string]$Message)
    [void]$script:Actions.Add($Message)
    if (-not $script:Quiet) {
        Write-Host "    [OK] $Message" -ForegroundColor Green
    }
}

function Write-Warn {
    param([string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-Host "    [警告] $Message" -ForegroundColor Yellow
}

# =====================================================================
# 路径 / 环境解析
# =====================================================================

function Get-DshHomePath {
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($env:DSH_HOME.Trim().Trim('"'))
        return [System.IO.Path]::GetFullPath($expanded)
    }
    $userProfile = [Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrEmpty($userProfile)) {
        throw '无法确定用户目录（USERPROFILE 为空），请设置 DSH_HOME 环境变量后重试。'
    }
    return (Join-Path $userProfile '.dsh')
}

function ConvertFrom-CommandLineToExe {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }
    $text = $CommandLine.Trim()
    $exe = $null
    if ($text.StartsWith('"')) {
        $end = $text.IndexOf('"', 1)
        if ($end -gt 1) {
            $exe = $text.Substring(1, $end - 1)
        }
    } else {
        $space = $text.IndexOf(' ')
        if ($space -gt 0) {
            $exe = $text.Substring(0, $space)
        } else {
            $exe = $text
        }
    }
    if ([string]::IsNullOrWhiteSpace($exe)) {
        return $null
    }
    return [Environment]::ExpandEnvironmentVariables($exe.Trim().Trim('"'))
}

function Get-RegistryAppExePath {
    try {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Classes\dsh\shell\open\command', $false)
        if ($null -eq $key) {
            return $null
        }
        try {
            $commandLine = [string]$key.GetValue($null)
        } finally {
            $key.Close()
        }
        return (ConvertFrom-CommandLineToExe -CommandLine $commandLine)
    } catch {
        return $null
    }
}

function Resolve-DshAppExe {
    param([string]$ExplicitPath, [string]$StateDirectory)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ExplicitPath.Trim().Trim('"'))
        if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
            throw "指定的 -AppExe 不存在或不是文件：$expanded"
        }
        return (Resolve-Path -LiteralPath $expanded).Path
    }

    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_APP_EXE)) {
        [void]$candidates.Add($env:DSH_APP_EXE)
    }
    if (-not [string]::IsNullOrWhiteSpace($StateDirectory)) {
        $appPathFile = Join-Path $StateDirectory 'app-path.txt'
        if (Test-Path -LiteralPath $appPathFile -PathType Leaf) {
            try {
                $firstLine = Get-Content -LiteralPath $appPathFile -TotalCount 1 -Encoding UTF8 -ErrorAction Stop
                if (-not [string]::IsNullOrWhiteSpace([string]$firstLine)) {
                    [void]$candidates.Add([string]$firstLine)
                }
            } catch {
                # 读取失败则继续其他候选。
            }
        }
    }
    $registryExe = Get-RegistryAppExePath
    if (-not [string]::IsNullOrWhiteSpace($registryExe)) {
        [void]$candidates.Add($registryExe)
    }

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim().Trim('"'))
        } catch {
            continue
        }
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            return (Resolve-Path -LiteralPath $expanded).Path
        }
    }
    return $null
}

function Get-PowerShellExePath {
    try {
        $current = (Get-Process -Id $PID -ErrorAction Stop).Path
        if (-not [string]::IsNullOrWhiteSpace($current) -and (Split-Path -Leaf $current) -ieq 'powershell.exe') {
            return $current
        }
    } catch {
        # 忽略。
    }
    $candidate = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }
    return 'powershell.exe'
}

# =====================================================================
# 文件 / 目录
# =====================================================================

function Copy-DirectoryTree {
    param([string]$SourcePath, [string]$DestinationPath)
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    $items = Get-ChildItem -LiteralPath $SourcePath -Force
    foreach ($item in $items) {
        $targetPath = Join-Path $DestinationPath $item.Name
        if ($item.PSIsContainer) {
            Copy-DirectoryTree -SourcePath $item.FullName -DestinationPath $targetPath
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $targetPath -Force -ErrorAction Stop
        }
    }
}

function Invoke-LauncherBuild {
    param([string]$BuildScript, [string]$Source, [string]$OutFile)
    if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
        throw "缺少启动器编译脚本：$BuildScript"
    }
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "缺少启动器源码：$Source"
    }
    $powerShellExe = Get-PowerShellExePath
    $buildArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $BuildScript,
        '-Source', $Source, '-OutFile', $OutFile
    )
    if ($script:Quiet) {
        $buildArguments += '-Quiet'
    }
    & $powerShellExe @buildArguments
    $buildExitCode = $LASTEXITCODE
    if ($buildExitCode -ne 0) {
        throw "编译启动器失败（build-launcher.ps1 退出码 $buildExitCode）。"
    }
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        throw "编译命令成功但未生成启动器：$OutFile"
    }
}

# =====================================================================
# junction / reparse point
# =====================================================================

function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Remove-PathRobust {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (Test-IsReparsePoint -Path $Path) {
        # 只删除链接本身，绝不递归删除目标内容。
        try {
            [System.IO.Directory]::Delete($Path, $false)
            return
        } catch {
            # 继续尝试备用方案。
        }
        try {
            (Get-Item -LiteralPath $Path -Force).Delete()
            return
        } catch {
            # 继续。
        }
        throw "无法删除链接：$Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

function Set-PluginJunction {
    param([string]$LinkPath, [string]$TargetPath)
    $parent = Split-Path -Parent $LinkPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $LinkPath) {
        $existing = Get-Item -LiteralPath $LinkPath -Force
        if (($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Remove-PathRobust -Path $LinkPath
            Write-Detail "已删除旧的 node_modules 链接：$LinkPath"
        } elseif ($existing.PSIsContainer) {
            $backupPath = $LinkPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $LinkPath -Destination $backupPath -Force -ErrorAction Stop
            Write-Warn "node_modules\dsh-open-in-folder 已存在且为普通目录，已移动为备份：$backupPath"
        } else {
            Remove-Item -LiteralPath $LinkPath -Force -ErrorAction Stop
        }
    }
    New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath -ErrorAction Stop | Out-Null
    $created = Get-Item -LiteralPath $LinkPath -Force
    if (($created.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "创建 junction 失败（未生成链接）：$LinkPath"
    }
    return $created
}

# =====================================================================
# 插件源预检（必须在产生任何副作用之前全部通过）
#    研究结论（research/install-and-client-loading.md §2.3/§4.1）：
#    插件一旦声明 dsh.client，若 client bundle 缺失/声明非法，client-modules
#    构造会抛错并连 required 条目一起拖死 → 整个 DSH 应用无法启动。
#    因此这里做硬校验：manifest、bundle patch、client bundle、JS 语法。
# =====================================================================

function Get-Utf8BomState {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Resolve-ExportTargetValue {
    param($Value)
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace([string]$Value)) {
            return $null
        }
        return [string]$Value
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        foreach ($item in $Value) {
            $resolved = Resolve-ExportTargetValue -Value $item
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                return $resolved
            }
        }
        return $null
    }
    foreach ($key in @('default', 'import', 'require', 'node', 'module')) {
        $child = Get-ObjectPropertyValue -Object $Value -Name $key
        if ($null -ne $child) {
            $resolved = Resolve-ExportTargetValue -Value $child
            if (-not [string]::IsNullOrWhiteSpace($resolved)) {
                return $resolved
            }
        }
    }
    return $null
}

function Resolve-ManifestRelativePath {
    param([string]$PluginSourcePath, [string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        return $null
    }
    $normalized = $RelativePath.Trim()
    if ($normalized.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(5)
    }
    $normalized = $normalized -replace '/', '\'
    if ([System.IO.Path]::IsPathRooted($normalized)) {
        $fullPath = [System.IO.Path]::GetFullPath($normalized)
    } else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $PluginSourcePath $normalized))
    }
    $sourceRoot = [System.IO.Path]::GetFullPath($PluginSourcePath).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($sourceRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "插件 package.json 中声明的路径越界（不在插件源目录内）：$RelativePath"
    }
    return $fullPath
}

function Find-NodeExecutable {
    param([string]$AppExePath, [string]$DshHomePath)
    # 1) PATH 上的 node
    try {
        $nodeCommand = Get-Command -Name 'node' -CommandType Application -ErrorAction Stop
        if ($null -ne $nodeCommand -and -not [string]::IsNullOrWhiteSpace($nodeCommand.Source) -and (Test-Path -LiteralPath $nodeCommand.Source -PathType Leaf)) {
            return $nodeCommand.Source
        }
    } catch {
        # 继续按固定位置查找。
    }
    # 2) Program Files 下的 node
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        [void]$candidates.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe'))
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        [void]$candidates.Add((Join-Path $programFilesX86 'nodejs\node.exe'))
    }
    # 3) DSH 应用自带 runtime 的 node
    if (-not [string]::IsNullOrWhiteSpace($AppExePath)) {
        $appDirectory = Split-Path -Parent $AppExePath
        if (-not [string]::IsNullOrWhiteSpace($appDirectory)) {
            [void]$candidates.Add((Join-Path $appDirectory 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'))
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    # 4) DSH_HOME\dsh-runtimes 下安装过的 runtime
    if (-not [string]::IsNullOrWhiteSpace($DshHomePath)) {
        $runtimesRoot = Join-Path $DshHomePath 'dsh-runtimes'
        if (Test-Path -LiteralPath $runtimesRoot -PathType Container) {
            try {
                $foundNode = Get-ChildItem -LiteralPath $runtimesRoot -Recurse -Filter 'node.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $foundNode) {
                    return $foundNode.FullName
                }
            } catch {
                # 继续。
            }
        }
    }
    return $null
}

function Invoke-NodeSyntaxCheck {
    param([string]$NodePath, [string]$ScriptPath)
    # 注意：$ErrorActionPreference='Stop' 时，把原生 stderr 合并到成功流（2>&1）
    # 会触发 NativeCommandError 终止脚本，因此这里临时放宽 EAP 再捕获。
    $previousErrorActionPreference = $ErrorActionPreference
    $output = @()
    $exitCode = 0
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $NodePath --check $ScriptPath 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        $detail = (@($output) | ForEach-Object { [string]$_ }) -join "`r`n"
        if ([string]::IsNullOrWhiteSpace($detail)) {
            $detail = '（node --check 无输出）'
        }
        throw "插件 JS 语法检查失败（node --check 退出码 $exitCode）：$ScriptPath`r`n$detail"
    }
}

function Assert-PluginSourcePreflight {
    param([string]$PluginSourcePath, [string]$AppExePath, [string]$DshHomePath)

    # --- 1. 必需文件 ---
    $requiredRelativeFiles = @('package.json', 'cordis.patch.yml', 'lib\index.js')
    foreach ($relativeFile in $requiredRelativeFiles) {
        $requiredPath = Join-Path $PluginSourcePath $relativeFile
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "插件源缺少必需文件：$requiredPath`r`n（install.ps1 需要 package.json、cordis.patch.yml、lib\index.js）"
        }
        if ((Get-Item -LiteralPath $requiredPath).Length -le 0) {
            throw "插件源文件为空：$requiredPath"
        }
    }

    # --- 2. manifest 合法性与 BOM ---
    $manifestPath = Join-Path $PluginSourcePath 'package.json'
    if (Get-Utf8BomState -Path $manifestPath) {
        throw "插件 package.json 带有 UTF-8 BOM：$manifestPath`r`nNode 的 JSON.parse 不容忍 BOM，可能导致 DSH 无法加载该插件；请去掉 BOM 后重试。"
    }
    $manifestRawText = $null
    $manifest = $null
    try {
        $manifestRawText = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
        $manifest = $manifestRawText | ConvertFrom-Json
    } catch {
        throw "插件 package.json 不是合法 JSON：$manifestPath`r`n$($_.Exception.Message)"
    }
    if ($null -eq $manifest) {
        throw "插件 package.json 解析结果为空：$manifestPath"
    }
    if ([string]$manifest.name -ne 'dsh-open-in-folder') {
        Write-Warn ("插件 package.json 的 name 不是 dsh-open-in-folder（实际：{0}）" -f [string]$manifest.name)
    }

    $dshNode = Get-ObjectPropertyValue -Object $manifest -Name 'dsh'

    # --- 3. dsh.bundle.patch 指向的文件 ---
    $bundleNode = Get-ObjectPropertyValue -Object $dshNode -Name 'bundle'
    $patchValue = Get-ObjectPropertyValue -Object $bundleNode -Name 'patch'
    if (-not [string]::IsNullOrWhiteSpace([string]$patchValue)) {
        $patchPath = Resolve-ManifestRelativePath -PluginSourcePath $PluginSourcePath -RelativePath ([string]$patchValue)
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
            throw "插件 dsh.bundle.patch 指向的文件不存在：$patchPath"
        }
        if ((Get-Item -LiteralPath $patchPath).Length -le 0) {
            throw "插件 dsh.bundle.patch 指向的文件为空：$patchPath"
        }
        Write-Detail "bundle patch：$patchPath"
    } else {
        Write-Detail '插件未声明 dsh.bundle.patch（跳过）'
    }

    # --- 4. dsh.client 声明 → exports["./client"] → client bundle 存在且非空 ---
    $clientNode = Get-ObjectPropertyValue -Object $dshNode -Name 'client'
    $clientFullPath = $null
    if ($null -ne $clientNode) {
        $platformValue = [string](Get-ObjectPropertyValue -Object $clientNode -Name 'platform')
        if ($platformValue -ne 'web') {
            throw "插件 dsh.client.platform 必须为 web（实际：'$platformValue'），否则 DSH 启动会失败。"
        }
        foreach ($arrayFieldName in @('inject', 'external')) {
            $arrayFieldValue = Get-ObjectPropertyValue -Object $clientNode -Name $arrayFieldName
            if ($null -eq $arrayFieldValue) {
                continue
            }
            # PowerShell 5.1 的 ConvertFrom-Json 会把单元素数组折叠成标量，
            # 因此用原始 JSON 文本判断该字段是否真的声明为数组。
            $rawFieldPattern = '"' + [regex]::Escape($arrayFieldName) + '"\s*:'
            if (-not [regex]::IsMatch($manifestRawText, $rawFieldPattern)) {
                throw "插件 dsh.client.$arrayFieldName 必须是字符串数组（原始 JSON 中未找到该字段）。"
            }
            $rawArrayPattern = '"' + [regex]::Escape($arrayFieldName) + '"\s*:\s*\['
            if (-not [regex]::IsMatch($manifestRawText, $rawArrayPattern)) {
                throw "插件 dsh.client.$arrayFieldName 必须是字符串数组，不能是字符串或其它类型。"
            }
            foreach ($entry in @($arrayFieldValue)) {
                if (-not ($entry -is [string])) {
                    throw "插件 dsh.client.$arrayFieldName 必须是字符串数组（发现非字符串元素）。"
                }
            }
        }
        $exportsNode = Get-ObjectPropertyValue -Object $manifest -Name 'exports'
        $clientExportValue = $null
        if ($null -ne $exportsNode -and -not ($exportsNode -is [string])) {
            $clientExportValue = Get-ObjectPropertyValue -Object $exportsNode -Name './client'
        }
        $clientRelativePath = $null
        if ($null -ne $clientExportValue) {
            $clientRelativePath = Resolve-ExportTargetValue -Value $clientExportValue
        }
        if ([string]::IsNullOrWhiteSpace($clientRelativePath)) {
            throw '插件声明了 dsh.client，但 package.json 的 exports["./client"] 缺失或无法解析出文件路径；缺失 client bundle 会导致整个 DSH 应用无法启动。'
        }
        $clientFullPath = Resolve-ManifestRelativePath -PluginSourcePath $PluginSourcePath -RelativePath $clientRelativePath
        if (-not (Test-Path -LiteralPath $clientFullPath -PathType Leaf)) {
            throw "插件声明了 dsh.client，但 client bundle 文件不存在：$clientFullPath`r`n（client.js 缺失会导致整个 DSH 应用无法启动，已阻止安装）"
        }
        $clientLength = (Get-Item -LiteralPath $clientFullPath).Length
        if ($clientLength -le 100) {
            throw "client bundle 文件过小（$clientLength 字节，要求大于 100 字节），疑似为空或未构建：$clientFullPath"
        }
        Write-Detail "client bundle：$clientFullPath（$clientLength 字节）"
    } else {
        Write-Detail '插件未声明 dsh.client（无客户端 bundle 需要校验）'
    }

    # --- 5. node --check 语法校验（找不到 node 时只警告） ---
    $nodePath = Find-NodeExecutable -AppExePath $AppExePath -DshHomePath $DshHomePath
    if ([string]::IsNullOrWhiteSpace($nodePath)) {
        Write-Warn '未找到 node 可执行文件，跳过插件 JS 语法校验（node --check）。'
        Write-Ok '插件源预检通过（未做 node 语法校验：未找到 node）'
        return
    }
    $nodeVersion = ''
    try {
        $nodeVersion = (@(& $nodePath --version 2>&1) | Select-Object -First 1)
    } catch {
        $nodeVersion = '未知版本'
    }
    Write-Detail ("Node 语法校验：{0}（{1}）" -f $nodePath, $nodeVersion)
    Invoke-NodeSyntaxCheck -NodePath $nodePath -ScriptPath (Join-Path $PluginSourcePath 'lib\index.js')
    if (-not [string]::IsNullOrWhiteSpace($clientFullPath)) {
        Invoke-NodeSyntaxCheck -NodePath $nodePath -ScriptPath $clientFullPath
    }
    foreach ($extraScript in @('shell-integration.js')) {
        $extraPath = Join-Path $PluginSourcePath ('lib\' + $extraScript)
        if (Test-Path -LiteralPath $extraPath -PathType Leaf) {
            Invoke-NodeSyntaxCheck -NodePath $nodePath -ScriptPath $extraPath
        }
    }
    Write-Ok '插件源预检通过（必需文件 / manifest / bundle patch / client bundle / JS 语法）'
}

# =====================================================================
# DSH 运行状态检测（install 只做提示，不阻塞）
# =====================================================================

function Test-DshHostHealthOnce {
    param([string]$StateDirectory)
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
        return $false
    }
    $statePath = Join-Path $StateDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }
    try {
        $stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
    } catch {
        return $false
    }
    $portMatch = [regex]::Match($stateText, '"port"\s*:\s*(\d+)')
    if (-not $portMatch.Success) {
        return $false
    }
    $port = 0
    if (-not [int]::TryParse($portMatch.Groups[1].Value, [ref]$port)) {
        return $false
    }
    if ($port -le 0 -or $port -gt 65535) {
        return $false
    }
    $stateHost = '127.0.0.1'
    $hostMatch = [regex]::Match($stateText, '"host"\s*:\s*"([^"]+)"')
    if ($hostMatch.Success -and -not [string]::IsNullOrWhiteSpace($hostMatch.Groups[1].Value)) {
        $stateHost = $hostMatch.Groups[1].Value
    }
    try {
        $request = [System.Net.HttpWebRequest]::Create(("http://{0}:{1}/dsh-open-in-folder/health" -f $stateHost, $port))
        $request.Method = 'GET'
        $request.Proxy = $null
        $request.Timeout = 1500
        $request.ReadWriteTimeout = 1500
        $request.KeepAlive = $false
        $response = $request.GetResponse()
        try {
            return ([int]$response.StatusCode -eq 200)
        } finally {
            $response.Close()
        }
    } catch {
        return $false
    }
}

function Test-DshRunning {
    param([string]$StateDirectory)
    try {
        $processes = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
        if ($processes.Count -gt 0) {
            return $true
        }
    } catch {
        # 忽略。
    }
    return (Test-DshHostHealthOnce -StateDirectory $StateDirectory)
}

# =====================================================================
# profile package.json 编辑
# =====================================================================

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

function Set-ObjectPropertyValue {
    param($Object, [string]$Name, $Value)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
        return
    }
    $property.Value = $Value
}

function Update-ProfilePackageJson {
    param([string]$ProfileDirectory, [string]$PluginDirectory)

    $packagePath = Join-Path $ProfileDirectory 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "profile package.json 不存在：$packagePath`r`n请先启动一次 DeepSeek Harness 桌面版生成该 profile，然后重试。"
    }
    $backupPath = Join-Path $ProfileDirectory 'package.json.bak-open-in-folder'
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        Copy-Item -LiteralPath $packagePath -Destination $backupPath -Force -ErrorAction Stop
        Write-Ok "已备份 profile package.json → $(Split-Path -Leaf $backupPath)"
    } else {
        Write-Detail '首次安装备份已存在，不覆盖：package.json.bak-open-in-folder'
    }

    $rawText = [System.IO.File]::ReadAllText($packagePath, [System.Text.Encoding]::UTF8)
    $package = $null
    try {
        $package = $rawText | ConvertFrom-Json
    } catch {
        throw "profile package.json 不是合法 JSON：$($_.Exception.Message)"
    }
    if ($null -eq $package) {
        throw "profile package.json 解析结果为空：$packagePath"
    }

    $packageHasBom = Get-Utf8BomState -Path $packagePath
    if ($packageHasBom) {
        Write-Warn 'profile package.json 带有 UTF-8 BOM（Node 解析可能失败），本次安装将写回无 BOM 版本。'
    }

    $changed = $false
    if ($packageHasBom) {
        $changed = $true
    }

    # --- dependencies["dsh-open-in-folder"] ---
    $dependencies = Get-ObjectPropertyValue -Object $package -Name 'dependencies'
    if ($null -eq $dependencies) {
        $dependencies = New-Object System.Management.Automation.PSCustomObject
        Set-ObjectPropertyValue -Object $package -Name 'dependencies' -Value $dependencies
        $changed = $true
        Write-Detail 'profile package.json 缺少 dependencies，已创建'
    }
    $expectedDependency = 'file:' + ($PluginDirectory -replace '\\', '/')
    $existingDependency = Get-ObjectPropertyValue -Object $dependencies -Name 'dsh-open-in-folder'
    if ($null -eq $existingDependency -or ([string]$existingDependency -ne $expectedDependency)) {
        Set-ObjectPropertyValue -Object $dependencies -Name 'dsh-open-in-folder' -Value $expectedDependency
        $changed = $true
        Write-Ok "dependencies 已设置 dsh-open-in-folder = $expectedDependency"
    } else {
        Write-Detail 'dependencies 已包含等价依赖，无需修改'
    }

    # --- dsh.profile.bundles += "dsh-open-in-folder" ---
    $dshNode = Get-ObjectPropertyValue -Object $package -Name 'dsh'
    if ($null -eq $dshNode) {
        $dshNode = New-Object System.Management.Automation.PSCustomObject
        Set-ObjectPropertyValue -Object $package -Name 'dsh' -Value $dshNode
        $changed = $true
    }
    $profileNode = Get-ObjectPropertyValue -Object $dshNode -Name 'profile'
    if ($null -eq $profileNode) {
        $profileNode = New-Object System.Management.Automation.PSCustomObject
        Set-ObjectPropertyValue -Object $dshNode -Name 'profile' -Value $profileNode
        $changed = $true
    }
    $bundlesValue = Get-ObjectPropertyValue -Object $profileNode -Name 'bundles'
    $bundles = @()
    if ($null -ne $bundlesValue) {
        $bundles = @($bundlesValue)
    }
    if ($bundles -notcontains 'dsh-open-in-folder') {
        $bundles = @($bundles + 'dsh-open-in-folder')
        Set-ObjectPropertyValue -Object $profileNode -Name 'bundles' -Value $bundles
        $changed = $true
        Write-Ok 'dsh.profile.bundles 已追加 dsh-open-in-folder'
    } else {
        Write-Detail 'dsh.profile.bundles 已包含 dsh-open-in-folder，无需修改'
    }

    if (-not $changed) {
        Write-Ok 'profile package.json 已是目标状态（幂等，无需修改）'
        return $false
    }

    $jsonText = $package | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($packagePath, $jsonText + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok '已更新 profile package.json（UTF-8 无 BOM）'
    return $true
}

# =====================================================================
# 图标 / 注册表
# =====================================================================

function Save-ExeAssociatedIcon {
    param([string]$ExePath, [string]$IconPath)
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        return $false
    }
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ExePath)
        if ($null -eq $icon) {
            return $false
        }
        $iconDirectory = Split-Path -Parent $IconPath
        if (-not (Test-Path -LiteralPath $iconDirectory)) {
            New-Item -ItemType Directory -Path $iconDirectory -Force | Out-Null
        }
        $stream = [System.IO.File]::Create($IconPath)
        try {
            $icon.Save($stream)
        } finally {
            $stream.Dispose()
            $icon.Dispose()
        }
        if ((Test-Path -LiteralPath $IconPath -PathType Leaf) -and (Get-Item -LiteralPath $IconPath).Length -gt 0) {
            return $true
        }
        return $false
    } catch {
        return $false
    }
}

function Resolve-MenuIcon {
    param([string]$AppPath, [string]$LauncherExe, [string]$IconPath)
    if (-not [string]::IsNullOrWhiteSpace($AppPath)) {
        if (Save-ExeAssociatedIcon -ExePath $AppPath -IconPath $IconPath) {
            return $IconPath
        }
        Write-Warn "从 DeepSeek Harness.exe 提取图标失败，右键菜单 Icon 回退为应用路径。"
        return $AppPath
    }
    if (Save-ExeAssociatedIcon -ExePath $LauncherExe -IconPath $IconPath) {
        Write-Detail '未找到 DSH 应用路径，已改用启动器自身图标。'
        return $IconPath
    }
    if (Test-Path -LiteralPath $LauncherExe -PathType Leaf) {
        return $LauncherExe
    }
    return $null
}

function Set-RegistryStringValue {
    param([string]$KeyPath, [string]$Name, [string]$Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($KeyPath)
    if ($null -eq $key) {
        throw "无法创建注册表项：HKCU\$KeyPath"
    }
    try {
        $valueName = $Name
        if ([string]::IsNullOrEmpty($valueName)) {
            $valueName = $null
        }
        $key.SetValue($valueName, $Value, [Microsoft.Win32.RegistryValueKind]::String)
    } finally {
        $key.Close()
    }
}

function Register-DshContextMenu {
    param([string]$LauncherExePath, [string]$IconValue, [string]$RegistryRoot)
    $menuText = '在 DeepSeek Harness 中打开'
    $menuTargets = @(
        [pscustomobject]@{ KeyPath = ($RegistryRoot + '\Directory\shell\DSH.OpenInFolder'); Placeholder = '%1' },
        [pscustomobject]@{ KeyPath = ($RegistryRoot + '\Directory\Background\shell\DSH.OpenInFolder'); Placeholder = '%V' },
        [pscustomobject]@{ KeyPath = ($RegistryRoot + '\Drive\shell\DSH.OpenInFolder'); Placeholder = '%1' }
    )
    foreach ($target in $menuTargets) {
        $keyPath = $target.KeyPath
        Set-RegistryStringValue -KeyPath $keyPath -Name '' -Value $menuText
        Set-RegistryStringValue -KeyPath $keyPath -Name 'MUIVerb' -Value $menuText
        if (-not [string]::IsNullOrWhiteSpace($IconValue)) {
            Set-RegistryStringValue -KeyPath $keyPath -Name 'Icon' -Value $IconValue
        }
        $commandLine = '"' + $LauncherExePath + '" "' + $target.Placeholder + '"'
        Set-RegistryStringValue -KeyPath ($keyPath + '\command') -Name '' -Value $commandLine
        Write-Ok ("HKCU\{0} → {1}" -f $keyPath, $commandLine)
    }
}

# =====================================================================
# 摘要
# =====================================================================

function Write-InstallSummary {
    param(
        [string]$DshHome,
        [string]$PluginDir,
        [string]$LauncherExe,
        [string]$AppPath,
        [string]$StateDir,
        [string]$ProfileDir,
        [string]$PackageJson,
        [string]$IconValue,
        [bool]$RegistrySkipped,
        [bool]$LauncherSkipped,
        [bool]$DshRunning
    )
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' DSH「右键打开文件夹」安装完成' -ForegroundColor Green
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host " DSH_HOME      : $DshHome"
    Write-Host " 插件目录      : $PluginDir"
    if ($LauncherSkipped) {
        Write-Host " 启动器        : $LauncherExe（已指定 -NoLauncher，未编译）" -ForegroundColor Yellow
    } else {
        Write-Host " 启动器        : $LauncherExe"
    }
    if ([string]::IsNullOrWhiteSpace($AppPath)) {
        Write-Host ' DSH 应用      : 未自动发现（启动器运行时会再尝试注册表/固定路径）' -ForegroundColor Yellow
    } else {
        Write-Host " DSH 应用      : $AppPath"
    }
    Write-Host " 状态目录      : $StateDir"
    Write-Host " Profile       : $ProfileDir"
    Write-Host " package.json  : $PackageJson（备份：package.json.bak-open-in-folder）"
    if ($DshRunning) {
        Write-Host ' DSH 状态      : 正在运行（新版通常热加载插件，一般立即生效）' -ForegroundColor Cyan
    }
    if ($RegistrySkipped) {
        Write-Host ' 右键菜单      : 已跳过（-NoRegistry）' -ForegroundColor Yellow
    } else {
        Write-Host ' 右键菜单      : 已注册（文件夹 / 文件夹空白处 / 盘符）'
        if (-not [string]::IsNullOrWhiteSpace($IconValue)) {
            Write-Host " 图标          : $IconValue"
        }
    }
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    if ($DshRunning) {
        Write-Host ' 后续步骤：'
        Write-Host '   1. 检测到 DSH 正在运行：新版 DSH 通常会自动热加载插件，一般无需操作；'
        Write-Host '   2. 若右键菜单或插件未生效，请完全退出 DSH（窗口 + 系统托盘）后重新打开；'
        Write-Host '   3. 右键任意文件夹 / 文件夹空白处 / 盘符 →「在 DeepSeek Harness 中打开」。'
    } else {
        Write-Host ' 后续步骤：'
        Write-Host '   1. 启动 DeepSeek Harness（插件在 DSH 启动时加载）；'
        Write-Host '   2. 右键任意文件夹 / 文件夹空白处 / 盘符 →「在 DeepSeek Harness 中打开」。'
    }
    Write-Host ''
    Write-Host ' 卸载：powershell.exe -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1'
    Write-Host ' 注意：install.ps1 不会重启或关闭正在运行的 DSH。'
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host " 本次安装有 $($script:Warnings.Count) 条警告：" -ForegroundColor Yellow
        foreach ($warningMessage in $script:Warnings) {
            Write-Host "   - $warningMessage" -ForegroundColor Yellow
        }
        Write-Host '============================================================' -ForegroundColor Cyan
    }
}

# =====================================================================
# 主流程
# =====================================================================

try {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ' DeepSeek Harness「右键打开文件夹」安装' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan

    # ---------------------------------------------------------------
    Write-Step '0/9 解析路径与安装参数'
    $dshHome = Get-DshHomePath
    if ([string]::IsNullOrWhiteSpace($PluginSource)) {
        $PluginSource = Join-Path $PSScriptRoot 'plugin'
    }
    $pluginSource = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($PluginSource.Trim().Trim('"')))
    $pluginsRoot = Join-Path $dshHome 'plugins'
    $pluginDir = Join-Path $pluginsRoot 'dsh-open-in-folder'
    $stateDir = Join-Path $dshHome 'open-in-folder'
    $profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
    $launcherSourceDir = Join-Path $PSScriptRoot 'launcher'
    $buildScript = Join-Path $launcherSourceDir 'build-launcher.ps1'
    $launcherSource = Join-Path $launcherSourceDir 'DSHOpenInFolder.cs'
    $launcherExe = Join-Path (Join-Path $pluginDir 'launcher') 'DSHOpenInFolder.exe'
    $appPathFile = Join-Path $stateDir 'app-path.txt'
    $packagePath = Join-Path $profileDir 'package.json'
    $iconPath = Join-Path (Join-Path $pluginDir 'assets') 'icon.ico'

    Write-Detail "DSH_HOME      : $dshHome"
    Write-Detail "插件源        : $pluginSource"
    Write-Detail "插件安装目录  : $pluginDir"
    Write-Detail "Profile       : $profileDir"

    if ($pluginSource.TrimEnd('\', '/') -ieq $pluginDir.TrimEnd('\', '/')) {
        throw "插件源目录与插件安装目录相同，拒绝执行：$pluginSource"
    }
    if (-not (Test-Path -LiteralPath $pluginSource -PathType Container)) {
        throw "插件源目录不存在：$pluginSource`r`n可用 -PluginSource 指定插件源目录（默认 <脚本目录>\plugin）。"
    }

    # 前置条件校验：在产生任何副作用之前完成，失败时不留半安装状态。
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "profile 目录不存在：$profileDir`r`n请先启动一次 DeepSeek Harness 桌面版生成「$Profile」profile，然后重试。"
    }
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "profile package.json 不存在：$packagePath`r`n请先启动一次 DeepSeek Harness 桌面版生成该 profile，然后重试。"
    }
    if (-not $NoLauncher) {
        if (-not (Test-Path -LiteralPath $buildScript -PathType Leaf)) {
            throw "缺少启动器编译脚本：$buildScript"
        }
        if (-not (Test-Path -LiteralPath $launcherSource -PathType Leaf)) {
            throw "缺少启动器源码：$launcherSource"
        }
    }

    # ---------------------------------------------------------------
    Write-Step '1/9 解析 DeepSeek Harness 应用路径'
    $appPath = Resolve-DshAppExe -ExplicitPath $AppExe -StateDirectory $stateDir
    if ([string]::IsNullOrWhiteSpace($appPath)) {
        Write-Warn '未找到 DeepSeek Harness.exe；继续安装，但启动器运行时仍需能自动发现它（可用 -AppExe 指定）。'
    } else {
        Write-Ok "DSH 应用：$appPath"
    }

    # DSH 运行状态检测：只提示，不阻塞。新版 DSH 对 profile 变更支持热加载。
    $dshRunning = Test-DshRunning -StateDirectory $stateDir
    if ($dshRunning) {
        Write-Host ''
        Write-Host '    [信息] 检测到 DeepSeek Harness 正在运行：' -ForegroundColor Cyan
        Write-Host '           新版 DSH 通常会自动热加载插件，本次安装一般立即生效；' -ForegroundColor Cyan
        Write-Host '           若右键菜单或插件未生效，请完全退出 DSH（窗口 + 系统托盘）后重新打开。' -ForegroundColor Cyan
    }

    # ---------------------------------------------------------------
    Write-Step '2/9 预检插件源（必须在产生任何副作用之前通过）'
    Assert-PluginSourcePreflight -PluginSourcePath $pluginSource -AppExePath $appPath -DshHomePath $dshHome

    # ---------------------------------------------------------------
    Write-Step '3/9 复制插件到 %DSH_HOME%\plugins\dsh-open-in-folder'
    if (-not (Test-Path -LiteralPath $pluginsRoot)) {
        New-Item -ItemType Directory -Path $pluginsRoot -Force | Out-Null
    }
    if (Test-Path -LiteralPath $pluginDir) {
        $oldChildren = @(Get-ChildItem -LiteralPath $pluginDir -Force)
        foreach ($child in $oldChildren) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
        }
        Write-Detail "已清空旧插件目录：$pluginDir"
    }
    Copy-DirectoryTree -SourcePath $pluginSource -DestinationPath $pluginDir
    Write-Ok "插件已复制：$pluginDir"

    # ---------------------------------------------------------------
    Write-Step '4/9 编译启动器（csc /target:winexe）'
    if ($NoLauncher) {
        Write-Detail '已指定 -NoLauncher，跳过启动器编译'
        if (-not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
            Write-Warn "未编译启动器且目标不存在：$launcherExe（右键菜单点击会失败）"
        }
    } else {
        Invoke-LauncherBuild -BuildScript $buildScript -Source $launcherSource -OutFile $launcherExe
        Write-Ok "启动器已编译：$launcherExe"
    }

    # ---------------------------------------------------------------
    Write-Step '5/9 写入 app-path.txt'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($appPath)) {
        [System.IO.File]::WriteAllText($appPathFile, $appPath + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        Write-Ok "已写入：$appPathFile"
    } else {
        Write-Detail '未解析到 DSH 应用路径，跳过 app-path.txt'
    }

    # ---------------------------------------------------------------
    Write-Step "6/9 建立 profile node_modules 解析（junction）"
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "profile 目录不存在：$profileDir`r`n请先启动一次 DeepSeek Harness 桌面版生成「$Profile」profile，然后重试。"
    }
    $nodeModulesDir = Join-Path $profileDir 'node_modules'
    if (-not (Test-Path -LiteralPath $nodeModulesDir -PathType Container)) {
        New-Item -ItemType Directory -Path $nodeModulesDir -Force | Out-Null
    }
    $junctionPath = Join-Path $nodeModulesDir 'dsh-open-in-folder'
    Set-PluginJunction -LinkPath $junctionPath -TargetPath $pluginDir | Out-Null
    Write-Ok "junction 已建立：$junctionPath -> $pluginDir"

    # ---------------------------------------------------------------
    Write-Step '7/9 更新 profile package.json（dependencies + dsh.profile.bundles）'
    Update-ProfilePackageJson -ProfileDirectory $profileDir -PluginDirectory $pluginDir | Out-Null

    # ---------------------------------------------------------------
    Write-Step '8/9 注册资源管理器右键菜单'
    $iconValue = $null
    if ($NoRegistry) {
        Write-Detail '已指定 -NoRegistry，跳过图标提取与右键菜单注册'
    } else {
        if (-not (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
            Write-Warn "启动器不存在，右键菜单点击将失败：$launcherExe"
        }
        $iconValue = Resolve-MenuIcon -AppPath $appPath -LauncherExe $launcherExe -IconPath $iconPath
        if (-not [string]::IsNullOrWhiteSpace($iconValue) -and $iconValue -ieq $iconPath) {
            Write-Ok "图标已提取：$iconPath"
        }
        if ($RegistryRoot -ne 'Software\Classes') {
            Write-Detail "注册表根（自定义/测试）：HKCU\$RegistryRoot"
        }
        Register-DshContextMenu -LauncherExePath $launcherExe -IconValue $iconValue -RegistryRoot $RegistryRoot
    }

    # ---------------------------------------------------------------
    Write-Step '9/9 完成'
    if ($dshRunning) {
        Write-Detail '安装完成：检测到 DSH 正在运行，新版通常热加载立即生效；未生效时请完全退出后重开。'
    } elseif ($appPath -and (Test-Path -LiteralPath $launcherExe -PathType Leaf)) {
        Write-Detail '安装完成：右键菜单可立即出现；插件将在 DSH 下次启动时加载。'
    }
    Write-InstallSummary -DshHome $dshHome -PluginDir $pluginDir -LauncherExe $launcherExe `
        -AppPath $appPath -StateDir $stateDir -ProfileDir $profileDir -PackageJson $packagePath `
        -IconValue $iconValue -RegistrySkipped ([bool]$NoRegistry) -LauncherSkipped ([bool]$NoLauncher) `
        -DshRunning ([bool]$dshRunning)

    exit 0
} catch {
    Write-Host ''
    Write-Host "安装失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '提示：本脚本幂等，修复问题后可直接重新运行 install.ps1。' -ForegroundColor Yellow
    exit 1
}
