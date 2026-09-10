<#
.SYNOPSIS
    Standard-User Safe System Maintenance Suite (PowerShell 5.1 Production Ready)
.DESCRIPTION
    完全相容 Windows PowerShell 5.1。以標準使用者 (Non-Admin) 權限執行的系統維護與安全快取清理工具。
    提供高信心啟動項審查、安全白名單快取清理、可逆登錄檔調優、實體捷徑備份還原與現代淺色 GUI。
.NOTES
    架構標準: Modular Architecture v4.5 (Safe-Whitelisted Edition)
    執行權限: 標準使用者 (無需管理員 UAC 提升)
#>

# ----------------------------------------------------------------------
# 0. 載入 WPF 核心組件
# ----------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ----------------------------------------------------------------------
# 1. 腳本內部設定模組 (Script Configuration Scope)
# ----------------------------------------------------------------------
$script:AppConfig = @{
    AppName        = "系統維護與快取安全清理工具"
    Version        = "4.5.0"
    BackupRoot     = [System.IO.Path]::Combine($env:LOCALAPPDATA, "UserOptimizer\Backups")
    MaxLogChars    = 100000

    # 登錄檔調優項目 (包含型別、預設值與原始狀態契約)
    RegistrySpecs  = @(
        @{
            Name        = "桌面選單展開延遲 (MenuShowDelay)"
            Path        = "HKCU:\Control Panel\Desktop"
            KeyName     = "MenuShowDelay"
            TargetValue = "20"
            ValueKind   = "String"
            Description = "縮短滑鼠懸停於選單時的展開等待時間"
        },
        @{
            Name        = "無回應程式判定逾時 (HungAppTimeout)"
            Path        = "HKCU:\Control Panel\Desktop"
            KeyName     = "HungAppTimeout"
            TargetValue = "1500"
            ValueKind   = "String"
            Description = "縮短 Windows 判定應用程式失去回應的時間"
        },
        @{
            Name        = "關閉無回應程式等候逾時 (WaitToKillAppTimeout)"
            Path        = "HKCU:\Control Panel\Desktop"
            KeyName     = "WaitToKillAppTimeout"
            TargetValue = "2000"
            ValueKind   = "String"
            Description = "縮短登出或關機時強制結束無回應程式的等候時間"
        },
        @{
            Name        = "視窗縮放動畫效果 (MinAnimate)"
            Path        = "HKCU:\Control Panel\Desktop\WindowMetrics"
            KeyName     = "MinAnimate"
            TargetValue = "0"
            ValueKind   = "String"
            Description = "停用視窗最小化與最大化的過渡動畫以提升流暢感"
        }
    )

    # 啟動項目登錄檔位置
    StartupRegKeys = @(
        @{ Location = "HKCU Run"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" },
        @{ Location = "HKCU RunOnce"; Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce" }
    )
    StartupFolder  = [System.IO.Path]::Combine($env:APPDATA, "Microsoft\Windows\Start Menu\Programs\Startup")
}

# ----------------------------------------------------------------------
# 2. 基礎底層工具函式模組 (Infrastructure Helpers)
# ----------------------------------------------------------------------
function Format-SafeBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][long]$Bytes)
    process {
        if ($Bytes -le 0) { return "0 B" }
        $units = @("B", "KB", "MB", "GB", "TB")
        $order = [Math]::Truncate([Math]::Log($Bytes, 1024))
        if ($order -ge $units.Length) { $order = $units.Length - 1 }
        $val = $Bytes / [Math]::Pow(1024, $order)
        return "{0:N2} {1}" -f $val, $units[$order]
    }
}

function Initialize-SafeNativeMethods {
    [CmdletBinding()]
    param()
    process {
        if (-not ([System.Management.Automation.PSTypeName]'Win32ProcessMemoryHelper').Type) {
            $cSharpSource = @"
using System;
using System.Runtime.InteropServices;

public static class Win32ProcessMemoryHelper {
    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EmptyWorkingSet(IntPtr hProcess);
}
"@
            Add-Type -TypeDefinition $cSharpSource -Language CSharp -ErrorAction Stop
        }
    }
}

# ----------------------------------------------------------------------
# 3. 安全快取定位與清理模組 (Whitelisted Cache Service)
# ----------------------------------------------------------------------
function Get-SafeCacheTargets {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        $targets = New-Object 'System.Collections.Generic.List[PSCustomObject]'

        # 1. 系統使用者暫存
        $tempPath = [System.IO.Path]::GetTempPath()
        if ([System.IO.Directory]::Exists($tempPath)) {
            $targets.Add([PSCustomObject]@{
                Category    = "系統暫存"
                Name        = "使用者暫存目錄 ($env:TEMP)"
                BasePath    = $tempPath
                FilePattern = "*"
                Recursive   = $true
                IsDirectory = $false
            })
        }

        # 2. 檔案總管縮圖快取 (嚴格白名單化：只刪 thumbcache_*.db 與 iconcache_*.db)
        $explorerPath = [System.IO.Path]::Combine($env:LOCALAPPDATA, "Microsoft\Windows\Explorer")
        if ([System.IO.Directory]::Exists($explorerPath)) {
            $targets.Add([PSCustomObject]@{
                Category    = "系統快取"
                Name        = "檔案總管圖示與縮圖快取資料庫"
                BasePath    = $explorerPath
                FilePattern = "*cache_*.db"
                Recursive   = $false
                IsDirectory = $false
            })
        }

        # 3. Chromium 系列 (動態掃描所有 Profile 資料夾)
        $chromiumBrowsers = @(
            @{ Name = "Microsoft Edge"; Base = [System.IO.Path]::Combine($env:LOCALAPPDATA, "Microsoft\Edge\User Data") },
            @{ Name = "Google Chrome";  Base = [System.IO.Path]::Combine($env:LOCALAPPDATA, "Google\Chrome\User Data") },
            @{ Name = "Brave Browser";  Base = [System.IO.Path]::Combine($env:LOCALAPPDATA, "BraveSoftware\Brave-Browser\User Data") }
        )

        foreach ($browser in $chromiumBrowsers) {
            if ([System.IO.Directory]::Exists($browser.Base)) {
                $profiles = Get-ChildItem -Path $browser.Base -Directory -ErrorAction SilentlyContinue | 
                            Where-Object { $_.Name -eq "Default" -or $_.Name -like "Profile *" }
                foreach ($p in $profiles) {
                    $cachePaths = @(
                        [System.IO.Path]::Combine($p.FullName, "Cache\Cache_Data"),
                        [System.IO.Path]::Combine($p.FullName, "Code Cache"),
                        [System.IO.Path]::Combine($p.FullName, "GPUCache")
                    )
                    foreach ($cp in $cachePaths) {
                        if ([System.IO.Directory]::Exists($cp)) {
                            $targets.Add([PSCustomObject]@{
                                Category    = "瀏覽器快取"
                                Name        = "$($browser.Name) ($($p.Name)) - $([System.IO.Path]::GetFileName($cp))"
                                BasePath    = $cp
                                FilePattern = "*"
                                Recursive   = $true
                                IsDirectory = $true
                            })
                        }
                    }
                }
            }
        }

        # 4. Firefox Profiles (嚴格限定 cache2 與 startupCache)
        $firefoxBase = [System.IO.Path]::Combine($env:LOCALAPPDATA, "Mozilla\Firefox\Profiles")
        if ([System.IO.Directory]::Exists($firefoxBase)) {
            $ffProfiles = Get-ChildItem -Path $firefoxBase -Directory -ErrorAction SilentlyContinue
            foreach ($ffp in $ffProfiles) {
                $ffCaches = @("cache2", "startupCache")
                foreach ($cName in $ffCaches) {
                    $ffPath = [System.IO.Path]::Combine($ffp.FullName, $cName)
                    if ([System.IO.Directory]::Exists($ffPath)) {
                        $targets.Add([PSCustomObject]@{
                            Category    = "瀏覽器快取"
                            Name        = "Mozilla Firefox ($($ffp.Name)) - $cName"
                            BasePath    = $ffPath
                            FilePattern = "*"
                            Recursive   = $true
                            IsDirectory = $true
                        })
                    }
                }
            }
        }

        # 5. 開發者快取
        $vscodeCache = [System.IO.Path]::Combine($env:APPDATA, "Code\Cache")
        if ([System.IO.Directory]::Exists($vscodeCache)) {
            $targets.Add([PSCustomObject]@{
                Category    = "開發環境快取"
                Name        = "VS Code HTTP 快取"
                BasePath    = $vscodeCache
                FilePattern = "*"
                Recursive   = $true
                IsDirectory = $true
            })
        }

        return $targets
    }
}

function Invoke-SafeCacheOperation {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][switch]$ExecuteClean,
        [Parameter()][scriptblock]$OnProgress
    )
    process {
        $targets = Get-SafeCacheTargets
        $results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

        foreach ($target in $targets) {
            $bytesFound = [long]0
            $filesFound = 0
            $bytesDeleted = [long]0
            $filesDeleted = 0
            $lockedFiles = 0

            if ($null -ne $OnProgress) {
                & $OnProgress -Status ("正在評估: {0}" -f $target.Name)
            }

            try {
                $searchOption = if ($target.Recursive) { [System.IO.SearchOption]::AllDirectories } else { [System.IO.SearchOption]::TopDirectoryOnly }
                $dirInfo = New-Object System.IO.DirectoryInfo($target.BasePath)
                $fileEnumeration = $dirInfo.EnumerateFiles($target.FilePattern, $searchOption)

                foreach ($file in $fileEnumeration) {
                    $len = $file.Length
                    $bytesFound += $len
                    $filesFound++

                    if ($ExecuteClean) {
                        try {
                            $file.Delete()
                            $bytesDeleted += $len
                            $filesDeleted++
                        }
                        catch {
                            $lockedFiles++
                        }
                    }
                }

                # 若標記為可清理子目錄且為執行清理
                if ($ExecuteClean -and $target.IsDirectory) {
                    $subDirs = $dirInfo.EnumerateDirectories("*", [System.IO.SearchOption]::AllDirectories)
                    foreach ($d in $subDirs) {
                        try {
                            if ($d.Exists -and ($d.GetFileSystemInfos().Count -eq 0)) {
                                $d.Delete($false)
                            }
                        } catch { }
                    }
                }
            }
            catch {
                # 存取拒絕或受鎖定時優雅略過
            }

            $results.Add([PSCustomObject][ordered]@{
                Category    = [string]$target.Category
                TargetName  = [string]$target.Name
                FilesCount  = [int]$filesFound
                SizeBefore  = [string](Format-SafeBytes -Bytes $bytesFound)
                BytesFound  = [long]$bytesFound
                BytesFreed  = [long]$bytesDeleted
                FreedSize   = [string](Format-SafeBytes -Bytes $bytesDeleted)
                LockedCount = [int]$lockedFiles
                Status      = if (-not $ExecuteClean) { "預覽完畢" } elseif ($bytesDeleted -gt 0) { "已安全清理" } else { "略過/被佔用" }
            })
        }

        return $results
    }
}

# ----------------------------------------------------------------------
# 4. 啟動項審查與安全實體備份模組 (Startup Audit & Safe Backup)
# ----------------------------------------------------------------------
function Resolve-StartupCommandLine {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory = $true)][string]$RawCommand)
    process {
        $result = [PSCustomObject]@{
            ExecutablePath = [string]::Empty
            Exists         = $false
            Confidence     = "Uncertain" # Valid, HighConfidenceOrphan, NeedsManualReview
        }

        if ([string]::IsNullOrWhiteSpace($RawCommand)) { return $result }
        $trimmed = $RawCommand.Trim()

        # 1. 引號路徑匹配: "C:\Program Files\App\app.exe" /arg
        if ($trimmed.StartsWith('"')) {
            $secondQuote = $trimmed.IndexOf('"', 1)
            if ($secondQuote -gt 1) {
                $extracted = $trimmed.Substring(1, $secondQuote - 1)
                $expanded = [System.Environment]::ExpandEnvironmentVariables($extracted)
                $result.ExecutablePath = $expanded
                $result.Exists = [System.IO.File]::Exists($expanded) -or [System.IO.Directory]::Exists($expanded)
                $result.Confidence = if ($result.Exists) { "Valid" } else { "HighConfidenceOrphan" }
                return $result
            }
        }

        # 2. 包含腳本或代理調用命令 (cmd.exe, rundll32.exe, powershell.exe 等)
        $tokens = $trimmed -split '\s+'
        $firstToken = [System.Environment]::ExpandEnvironmentVariables($tokens[0])
        $systemHostTools = @("cmd.exe", "cmd", "rundll32.exe", "rundll32", "powershell.exe", "powershell", "wscript.exe", "cscript.exe")

        if ($systemHostTools -contains [System.IO.Path]::GetFileName($firstToken).ToLower()) {
            # 這是由系統組件執行的複合命令，判定風險極高，一律交給人工審查
            $result.ExecutablePath = $firstToken
            $result.Exists = $true
            $result.Confidence = "NeedsManualReview"
            return $result
        }

        # 3. 無引號漸進式比對
        $candidate = ""
        foreach ($token in $tokens) {
            $candidate = if ([string]::IsNullOrEmpty($candidate)) { $token } else { "$candidate $token" }
            $expanded = [System.Environment]::ExpandEnvironmentVariables($candidate)
            if ([System.IO.File]::Exists($expanded)) {
                $result.ExecutablePath = $expanded
                $result.Exists = $true
                $result.Confidence = "Valid"
                return $result
            }
        }

        # 4. 系統 PATH 解析
        $cmdCheck = Get-Command -Name $firstToken -CommandType Application, ExternalScript -ErrorAction SilentlyContinue
        if ($null -ne $cmdCheck) {
            $result.ExecutablePath = $cmdCheck.Source
            $result.Exists = $true
            $result.Confidence = "Valid"
            return $result
        }

        # 若均找不到，且開頭明確以磁碟代號起頭，標記為高信心孤立殘留
        if ($trimmed -match '^[a-zA-Z]:\\') {
            $result.ExecutablePath = $firstToken
            $result.Exists = $false
            $result.Confidence = "HighConfidenceOrphan"
        } else {
            $result.ExecutablePath = $firstToken
            $result.Exists = $false
            $result.Confidence = "NeedsManualReview"
        }

        return $result
    }
}

function Get-UserStartupAudit {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        $auditList = New-Object 'System.Collections.Generic.List[PSCustomObject]'

        # 審查 HKCU 登錄檔
        foreach ($cfg in $script:AppConfig.StartupRegKeys) {
            if (-not (Test-Path -Path $cfg.Path)) { continue }
            try {
                $regItem = Get-Item -Path $cfg.Path -ErrorAction Stop
                foreach ($propName in $regItem.Property) {
                    $rawVal = [string]($regItem.GetValue($propName))
                    $eval = Resolve-StartupCommandLine -RawCommand $rawVal

                    $auditList.Add([PSCustomObject][ordered]@{
                        SourceType     = "Registry"
                        Location       = [string]$cfg.Location
                        RegistryPath   = [string]$cfg.Path
                        EntryName      = [string]$propName
                        RawCommand     = [string]$rawVal
                        ResolvedTarget = [string]$eval.ExecutablePath
                        TargetExists   = [bool]$eval.Exists
                        Confidence     = [string]$eval.Confidence
                        FilePath       = [string]::Empty
                    })
                }
            } catch { }
        }

        # 審查開始功能表 Startup 資料夾
        $fPath = $script:AppConfig.StartupFolder
        if ([System.IO.Directory]::Exists($fPath)) {
            $wscriptShell = $null
            try {
                $wscriptShell = New-Object -ComObject WScript.Shell
                $files = Get-ChildItem -Path $fPath -File -ErrorAction SilentlyContinue
                foreach ($file in $files) {
                    $raw = $file.FullName
                    $resolved = $file.FullName
                    $exists = $true
                    $confidence = "Valid"

                    if ($file.Extension -eq ".lnk" -and $null -ne $wscriptShell) {
                        try {
                            $sc = $wscriptShell.CreateShortcut($file.FullName)
                            $targetPath = [System.Environment]::ExpandEnvironmentVariables($sc.TargetPath)
                            $resolved = $targetPath
                            $raw = "{0} {1}" -f $sc.TargetPath, $sc.Arguments
                            if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                                $exists = [System.IO.File]::Exists($targetPath) -or [System.IO.Directory]::Exists($targetPath)
                                $confidence = if ($exists) { "Valid" } else { "HighConfidenceOrphan" }
                            }
                        } catch {
                            $confidence = "NeedsManualReview"
                        }
                    }

                    $auditList.Add([PSCustomObject][ordered]@{
                        SourceType     = "Folder"
                        Location       = "Startup 資料夾"
                        RegistryPath   = [string]::Empty
                        EntryName      = [string]$file.Name
                        RawCommand     = [string]$raw
                        ResolvedTarget = [string]$resolved
                        TargetExists   = [bool]$exists
                        Confidence     = [string]$confidence
                        FilePath       = [string]$file.FullName
                    })
                }
            }
            finally {
                if ($null -ne $wscriptShell) {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wscriptShell) | Out-Null
                    $wscriptShell = $null
                }
            }
        }

        return $auditList
    }
}

function Remove-UserStartupOrphanSafe {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        $audit = Get-UserStartupAudit
        # 嚴格過濾：必須為 TargetExists = $false 且 Confidence = 'HighConfidenceOrphan'
        $toRemove = @($audit | Where-Object { (-not $_.TargetExists) -and ($_.Confidence -eq "HighConfidenceOrphan") })

        $results = New-Object 'System.Collections.Generic.List[PSCustomObject]'
        if ($toRemove.Count -eq 0) { return $results }

        # 建立具備時間戳記的獨立備份目錄
        $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $batchBackupDir = [System.IO.Path]::Combine($script:AppConfig.BackupRoot, "Startup_$timestamp")
        [System.IO.Directory]::CreateDirectory($batchBackupDir) | Out-Null

        # 寫入 Manifest JSON
        $manifestPath = [System.IO.Path]::Combine($batchBackupDir, "StartupManifest.json")
        $toRemove | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding UTF8

        # 逐項備份與安全刪除
        foreach ($item in $toRemove) {
            try {
                if ($item.SourceType -eq "Registry") {
                    Remove-ItemProperty -Path $item.RegistryPath -Name $item.EntryName -ErrorAction Stop
                    $results.Add([PSCustomObject][ordered]@{
                        EntryName  = [string]$item.EntryName
                        SourceType = "Registry"
                        Action     = "刪除孤立機碼"
                        Status     = "成功"
                    })
                }
                elseif ($item.SourceType -eq "Folder" -and [System.IO.File]::Exists($item.FilePath)) {
                    # 實體複製捷徑檔案至備份資料夾以供還原
                    $destFile = [System.IO.Path]::Combine($batchBackupDir, $item.EntryName)
                    [System.IO.File]::Copy($item.FilePath, $destFile, $true)
                    [System.IO.File]::Delete($item.FilePath)

                    $results.Add([PSCustomObject][ordered]@{
                        EntryName  = [string]$item.EntryName
                        SourceType = "Folder"
                        Action     = "移除捷徑並已備份"
                        Status     = "成功"
                    })
                }
            }
            catch {
                $results.Add([PSCustomObject][ordered]@{
                    EntryName  = [string]$item.EntryName
                    SourceType = [string]$item.SourceType
                    Action     = "清理失敗"
                    Status     = [string]$_.Exception.Message
                })
            }
        }

        return $results
    }
}

function Restore-UserStartupSafe {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        $results = New-Object 'System.Collections.Generic.List[PSCustomObject]'
        if (-not [System.IO.Directory]::Exists($script:AppConfig.BackupRoot)) { return $results }

        # 尋找最新的 Startup 備份批次目錄
        $backupDirs = Get-ChildItem -Path $script:AppConfig.BackupRoot -Directory -Filter "Startup_*" -ErrorAction SilentlyContinue | 
                      Sort-Object -Property CreationTime -Descending

        if ($backupDirs.Count -eq 0) { return $results }
        $latestBatch = $backupDirs[0].FullName
        $manifestPath = [System.IO.Path]::Combine($latestBatch, "StartupManifest.json")

        if (-not [System.IO.File]::Exists($manifestPath)) { return $results }

        $jsonContent = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $jsonContent

        foreach ($item in $items) {
            try {
                if ($item.SourceType -eq "Registry") {
                    Set-ItemProperty -Path $item.RegistryPath -Name $item.EntryName -Value $item.RawCommand -ErrorAction Stop
                    $results.Add([PSCustomObject][ordered]@{
                        EntryName = [string]$item.EntryName
                        Type      = "Registry"
                        Action    = "機碼值已完整還原"
                        Status    = "成功"
                    })
                }
                elseif ($item.SourceType -eq "Folder") {
                    $backupFile = [System.IO.Path]::Combine($latestBatch, $item.EntryName)
                    if ([System.IO.File]::Exists($backupFile)) {
                        $restoreDest = [System.IO.Path]::Combine($script:AppConfig.StartupFolder, $item.EntryName)
                        [System.IO.File]::Copy($backupFile, $restoreDest, $true)
                        $results.Add([PSCustomObject][ordered]@{
                            EntryName = [string]$item.EntryName
                            Type      = "Folder"
                            Action    = "捷徑實體檔案已還原"
                            Status    = "成功"
                        })
                    }
                }
            }
            catch {
                $results.Add([PSCustomObject][ordered]@{
                    EntryName = [string]$item.EntryName
                    Type      = [string]$item.SourceType
                    Action    = "還原失敗"
                    Status    = [string]$_.Exception.Message
                })
            }
        }

        return $results
    }
}

# ----------------------------------------------------------------------
# 5. HKCU 登錄檔精準備份與可逆調優 (Exact Registry Tuning & Restore)
# ----------------------------------------------------------------------
function Set-UserRegistryTuningSafe {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        if (-not [System.IO.Directory]::Exists($script:AppConfig.BackupRoot)) {
            [System.IO.Directory]::CreateDirectory($script:AppConfig.BackupRoot) | Out-Null
        }

        $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $backupFile = [System.IO.Path]::Combine($script:AppConfig.BackupRoot, "RegBackup_$timestamp.json")

        $backupPayload = New-Object 'System.Collections.Generic.List[hashtable]'
        $results = New-Object 'System.Collections.Generic.List[PSCustomObject]'

        foreach ($spec in $script:AppConfig.RegistrySpecs) {
            $path = $spec.Path
            $key = $spec.KeyName
            $target = $spec.TargetValue

            $existed = $false
            $currentVal = $null
            $currentKind = "String"

            if (Test-Path -Path $path) {
                try {
                    $prop = Get-ItemProperty -Path $path -Name $key -ErrorAction SilentlyContinue
                    if ($null -ne $prop -and $null -ne $prop.$key) {
                        $existed = $true
                        $currentVal = [string]$prop.$key
                    }
                } catch { }
            } else {
                New-Item -Path $path -Force | Out-Null
            }

            # 記錄真實狀態至備份清單
            $backupPayload.Add(@{
                Path      = $path
                KeyName   = $key
                Existed   = $existed
                OldValue  = $currentVal
                ValueKind = $currentKind
            })

            # 套用新值
            Set-ItemProperty -Path $path -Name $key -Value $target -ErrorAction SilentlyContinue

            $results.Add([PSCustomObject][ordered]@{
                SettingName = [string]$spec.Name
                BeforeValue = if ($existed) { $currentVal } else { "<原本未設定>" }
                AfterValue  = [string]$target
                Difference  = if ($existed) { "$currentVal ➔ $target" } else { "未建立 ➔ $target" }
                Status      = "已套用"
            })
        }

        # 序列化輸出
        $backupPayload | ConvertTo-Json -Depth 3 | Set-Content -Path $backupFile -Encoding UTF8
        return $results
    }
}

function Restore-UserRegistryTuningSafe {
    [CmdletBinding()]
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param()
    process {
        $results = New-Object 'System.Collections.Generic.List[PSCustomObject]'
        if (-not [System.IO.Directory]::Exists($script:AppConfig.BackupRoot)) { return $results }

        # 取得最新的一份登錄檔備份
        $backupFiles = Get-ChildItem -Path $script:AppConfig.BackupRoot -Filter "RegBackup_*.json" -ErrorAction SilentlyContinue | 
                       Sort-Object -Property CreationTime -Descending

        if ($backupFiles.Count -eq 0) { return $results }
        $targetBackup = $backupFiles[0].FullName

        $jsonText = [System.IO.File]::ReadAllText($targetBackup, [System.Text.Encoding]::UTF8)
        $items = ConvertFrom-Json -InputObject $jsonText

        foreach ($item in $items) {
            $path = $item.Path
            $key = $item.KeyName
            $existed = [bool]$item.Existed
            $oldVal = $item.OldValue

            if (-not (Test-Path -Path $path)) { continue }

            try {
                if ($existed) {
                    # 原始存在者寫回原值
                    Set-ItemProperty -Path $path -Name $key -Value $oldVal -ErrorAction Stop
                    $results.Add([PSCustomObject][ordered]@{
                        RegistryKey = "$path\$key"
                        RestoredTo  = [string]$oldVal
                        Action      = "恢復數值"
                        Status      = "成功"
                    })
                } else {
                    # 原始根本不存在者，予以刪除以維持精準契約！
                    Remove-ItemProperty -Path $path -Name $key -ErrorAction SilentlyContinue
                    $results.Add([PSCustomObject][ordered]@{
                        RegistryKey = "$path\$key"
                        RestoredTo  = "<已移除鍵值>"
                        Action      = "刪除未設定項"
                        Status      = "成功"
                    })
                }
            }
            catch {
                $results.Add([PSCustomObject][ordered]@{
                    RegistryKey = "$path\$key"
                    RestoredTo  = "還原失敗"
                    Action      = "異常"
                    Status      = [string]$_.Exception.Message
                })
            }
        }

        return $results
    }
}

# ----------------------------------------------------------------------
# 6. 程序工作集暫時修剪與 DNS 清理 (WorkingSet Trim & DNS Flush)
# ----------------------------------------------------------------------
function Optimize-UserWorkingSetSafe {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()][long]$MinWorkingSetBytes = 52428800 # 50 MB 門檻
    )
    process {
        Initialize-SafeNativeMethods

        $topList = New-Object 'System.Collections.Generic.List[PSCustomObject]'
        $processed = 0
        $skipped = 0
        $initialTotal = [long]0
        $finalTotal = [long]0

        $excluded = @("powershell", "powershell_ise", "cmd", "conhost", "explorer")
        $procs = Get-Process -ErrorAction SilentlyContinue

        foreach ($p in $procs) {
            if ($excluded -contains $p.ProcessName.ToLower() -or $p.Id -eq $PID) {
                continue
            }

            try {
                $bytesBefore = $p.WorkingSet64
                if ($bytesBefore -lt $MinWorkingSetBytes) {
                    $skipped++
                    continue
                }

                $handle = $p.Handle
                $success = [Win32ProcessMemoryHelper]::EmptyWorkingSet($handle)
                if ($success) {
                    $p.Refresh()
                    $bytesAfter = $p.WorkingSet64
                    $delta = $bytesBefore - $bytesAfter

                    $initialTotal += $bytesBefore
                    $finalTotal += $bytesAfter

                    if ($delta -gt 0) {
                        $topList.Add([PSCustomObject][ordered]@{
                            ProcessName = [string]$p.ProcessName
                            PID         = [int]$p.Id
                            BeforeSize  = [string](Format-SafeBytes -Bytes $bytesBefore)
                            AfterSize   = [string](Format-SafeBytes -Bytes $bytesAfter)
                            DeltaSize   = [string](Format-SafeBytes -Bytes $delta)
                            RawDelta    = [long]$delta
                        })
                    }
                    $processed++
                } else {
                    $skipped++
                }
            } catch {
                $skipped++
            }
        }

        $totalFreed = [Math]::Max([long]0, ($initialTotal - $finalTotal))

        return [PSCustomObject][ordered]@{
            ProcessedCount = [int]$processed
            SkippedCount   = [int]$skipped
            InitialDisplay = [string](Format-SafeBytes -Bytes $initialTotal)
            FinalDisplay   = [string](Format-SafeBytes -Bytes $finalTotal)
            FreedDisplay   = [string](Format-SafeBytes -Bytes $totalFreed)
            TopItems       = [PSCustomObject[]]($topList | Sort-Object -Property RawDelta -Descending)
        }
    }
}

function Clear-UserDnsCacheSafe {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()
    process {
        try {
            Clear-DnsClientCache -ErrorAction Stop
            return [PSCustomObject]@{ Success = $true; Method = "Clear-DnsClientCache Cmdlet"; Message = "DNS 用戶端快取已順利清空。" }
        }
        catch {
            $cmdError = $_.Exception.Message
            try {
                $p = Start-Process -FilePath "ipconfig.exe" -ArgumentList "/flushdns" -NoNewWindow -Wait -PassThru
                if ($p.ExitCode -eq 0) {
                    return [PSCustomObject]@{ Success = $true; Method = "ipconfig /flushdns"; Message = "已透過系統指令清空解析快取。" }
                } else {
                    return [PSCustomObject]@{ Success = $false; Method = "ipconfig /flushdns"; Message = ("結束碼非零 ({0})" -f $p.ExitCode) }
                }
            }
            catch {
                return [PSCustomObject]@{ Success = $false; Method = "None"; Message = ("執行失敗: {0}" -f $cmdError) }
            }
        }
    }
}

# ----------------------------------------------------------------------
# 7. WPF 現代高對比淺色介面 (Modern Light UI Controller)
# ----------------------------------------------------------------------
function Start-UserMaintenanceGui {
    [CmdletBinding()]
    param()

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows 系統維護與安全清理工具 (標準使用者權限)" 
        Height="760" Width="1180" MinHeight="600" MinWidth="940"
        WindowStartupLocation="CenterScreen" Background="#F9FAFB">
    <Window.Resources>
        <!-- 現代淺色高對比按鈕風格 -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#1F2937"/>
            <Setter Property="FontSize" Value="12.5"/>
            <Setter Property="FontFamily" Value="Segoe UI, Microsoft JhengHei UI"/>
            <Setter Property="Height" Value="34"/>
            <Setter Property="Margin" Value="0,3,0,3"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="HorizontalContentAlignment" Value="Left"/>
            <Setter Property="Padding" Value="12,0,0,0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#EFF6FF"/>
                    <Setter Property="BorderBrush" Value="#0F6CBD"/>
                    <Setter Property="Foreground" Value="#0F6CBD"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="#F3F4F6"/>
                    <Setter Property="Foreground" Value="#9CA3AF"/>
                    <Setter Property="BorderBrush" Value="#E5E7EB"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="#F0FDF4"/>
            <Setter Property="BorderBrush" Value="#86EFAC"/>
            <Setter Property="Foreground" Value="#15803D"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#DCFCE7"/>
                    <Setter Property="BorderBrush" Value="#16A34A"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="TextBlock" x:Key="GroupTitle">
            <Setter Property="Foreground" Value="#0F6CBD"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Margin" Value="4,10,0,4"/>
        </Style>
    </Window.Resources>

    <Grid Margin="14">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="320"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- 左側控制面板 -->
        <Border Grid.Column="0" Background="#FFFFFF" CornerRadius="6" Padding="14" Margin="0,0,12,0" BorderBrush="#E5E7EB" BorderThickness="1">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel>
                    <TextBlock Text="🛠️ 系統維護套件" Foreground="#111827" FontSize="17" FontWeight="Bold" Margin="4,0,0,2"/>
                    <TextBlock Text="權限邊界: 標準使用者 (無 UAC 需求)" Foreground="#6B7280" FontSize="11" Margin="4,0,0,10"/>

                    <TextBlock Text="【安全快取維護 (精準白名單)】" Style="{StaticResource GroupTitle}"/>
                    <Button Name="BtnScanCache" Content="🔍 預覽掃描快取 (僅分析不刪除)"/>
                    <Button Name="BtnClearCache" Content="🧹 執行安全快取清理 (依白名單)" Style="{StaticResource AccentButton}"/>

                    <TextBlock Text="【開機自啟項目審查】" Style="{StaticResource GroupTitle}"/>
                    <Button Name="BtnAuditStartup" Content="📋 審查開機啟動項目"/>
                    <Button Name="BtnCleanOrphanStartup" Content="🗑️ 清理高信心孤立項 (自動備份)"/>
                    <Button Name="BtnRestoreStartup" Content="↩️ 還原啟動項備份 (含捷徑檔)"/>

                    <TextBlock Text="【系統響應與暫存優化】" Style="{StaticResource GroupTitle}"/>
                    <Button Name="BtnTuneRegistry" Content="🚀 套用 HKCU 響應調整 (自動備份)"/>
                    <Button Name="BtnRestoreRegistry" Content="↩️ 精準還原登錄值 (可還原未建立)"/>
                    <Button Name="BtnTrimMemory" Content="💾 嘗試修剪程式工作集 (門檻 50MB)"/>
                    <Button Name="BtnFlushDns" Content="🌐 重新整理本機 DNS 快取"/>

                    <Separator Margin="0,16,0,10" Background="#E5E7EB"/>
                    <Button Name="BtnClearLog" Content="🧽 清除歷程記錄" Background="#FEF2F2" BorderBrush="#FECACA" Foreground="#DC2626"/>
                </StackPanel>
            </ScrollViewer>
        </Border>

        <!-- 右側歷程看板 -->
        <Grid Grid.Column="1">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- 標題欄 -->
            <Border Grid.Row="0" Background="#FFFFFF" Padding="14,10" CornerRadius="6,6,0,0" BorderBrush="#E5E7EB" BorderThickness="1,1,1,0">
                <DockPanel>
                    <TextBlock Text="執行歷程與「調整前 / 調整後」差異明細" Foreground="#111827" FontWeight="Bold" FontSize="13" VerticalAlignment="Center"/>
                    <TextBlock Name="TxtActiveTarget" Text="就緒 (Ready)" Foreground="#16A34A" FontWeight="SemiBold" HorizontalAlignment="Right" VerticalAlignment="Center" FontSize="12"/>
                </DockPanel>
            </Border>

            <!-- 等寬字體日誌框 -->
            <TextBox Name="TxtLogOutput" Grid.Row="1"
                     Background="#FFFFFF" Foreground="#1F2937"
                     FontFamily="Consolas, Cascadia Mono, Courier New" FontSize="12.5"
                     IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Auto"
                     BorderBrush="#E5E7EB" BorderThickness="1" Padding="10"/>

            <!-- 狀態列 -->
            <Border Grid.Row="2" Background="#0F6CBD" Padding="10,6" CornerRadius="0,0,6,6">
                <DockPanel>
                    <TextBlock Name="TxtStatusBar" Text="所有模組加載就緒。安全白名單防護中。" Foreground="#FFFFFF" FontSize="11.5"/>
                    <TextBlock Text="v4.5.0 (Safe Edition) | PS 5.1" Foreground="#E0E7FF" HorizontalAlignment="Right" FontSize="11.5"/>
                </DockPanel>
            </Border>
        </Grid>
    </Grid>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $btnScanCache          = $window.FindName("BtnScanCache")
    $btnClearCache         = $window.FindName("BtnClearCache")
    $btnAuditStartup       = $window.FindName("BtnAuditStartup")
    $btnCleanOrphanStartup = $window.FindName("BtnCleanOrphanStartup")
    $btnRestoreStartup     = $window.FindName("BtnRestoreStartup")
    $btnTuneRegistry       = $window.FindName("BtnTuneRegistry")
    $btnRestoreRegistry    = $window.FindName("BtnRestoreRegistry")
    $btnTrimMemory         = $window.FindName("BtnTrimMemory")
    $btnFlushDns           = $window.FindName("BtnFlushDns")
    $btnClearLog           = $window.FindName("BtnClearLog")
    $txtLogOutput          = $window.FindName("TxtLogOutput")
    $txtActiveTarget       = $window.FindName("TxtActiveTarget")
    $txtStatusBar          = $window.FindName("TxtStatusBar")

    $allButtons = @(
        $btnScanCache, $btnClearCache, $btnAuditStartup, 
        $btnCleanOrphanStartup, $btnRestoreStartup, $btnTuneRegistry, 
        $btnRestoreRegistry, $btnTrimMemory, $btnFlushDns
    )

    # UI 幫浦防卡死
    $script:PumpEvents = {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [System.Action[System.Windows.Threading.DispatcherFrame]]{ param($f) $f.Continue = $false },
            $frame
        ) | Out-Null
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }

    $script:AppendLog = {
        param([string]$Message, [string]$Level = "INFO")
        $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        $prefix = switch ($Level) {
            "SUCCESS" { "[✓ 成功]" }
            "WARN"    { "[! 注意]" }
            "ERROR"   { "[✗ 異常]" }
            default   { "[i 資訊]" }
        }
        $line = "{0} {1} {2}" -f $timestamp, $prefix, $Message

        # 保護限制：若超過最大長度，截斷最舊的一半內容
        if ($txtLogOutput.Text.Length -gt $script:AppConfig.MaxLogChars) {
            $txtLogOutput.Text = $txtLogOutput.Text.Substring($txtLogOutput.Text.Length / 2)
        }

        $txtLogOutput.AppendText($line + [System.Environment]::NewLine)
        $txtLogOutput.ScrollToEnd()
        & $script:PumpEvents
    }

    $script:ExecuteWrapper = {
        param([string]$TaskTitle, [scriptblock]$Action)
        foreach ($b in $allButtons) { $b.IsEnabled = $false }
        $txtActiveTarget.Text = "處理中: $TaskTitle"
        $txtActiveTarget.Foreground = [System.Windows.Media.Brushes]::DarkOrange
        $txtStatusBar.Text = "正在處理: $TaskTitle..."

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $script:AppendLog -Message "========== 開始作業: $TaskTitle ==========" -Level "INFO"

        try {
            & $Action
        }
        catch {
            & $script:AppendLog -Message "作業發生例外: $($_.Exception.Message)" -Level "ERROR"
        }
        finally {
            $sw.Stop()
            & $script:AppendLog -Message "========== 作業完成: $TaskTitle (耗時: $($sw.Elapsed.TotalSeconds.ToString("N2")) 秒) ==========`n" -Level "SUCCESS"
            foreach ($b in $allButtons) { $b.IsEnabled = $true }
            $txtActiveTarget.Text = "就緒 (Ready)"
            $txtActiveTarget.Foreground = [System.Windows.Media.Brushes]::Green
            $txtStatusBar.Text = "任務 [$TaskTitle] 結束。"
        }
    }

    # 1. 預覽掃描快取
    $btnScanCache.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "預覽掃描受管快取" -Action {
            $res = Invoke-SafeCacheOperation -ExecuteClean:$false -OnProgress {
                param($Status)
                $txtStatusBar.Text = $Status
                & $script:PumpEvents
            }
            if ($res.Count -gt 0) {
                & $script:AppendLog -Message "【安全快取掃描預估表 (未刪除任何檔案)】" -Level "INFO"
                $table = $res | Format-Table -AutoSize -Property Category, TargetName, FilesCount, SizeBefore, Status | Out-String
                $txtLogOutput.AppendText($table)
                $totalBytes = ($res | Measure-Object -Property BytesFound -Sum).Sum
                & $script:AppendLog -Message "預計可安全釋放空間總計: $(Format-SafeBytes -Bytes ([long]$totalBytes))" -Level "SUCCESS"
            }
        }
    })

    # 2. 執行安全清理
    $btnClearCache.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "執行安全快取清理" -Action {
            & $script:AppendLog -Message "提示: 執行中若遇到被開啟的檔案將自動略過 (保證不中斷)。" -Level "INFO"
            $res = Invoke-SafeCacheOperation -ExecuteClean:$true -OnProgress {
                param($Status)
                $txtStatusBar.Text = $Status
                & $script:PumpEvents
            }
            if ($res.Count -gt 0) {
                & $script:AppendLog -Message "【清理前容量 / 實質釋放容量 明細對照表】" -Level "INFO"
                $table = $res | Format-Table -AutoSize -Property TargetName, SizeBefore, FreedSize, LockedCount, Status | Out-String
                $txtLogOutput.AppendText($table)
                $freedBytes = ($res | Measure-Object -Property BytesFreed -Sum).Sum
                & $script:AppendLog -Message "清理作業完成！共釋放空間: $(Format-SafeBytes -Bytes ([long]$freedBytes))" -Level "SUCCESS"
            }
        }
    })

    # 3. 審查自啟項
    $btnAuditStartup.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "審查開機啟動項目" -Action {
            $audit = Get-UserStartupAudit
            if ($audit.Count -eq 0) {
                & $script:AppendLog -Message "未發現登錄在當前使用者底下的自啟項目。" -Level "INFO"
            } else {
                & $script:AppendLog -Message "【開機自啟項目審查報告】" -Level "INFO"
                $table = $audit | Format-Table -AutoSize -Property EntryName, SourceType, TargetExists, Confidence, ResolvedTarget | Out-String
                $txtLogOutput.AppendText($table)

                $highOrphans = ($audit | Where-Object { $_.Confidence -eq "HighConfidenceOrphan" }).Count
                $manualReview = ($audit | Where-Object { $_.Confidence -eq "NeedsManualReview" }).Count

                if ($highOrphans -gt 0) {
                    & $script:AppendLog -Message "發現 $highOrphans 個高信心孤立殘留項，可安全點擊清理。" -Level "WARN"
                }
                if ($manualReview -gt 0) {
                    & $script:AppendLog -Message "注意: 有 $manualReview 個項目因含複合參數，標記為「需人工確認」，系統絕不自動刪除。" -Level "INFO"
                }
            }
        }
    })

    # 4. 清理孤立項
    $btnCleanOrphanStartup.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "清理高信心孤立自啟項" -Action {
            $cleaned = Remove-UserStartupOrphanSafe
            if ($cleaned.Count -eq 0) {
                & $script:AppendLog -Message "未偵測到符合「高信心孤立」的無效項目，略過清理以維護系統穩定。" -Level "INFO"
            } else {
                & $script:AppendLog -Message "【已清理孤立項目清單】" -Level "INFO"
                $table = $cleaned | Format-Table -AutoSize -Property EntryName, SourceType, Action, Status | Out-String
                $txtLogOutput.AppendText($table)
                & $script:AppendLog -Message "清理項目已連同實體捷徑完整備份於: $($script:AppConfig.BackupRoot)" -Level "SUCCESS"
            }
        }
    })

    # 5. 還原自啟備份
    $btnRestoreStartup.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "還原開機自啟備份" -Action {
            $restored = Restore-UserStartupSafe
            if ($restored.Count -eq 0) {
                & $script:AppendLog -Message "未找到可還原之自啟項目備份檔。" -Level "WARN"
            } else {
                & $script:AppendLog -Message "【自啟備份還原結果】" -Level "INFO"
                $table = $restored | Format-Table -AutoSize -Property EntryName, Type, Action, Status | Out-String
                $txtLogOutput.AppendText($table)
                & $script:AppendLog -Message "自啟項目還原作業已結束。" -Level "SUCCESS"
            }
        }
    })

    # 6. 套用 HKCU 調優
    $btnTuneRegistry.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "套用 HKCU 響應調整" -Action {
            $res = Set-UserRegistryTuningSafe
            & $script:AppendLog -Message "【登錄值調整前 / 調整後 數值對照表】" -Level "INFO"
            $table = $res | Format-Table -AutoSize -Property SettingName, BeforeValue, AfterValue, Difference, Status | Out-String
            $txtLogOutput.AppendText($table)
            & $script:AppendLog -Message "原始數值已建立獨立時間戳記備份檔。" -Level "SUCCESS"
        }
    })

    # 7. 還原 HKCU 調優
    $btnRestoreRegistry.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "精準還原 HKCU 登錄值" -Action {
            $res = Restore-UserRegistryTuningSafe
            if ($res.Count -eq 0) {
                & $script:AppendLog -Message "未找到先前的登錄檔備份檔案。" -Level "WARN"
            } else {
                & $script:AppendLog -Message "【登錄檔精準還原對照表】" -Level "INFO"
                $table = $res | Format-Table -AutoSize -Property RegistryKey, RestoredTo, Action, Status | Out-String
                $txtLogOutput.AppendText($table)
                & $script:AppendLog -Message "已依據備份契約精準復原（原先不存在的鍵值已正確刪除）。" -Level "SUCCESS"
            }
        }
    })

    # 8. 修剪工作集
    $btnTrimMemory.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "嘗試修剪程序工作集" -Action {
            & $script:AppendLog -Message "說明: 本操作呼叫 EmptyWorkingSet 促使程序釋出閒置實體分頁，此為暫時性狀態。" -Level "INFO"
            $mem = Optimize-UserWorkingSetSafe -MinWorkingSetBytes 52428800
            if ($mem.TopItems.Count -gt 0) {
                & $script:AppendLog -Message "【修剪成效顯著之處理常式 (工作集 > 50MB)】" -Level "INFO"
                $table = $mem.TopItems | Select-Object -First 10 | 
                         Format-Table -AutoSize -Property ProcessName, PID, BeforeSize, AfterSize, DeltaSize | Out-String
                $txtLogOutput.AppendText($table)
            }
            & $script:AppendLog -Message ("總計修剪前: {0} ➔ 修剪後: {1} (暫時轉移空間: {2})" -f $mem.InitialDisplay, $mem.FinalDisplay, $mem.FreedDisplay) -Level "SUCCESS"
        }
    })

    # 9. 重新整理 DNS
    $btnFlushDns.Add_Click({
        & $script:ExecuteWrapper -TaskTitle "重新整理 DNS 快取" -Action {
            $dnsRes = Clear-UserDnsCacheSafe
            if ($dnsRes.Success) {
                & $script:AppendLog -Message ("成功: {0} (呼叫方式: {1})" -f $dnsRes.Message, $dnsRes.Method) -Level "SUCCESS"
            } else {
                & $script:AppendLog -Message ("失敗: {0} (呼叫方式: {1})" -f $dnsRes.Message, $dnsRes.Method) -Level "ERROR"
            }
        }
    })

    # 清空日誌按鈕
    $btnClearLog.Add_Click({
        $txtLogOutput.Clear()
        & $script:AppendLog -Message "歷程日誌已清空。" -Level "INFO"
    })

    & $script:AppendLog -Message "系統維護工具已就緒。介面主題: 現代淺色高對比。" -Level "INFO"
    & $script:AppendLog -Message "保護機制已生效：快取白名單化、高信心啟動項隔離、登錄可逆還原契約。" -Level "INFO"

    $window.ShowDialog() | Out-Null
}

# ----------------------------------------------------------------------
# 8. 進入點保護 (Dot-Source 與 直接執行判定)
# ----------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.' -and ($MyInvocation.Line -notmatch '^\s*\.\s+')) {
    Start-UserMaintenanceGui
}
