# build-launcher.ps1
# 编译 DSH「在 DeepSeek Harness 中打开」右键启动器（C# 5 / .NET Framework 4.8 / WinExe）。
#
# 用法：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\build-launcher.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File launcher\build-launcher.ps1 -OutFile <某路径>\DSHOpenInFolder.exe
#
# 可选参数：
#   -Source   源文件，默认 <本脚本目录>\DSHOpenInFolder.cs
#   -OutFile  输出 exe，默认 <本脚本目录>\DSHOpenInFolder.exe
#   -CscPath  显式指定 csc.exe
#   -Quiet    减少输出
#
# 退出码：0 成功；1 失败。

[CmdletBinding()]
param(
    [string]$Source,
    [string]$OutFile,
    [string]$CscPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Write-BuildInfo {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host "    $Message" -ForegroundColor DarkGray
    }
}

function Write-BuildError {
    param([string]$Message)
    Write-Host "    [错误] $Message" -ForegroundColor Red
}

function Find-Csc {
    param([string]$Hint)
    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($Hint)) {
        [void]$candidates.Add($Hint)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:WINDIR)) {
        [void]$candidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'))
        [void]$candidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    try {
        $command = Get-Command -Name 'csc.exe' -CommandType Application -ErrorAction Stop
        return $command.Source
    } catch {
        return $null
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($Source)) {
        $Source = Join-Path $PSScriptRoot 'DSHOpenInFolder.cs'
    }
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $OutFile = Join-Path $PSScriptRoot 'DSHOpenInFolder.exe'
    }
    $Source = [System.IO.Path]::GetFullPath($Source)
    $OutFile = [System.IO.Path]::GetFullPath($OutFile)

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Write-BuildError "源文件不存在：$Source"
        exit 1
    }

    $compiler = Find-Csc -Hint $CscPath
    if ([string]::IsNullOrWhiteSpace($compiler)) {
        Write-BuildError '未找到 C# 编译器 csc.exe（需要 .NET Framework 4.x）。'
        Write-BuildError '请安装 .NET Framework 4.8，或用 -CscPath 指定 csc.exe 路径。'
        exit 1
    }
    Write-BuildInfo "csc   : $compiler"

    $outDirectory = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $outDirectory)) {
        New-Item -ItemType Directory -Path $outDirectory -Force | Out-Null
    }

    # 源文件应为 UTF-8 带 BOM（csc 4.8 处理中文字面量最稳）；无 BOM 时给出警告但不阻断编译。
    try {
        $head = [System.IO.File]::ReadAllBytes($Source)
        if ($head.Length -lt 3 -or $head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) {
            Write-Host '    [警告] 源文件不是 UTF-8 带 BOM，中文文案可能显示异常。' -ForegroundColor Yellow
        }
    } catch {
        # 编码检查失败不影响编译。
    }

    $compilerArgs = @(
        '/nologo',
        '/target:winexe',
        '/codepage:65001',
        '/optimize+',
        ('/out:' + $OutFile),
        '/r:System.Windows.Forms.dll',
        '/r:System.Drawing.dll',
        $Source
    )
    Write-BuildInfo "源文件: $Source"
    Write-BuildInfo "输出  : $OutFile"

    $compilerOutput = & $compiler @compilerArgs 2>&1
    $compilerExitCode = $LASTEXITCODE
    if (-not $Quiet) {
        foreach ($line in @($compilerOutput)) {
            $text = [string]$line
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                Write-Host "    $text"
            }
        }
    }

    if ($compilerExitCode -ne 0) {
        Write-BuildError "编译失败（csc 退出码 $compilerExitCode）。"
        exit 1
    }
    if (-not (Test-Path -LiteralPath $OutFile -PathType Leaf)) {
        Write-BuildError "编译命令成功但未生成输出文件：$OutFile"
        exit 1
    }
    $size = (Get-Item -LiteralPath $OutFile).Length
    if (-not $Quiet) {
        Write-Host "    [OK] 编译成功：$OutFile（$size 字节）" -ForegroundColor Green
    }
    exit 0
} catch {
    Write-BuildError "编译异常：$($_.Exception.Message)"
    exit 1
}
