<#
.SYNOPSIS
  卸载 DeepSeek Harness「右键打开文件夹」集成（幂等回滚，精确删除）。

.DESCRIPTION
  回滚内容（顺序经过设计，避免出现“profile 仍声明插件 bundle/client、但文件已被删”的致命窗口期）：
    1. 先更新 profile package.json：精确删除 dependencies["dsh-open-in-folder"] 与
       dsh.profile.bundles 中的 "dsh-open-in-folder"，【保留其它所有字段与其它插件条目】；
       仅当当前 package.json 不存在或无法解析、且存在首次安装备份时，才回退为从备份恢复
       （并明确告警、把损坏文件另存一份）。备份文件不删除；
    2. 删除 profile node_modules 下指向插件目录的 junction；
    3. 删除 %DSH_HOME%\plugins\dsh-open-in-folder；
    4. 删除 HKCU 右键菜单注册表项（文件夹 / 文件夹空白处 / 盘符）；
    5. 删除 %DSH_HOME%\open-in-folder 状态目录（-KeepState 时保留）。

  说明：本脚本【不会】重启或关闭正在运行的 DeepSeek Harness；
        新版 DSH 通常会对 profile 变更热加载。

.PARAMETER Profile
  DSH profile 名称，默认 desktop。

.PARAMETER KeepState
  保留 %DSH_HOME%\open-in-folder（state.json / events.log / launcher.log / app-path.txt）。

.PARAMETER RegistryRoot
  注册表根路径（HKCU 下），默认 Software\Classes。
  仅高级/测试使用：指向测试根可避免改动真实右键菜单。

.PARAMETER Quiet
  减少过程输出（仍输出摘要、警告与错误）。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 -KeepState

.NOTES
  退出码：0 成功（含“本来就没装”的幂等情况）；1 有删除操作失败。
#>

[CmdletBinding()]
param(
    [string]$Profile = 'desktop',
    [string]$RegistryRoot,
    [switch]$KeepState,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Quiet = [bool]$Quiet
$script:Warnings = New-Object System.Collections.ArrayList
$script:Failures = New-Object System.Collections.ArrayList
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
    if (-not $script:Quiet) {
        Write-Host "    [OK] $Message" -ForegroundColor Green
    }
}

function Write-Warn {
    param([string]$Message)
    [void]$script:Warnings.Add($Message)
    Write-Host "    [警告] $Message" -ForegroundColor Yellow
}

function Write-Failure {
    param([string]$Message)
    [void]$script:Failures.Add($Message)
    Write-Host "    [失败] $Message" -ForegroundColor Red
}

# =====================================================================
# 路径 / 文件 / 注册表辅助
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

function Test-IsReparsePoint {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Test-FileHasUtf8Bom {
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
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
            # 尝试备用方案。
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

function Remove-RegistryTree {
    param([string]$KeyPath)
    try {
        $lastSlash = $KeyPath.LastIndexOf('\')
        if ($lastSlash -lt 1) {
            throw "非法注册表路径：$KeyPath"
        }
        $parentPath = $KeyPath.Substring(0, $lastSlash)
        $leafName = $KeyPath.Substring($lastSlash + 1)
        $parentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parentPath, $true)
        if ($null -eq $parentKey) {
            return $false
        }
        try {
            $existingKey = $parentKey.OpenSubKey($leafName, $false)
            if ($null -eq $existingKey) {
                return $false
            }
            $existingKey.Close()
            $parentKey.DeleteSubKeyTree($leafName, $false)
            return $true
        } finally {
            $parentKey.Close()
        }
    } catch {
        throw "删除注册表项失败（HKCU\$KeyPath）：$($_.Exception.Message)"
    }
}

# =====================================================================
# profile package.json：外科式删除（保留其它插件条目）
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

function Remove-PluginFromPackageJson {
    param([string]$PackagePath)

    $rawText = [System.IO.File]::ReadAllText($PackagePath, [System.Text.Encoding]::UTF8)
    try {
        $package = $rawText | ConvertFrom-Json
    } catch {
        throw "profile package.json 不是合法 JSON，无法精确编辑：$($_.Exception.Message)"
    }
    if ($null -eq $package) {
        return $false
    }
    $changed = $false

    # dependencies["dsh-open-in-folder"]
    $dependencies = Get-ObjectPropertyValue -Object $package -Name 'dependencies'
    if ($null -ne $dependencies) {
        $dependencyProperty = $dependencies.PSObject.Properties['dsh-open-in-folder']
        if ($null -ne $dependencyProperty) {
            $dependencies.PSObject.Properties.Remove('dsh-open-in-folder')
            $changed = $true
        }
    }

    # dsh.profile.bundles 中的 "dsh-open-in-folder"
    $dshNode = Get-ObjectPropertyValue -Object $package -Name 'dsh'
    if ($null -ne $dshNode) {
        $profileNode = Get-ObjectPropertyValue -Object $dshNode -Name 'profile'
        if ($null -ne $profileNode) {
            $bundlesProperty = $profileNode.PSObject.Properties['bundles']
            if ($null -ne $bundlesProperty -and $null -ne $bundlesProperty.Value) {
                $bundles = @($bundlesProperty.Value)
                $filtered = @($bundles | Where-Object { [string]$_ -ne 'dsh-open-in-folder' })
                if ($filtered.Count -ne $bundles.Count) {
                    $profileNode.PSObject.Properties.Remove('bundles')
                    $profileNode | Add-Member -MemberType NoteProperty -Name 'bundles' -Value $filtered -Force
                    $changed = $true
                }
            }
        }
    }

    if (-not $changed) {
        return $false
    }
    $jsonText = $package | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($PackagePath, $jsonText + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $true
}

# =====================================================================
# 摘要
# =====================================================================

function Write-UninstallSummary {
    param(
        [string]$DshHome,
        [string]$PluginDir,
        [string]$StateDir,
        [string]$ProfileDir,
        [string]$PackageJson,
        [string]$BackupPath,
        [string]$RecoveredBrokenCopy,
        [bool]$StateKept,
        [bool]$WasInstalled
    )
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($WasInstalled) {
        Write-Host ' DSH「右键打开文件夹」卸载完成' -ForegroundColor Green
    } else {
        Write-Host ' DSH「右键打开文件夹」未检测到安装痕迹（幂等，无操作）' -ForegroundColor Green
    }
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host " DSH_HOME      : $DshHome"
    Write-Host " 插件目录      : $PluginDir（已删除或不存在）"
    Write-Host " Profile       : $ProfileDir"
    Write-Host " package.json  : $PackageJson（已精确移除本插件条目，保留其它插件配置）"
    if (Test-Path -LiteralPath $BackupPath -PathType Leaf) {
        Write-Host " 备份文件      : $BackupPath（已保留；确认不再需要时可手动删除）" -ForegroundColor Yellow
    }
    if (-not [string]::IsNullOrWhiteSpace($RecoveredBrokenCopy)) {
        Write-Host " 损坏文件副本  : $RecoveredBrokenCopy" -ForegroundColor Yellow
    }
    if ($StateKept) {
        Write-Host " 状态目录      : $StateDir（已按 -KeepState 保留）" -ForegroundColor Yellow
    } else {
        Write-Host " 状态目录      : $StateDir（已删除或不存在）"
    }
    Write-Host ' 右键菜单      : 已删除（文件夹 / 文件夹空白处 / 盘符）'
    Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host ' 说明：卸载不会重启 DSH；新版 DSH 通常会对 profile 变更热加载，一般立即生效。'
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Host " 本次卸载有 $($script:Warnings.Count) 条警告：" -ForegroundColor Yellow
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
    Write-Host ' DeepSeek Harness「右键打开文件夹」卸载' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan

    $dshHome = Get-DshHomePath
    $pluginsRoot = Join-Path $dshHome 'plugins'
    $pluginDir = Join-Path $pluginsRoot 'dsh-open-in-folder'
    $stateDir = Join-Path $dshHome 'open-in-folder'
    $profileDir = Join-Path (Join-Path $dshHome 'profiles') $Profile
    $packagePath = Join-Path $profileDir 'package.json'
    $backupPath = Join-Path $profileDir 'package.json.bak-open-in-folder'
    $nodeModulesDir = Join-Path $profileDir 'node_modules'
    $junctionPath = Join-Path $nodeModulesDir 'dsh-open-in-folder'
    $wasInstalled = $false
    $recoveredBrokenCopy = ''

    Write-Detail "DSH_HOME : $dshHome"
    Write-Detail "Profile  : $profileDir"

    # ---------------------------------------------------------------
    # 顺序很重要：先让 profile 不再声明本插件（bundle/client），再动文件。
    # 这样任何窗口期最多是“文件还在但未登记”（可容忍），不会出现
    # “声明了 dsh.client 但 client.js 已不存在”这种会让 DSH 起不来的组合。
    # ---------------------------------------------------------------
    Write-Step '1/5 更新 profile package.json（精确移除本插件登记，保留其它插件配置）'
    $packageExists = Test-Path -LiteralPath $packagePath -PathType Leaf
    $packageParsed = $false
    if ($packageExists) {
        try {
            $null = [System.IO.File]::ReadAllText($packagePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $packageParsed = $true
        } catch {
            $packageParsed = $false
        }
    }
    if ($packageParsed) {
        if (Test-FileHasUtf8Bom -Path $packagePath) {
            Write-Warn 'profile package.json 带有 UTF-8 BOM（Node 解析可能失败），如本次未改动请运行 install.ps1 修复。'
        }
        try {
            if (Remove-PluginFromPackageJson -PackagePath $packagePath) {
                Write-Ok '已从 profile package.json 精确移除 dsh-open-in-folder 的 dependencies 与 dsh.profile.bundles 条目（保留其它插件条目）'
                $wasInstalled = $true
            } else {
                Write-Detail 'profile package.json 未包含本插件条目，跳过'
            }
        } catch {
            Write-Failure "编辑 profile package.json 失败：$($_.Exception.Message)"
        }
    } elseif (Test-Path -LiteralPath $backupPath -PathType Leaf) {
        # 只有当前 package.json 不存在/无法解析时，才回退到备份恢复（并明确告警）。
        if ($packageExists) {
            $recoveredBrokenCopy = $packagePath + '.broken-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            try {
                Copy-Item -LiteralPath $packagePath -Destination $recoveredBrokenCopy -Force -ErrorAction Stop
                Write-Warn "当前 profile package.json 无法解析，已另存损坏文件副本：$recoveredBrokenCopy"
            } catch {
                Write-Warn "当前 profile package.json 无法解析，且另存损坏副本失败：$($_.Exception.Message)"
                $recoveredBrokenCopy = ''
            }
        }
        Write-Warn '回退为从 package.json.bak-open-in-folder 恢复（备份文件保留）。'
        try {
            Copy-Item -LiteralPath $backupPath -Destination $packagePath -Force -ErrorAction Stop
            Write-Ok '已从备份恢复 profile package.json'
            $wasInstalled = $true
        } catch {
            Write-Failure "从备份恢复 profile package.json 失败：$($_.Exception.Message)"
        }
    } else {
        Write-Detail 'profile package.json 不存在且无备份，跳过'
    }

    # ---------------------------------------------------------------
    Write-Step '2/5 删除 profile node_modules 中的 junction'
    if (Test-Path -LiteralPath $junctionPath) {
        if (Test-IsReparsePoint -Path $junctionPath) {
            try {
                Remove-PathRobust -Path $junctionPath
                Write-Ok "已删除 junction：$junctionPath"
                $wasInstalled = $true
            } catch {
                Write-Failure $_.Exception.Message
            }
        } else {
            # 普通目录：仅当确认是本插件副本时才删除，避免误删用户数据。
            $isOurPlugin = $false
            $manifestPath = Join-Path $junctionPath 'package.json'
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                try {
                    $manifest = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    if ([string]$manifest.name -eq 'dsh-open-in-folder') {
                        $isOurPlugin = $true
                    }
                } catch {
                    $isOurPlugin = $false
                }
            }
            if ($isOurPlugin) {
                try {
                    Remove-Item -LiteralPath $junctionPath -Recurse -Force -ErrorAction Stop
                    Write-Ok "已删除插件普通目录副本：$junctionPath"
                    $wasInstalled = $true
                } catch {
                    Write-Failure "删除 node_modules\dsh-open-in-folder 失败：$($_.Exception.Message)"
                }
            } else {
                Write-Warn "node_modules\dsh-open-in-folder 是普通目录且不是本插件（未包含匹配的 package.json），已保留：$junctionPath"
            }
        }
    } else {
        Write-Detail 'junction 不存在，跳过'
    }

    # ---------------------------------------------------------------
    Write-Step '3/5 删除插件目录'
    if (Test-Path -LiteralPath $pluginDir) {
        try {
            Remove-Item -LiteralPath $pluginDir -Recurse -Force -ErrorAction Stop
            Write-Ok "已删除插件目录：$pluginDir"
            $wasInstalled = $true
        } catch {
            Write-Failure "删除插件目录失败（可能仍被占用）：$pluginDir`r`n$($_.Exception.Message)"
        }
    } else {
        Write-Detail "插件目录不存在，跳过：$pluginDir"
    }
    if (Test-Path -LiteralPath $pluginsRoot) {
        try {
            $remaining = @(Get-ChildItem -LiteralPath $pluginsRoot -Force)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $pluginsRoot -Force -ErrorAction Stop
                Write-Detail "已清理空目录：$pluginsRoot"
            }
        } catch {
            Write-Detail "清理空 plugins 目录失败（可忽略）：$($_.Exception.Message)"
        }
    }

    # ---------------------------------------------------------------
    Write-Step '4/5 删除资源管理器右键菜单注册表项'
    $menuKeys = @(
        ($RegistryRoot + '\Directory\shell\DSH.OpenInFolder'),
        ($RegistryRoot + '\Directory\Background\shell\DSH.OpenInFolder'),
        ($RegistryRoot + '\Drive\shell\DSH.OpenInFolder')
    )
    if ($RegistryRoot -ne 'Software\Classes') {
        Write-Detail "注册表根（自定义/测试）：HKCU\$RegistryRoot"
    }
    foreach ($menuKey in $menuKeys) {
        try {
            if (Remove-RegistryTree -KeyPath $menuKey) {
                Write-Ok "已删除 HKCU\$menuKey"
                $wasInstalled = $true
            } else {
                Write-Detail "注册表项不存在，跳过：HKCU\$menuKey"
            }
        } catch {
            Write-Failure $_.Exception.Message
        }
    }

    # ---------------------------------------------------------------
    Write-Step '5/5 删除运行状态目录'
    if ($KeepState) {
        Write-Detail "已指定 -KeepState，保留状态目录：$stateDir"
    } elseif (Test-Path -LiteralPath $stateDir) {
        try {
            Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction Stop
            Write-Ok "已删除状态目录：$stateDir"
            $wasInstalled = $true
        } catch {
            Write-Failure "删除状态目录失败（可能仍被占用）：$stateDir`r\n$($_.Exception.Message)"
        }
    } else {
        Write-Detail "状态目录不存在，跳过：$stateDir"
    }

    # ---------------------------------------------------------------
    Write-UninstallSummary -DshHome $dshHome -PluginDir $pluginDir -StateDir $stateDir `
        -ProfileDir $profileDir -PackageJson $packagePath -BackupPath $backupPath `
        -RecoveredBrokenCopy $recoveredBrokenCopy -StateKept ([bool]$KeepState) -WasInstalled $wasInstalled

    if ($script:Failures.Count -gt 0) {
        Write-Host ''
        Write-Host "卸载未完全成功：$($script:Failures.Count) 个操作失败。" -ForegroundColor Red
        foreach ($failureMessage in $script:Failures) {
            Write-Host "   - $failureMessage" -ForegroundColor Red
        }
        exit 1
    }
    exit 0
} catch {
    Write-Host ''
    Write-Host "卸载失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
