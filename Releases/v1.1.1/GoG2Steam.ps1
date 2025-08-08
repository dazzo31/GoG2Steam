<#
.SYNOPSIS
  Auto-add all GOG Galaxy-installed games as "Non-Steam" shortcuts in Steam.

.DESCRIPTION
  1. Reads GOG Galaxy's SQLite database to find every installed game (title + folder).
  2. Attempts to locate each game's main .exe (first trying GameTitle.exe; then the largest .exe in that folder).
  3. Backs up your existing Steam shortcuts.vdf (into config\shortcuts.vdf.bak_TIMESTAMP).
  4. Builds a brand-new shortcuts.vdf (binary) containing all GOG games.

.VERSION
  GoG2Steam v1.1.1 (2025-08-08)

.NOTES
  - Uses DatabaseFunctions.ps1 for SQLite database operations
  - Preserves existing Steam shortcuts while adding new GOG games
  - Uses GOG's PlayTasks database for authoritative executable detection
  - Includes intelligent duplicate prevention and merging
  - Tested on Windows 10/11 with Steam installed under the default path
  - PowerShell 5.1+ recommended

.CHANGELOG (summary)
  Version 1.1.1 - August 8, 2025:
  - Added unified interactive options menu (numeric input) and consistent Steam user selection
  - Improved Steam shutdown workflow with escalation and manual close loop; clean cancel on 'q'
  - Prompt to launch Steam at end of run in interactive mode
  - Simplified Steam user labels to numeric IDs (with [MostRecent]) to avoid mislabeling
  - Minor comment cleanup and transcript logging option

  Version 1.1.0 - August 3, 2025:
  - Enhanced executable detection using GOG PlayTasks with isPrimary=1
  - Added existing shortcuts preservation and intelligent merging
  - Improved validation with IsGogAuthoritative parameter
  - Enhanced string processing and VDF generation capabilities
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$SteamPath = (Join-Path ${env:ProgramFiles(x86)} "Steam"),

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$GogPath = (Join-Path ${env:ProgramFiles(x86)} "GOG Galaxy"),

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$GogDb = (Join-Path $env:ProgramData "GOG.com\Galaxy\storage\galaxy-2.0.db"),

    [Parameter(Mandatory=$false)]
    [ValidateScript({ if ($_ -eq $null -or $_ -eq '') { $true } else { $_ -match '^\d{1,20}$' } })]
    [string]$SteamUserId,

    [Parameter(Mandatory=$false)]
    [string]$NamePrefix = '',

    [Parameter(Mandatory=$false)]
    [string]$NameSuffix = '',

    [Parameter(Mandatory=$false)]
    [string]$IncludeTitlePattern,

    [Parameter(Mandatory=$false)]
    [string]$ExcludeTitlePattern,

    [Parameter(Mandatory=$false)]
    [string]$LogPath,

    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [switch]$DebugVdf,

    [Parameter(Mandatory=$false)]
    [string]$DebugTitlePattern = 'SimCity|SimCity 2000',

    [Parameter(Mandatory=$false)]
    [switch]$SkipSteamCheck,

    [Parameter(Mandatory=$false)]
    [switch]$ForceCloseSteam,

    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory=$false)]
    [switch]$SelectUser,

    [switch]$NoBackup
)

# Import function modules
$functionPath = Join-Path $PSScriptRoot 'functions'
$moduleFiles = @(
    'StringProcessing.ps1',
    'DatabaseFunctions.ps1',
    'ExecutableValidation.ps1',
    'VdfGeneration.ps1'
)

foreach ($module in $moduleFiles) {
    $modulePath = Join-Path $functionPath $module
    if (-not (Test-Path $modulePath)) {
        Write-Error "Required module not found: $module"
        throw "Missing required module: $module"
    }
    try {
        . $modulePath
    }
    catch {
        Write-Error "Error loading module $module : $_"
        throw
    }
}

# Stricter runtime behavior
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Honor -DryRun by enabling WhatIf globally within this script
if ($DryRun) { $WhatIfPreference = $true }

# Optional logging to a transcript file
$transcriptStarted = $false
if ($LogPath) {
    try {
        Start-Transcript -Path $LogPath -Append -ErrorAction Stop | Out-Null
        $transcriptStarted = $true
    } catch {
        Write-Warning "Failed to start transcript at '$LogPath': $_"
    }
}

# ===[ CONFIGURATION ]===

# Validate paths
if (-not (Test-Path $SteamPath)) {
    Write-Error "Steam installation not found at: $SteamPath"
    throw "Steam path not found"
}

if (-not (Test-Path $GogPath)) {
    Write-Error "GOG Galaxy installation not found at: $GogPath"
    throw "GOG Galaxy path not found"
}

if (-not (Test-Path $GogDb)) {
    Write-Error "GOG Galaxy database not found at: $GogDb"
    throw "GOG Galaxy database not found"
}

# Helper to parse Steam users from loginusers.vdf (with account and persona names when available)
function Get-SteamUsers {
    param(
        [Parameter(Mandatory)] [string]$SteamRoot
    )
    $loginUsersPath = Join-Path (Join-Path $SteamRoot 'config') 'loginusers.vdf'
    $users = @()
    if (Test-Path $loginUsersPath) {
        try {
            $content = Get-Content -LiteralPath $loginUsersPath -Raw -ErrorAction Stop
            $regex = '"(\d{5,20})"\s*\{([^}]*)\}'
            foreach ($m in [System.Text.RegularExpressions.Regex]::Matches($content, $regex, 'Singleline')) {
                $id = $m.Groups[1].Value
                $block = $m.Groups[2].Value
                $isMostRecent = [System.Text.RegularExpressions.Regex]::IsMatch($block, '"MostRecent"\s*"1"')
                $timestamp = 0
                $tsMatch = [System.Text.RegularExpressions.Regex]::Match($block, '"Timestamp"\s*"(\d+)"')
                if ($tsMatch.Success) { $timestamp = [int64]$tsMatch.Groups[1].Value }
                $persona = ''
                $account = ''
                $pnMatch = [System.Text.RegularExpressions.Regex]::Match($block, '"PersonaName"\s*"([^"]*)"')
                if ($pnMatch.Success) { $persona = $pnMatch.Groups[1].Value }
                $anMatch = [System.Text.RegularExpressions.Regex]::Match($block, '"AccountName"\s*"([^"]*)"')
                if ($anMatch.Success) { $account = $anMatch.Groups[1].Value }
                $users += [pscustomobject]@{ Id = $id; AccountName = $account; PersonaName = $persona; MostRecent = $isMostRecent; Timestamp = $timestamp }
            }
        } catch {
            Write-Verbose "Failed to parse loginusers.vdf: $_"
        }
    }
    # Include any additional directories under userdata not in loginusers
    $userdataPath = Join-Path $SteamRoot 'userdata'
    if (Test-Path $userdataPath) {
        foreach ($dir in Get-ChildItem -LiteralPath $userdataPath -Directory -ErrorAction SilentlyContinue) {
            if (-not ($users | Where-Object { $_.Id -eq $dir.Name })) {
                $users += [pscustomobject]@{ Id = $dir.Name; AccountName=''; PersonaName = ''; MostRecent = $false; Timestamp = ($dir.LastWriteTime).ToFileTimeUtc() }
            }
        }
    }
    return $users
}

function Get-MostRecentSteamUserId {
    param([Parameter(Mandatory)] [string]$SteamRoot)
    $users = Get-SteamUsers -SteamRoot $SteamRoot
    if (-not $users -or $users.Count -eq 0) { return $null }
    $most = $users | Where-Object { $_.MostRecent } | Select-Object -First 1
    if ($most) { return $most.Id }
    return ($users | Sort-Object Timestamp -Descending | Select-Object -First 1).Id
}

# Helper to render a consistent, simple numeric selection menu
function Select-FromList {
    param(
        [Parameter(Mandatory)] [string]$Title,
        [Parameter(Mandatory)] [string]$Prompt,
        [Parameter(Mandatory)] $Items,
        [scriptblock]$LabelSelector,
        [int]$DefaultIndex = 0
    )
    if (-not $Items) { return -1 }
    $count = ($Items | Measure-Object).Count
    if ($DefaultIndex -lt 0 -or $DefaultIndex -ge $count) { $DefaultIndex = 0 }

    Write-Host ""; Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $count; $i++) {
        $item = $Items[$i]
        $label = if ($LabelSelector) { & $LabelSelector $item } else { $item.ToString() }
        Write-Host ("{0}) {1}" -f ($i + 1), $label) -ForegroundColor White
    }
    $choice = Read-Host ("$Prompt (1-$count) [default {0}]" -f ($DefaultIndex + 1))
    if ([string]::IsNullOrWhiteSpace($choice)) { return $DefaultIndex }
    $parsed = 0
    $ok = [int]::TryParse($choice, [ref]$parsed)
    if (-not $ok) { return -1 }
    $idx = $parsed
    if ($idx -lt 1 -or $idx -gt $count) { return -1 }
    return ($idx - 1)
}

# Helper to format a user label preferring AccountName, then PersonaName, including both when different
function Format-UserLabel {
    param([Parameter(Mandatory)] $User)
    # Per user request, display only the numeric Steam user ID (plus [MostRecent] tag when applicable)
    $label = "$($User.Id)"
    if ($User.PSObject.Properties.Name -contains 'MostRecent' -and $User.MostRecent) { $label = "$label [MostRecent]" }
    return $label
}

# Interactive Steam user selector consistent with the main menu style
function Select-SteamUserInteractive {
    param([Parameter(Mandatory)] [object[]]$Users)
    if (-not $Users -or $Users.Count -eq 0) { return $null }
    $sorted = $Users | Sort-Object -Property @{Expression='MostRecent';Descending=$true}, @{Expression='Timestamp';Descending=$true}
    $default = 0
    $labeler = { param($u) Format-UserLabel -User $u }
    $sel = Select-FromList -Title 'Select Steam user' -Prompt 'Enter number' -Items $sorted -LabelSelector $labeler -DefaultIndex $default
    if ($sel -lt 0) { Write-Host 'Invalid selection.' -ForegroundColor Yellow; return $null }
    return $sorted[$sel]
}

# Helper to find fallback executable when PlayTasks is missing
function Get-FallbackExecutable {
    param(
        [Parameter(Mandatory)] [string]$InstallPath,
        [Parameter(Mandatory)] [string]$GameTitle
    )
    if (-not (Test-Path $InstallPath)) { return $null }
    try {
        $titleExe = Join-Path $InstallPath ("{0}.exe" -f ($GameTitle -replace '[^A-Za-z0-9._ -]', ''))
        if (Test-Path $titleExe -PathType Leaf) { return (Resolve-Path $titleExe).Path }
        $excludePatterns = @('updater', 'launcher', 'config', 'crash', 'support', 'vcredist')
        $candidates = Get-ChildItem -LiteralPath $InstallPath -Include *.exe -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
            $name = $_.Name.ToLowerInvariant()
            -not ($excludePatterns | ForEach-Object { $name -like "*$_*" } | Where-Object { $_ })
        }
        if ($candidates) {
            return ($candidates | Sort-Object Length -Descending | Select-Object -First 1).FullName
        }
    } catch {
        Write-Verbose "Fallback executable search failed: $_"
    }
    return $null
}

# Pre-check: ensure Steam is not running (to avoid it overwriting shortcuts.vdf)
function Ensure-SteamNotRunning {
    param(
        [switch]$SkipCheck,
        [switch]$ForceClose,
        [switch]$NonInteractive
    )
    if ($SkipCheck) { return }
    try {
        $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue)
    } catch { $procList = @() }
    if ($procList.Count -gt 0) {
        Write-Warning "Steam appears to be running. It's recommended to close it before writing shortcuts.vdf."

        if ($NonInteractive) {
            # In non-interactive mode, attempt graceful close then escalate to forceful methods if needed
            try {
                Write-Host "NonInteractive: attempting to close Steam..." -ForegroundColor Yellow
                foreach ($p in $procList) { $null = $p.CloseMainWindow() }
                try { Wait-Process -Name steam -Timeout 15 -ErrorAction SilentlyContinue } catch {}
                try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
                if ($procList.Count -gt 0) {
                    Write-Host "NonInteractive: stopping Steam process..." -ForegroundColor Yellow
                    try { Stop-Process -Name steam -ErrorAction SilentlyContinue } catch {}
                    try { Wait-Process -Name steam -Timeout 5 -ErrorAction SilentlyContinue } catch {}
                }
                try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
                if ($procList.Count -gt 0) {
                    Write-Host "NonInteractive: force-closing Steam..." -ForegroundColor Yellow
                    try { Stop-Process -Name steam -Force -ErrorAction SilentlyContinue } catch {}
                    try { Wait-Process -Name steam -Timeout 5 -ErrorAction SilentlyContinue } catch {}
                }
                try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
                if ($procList.Count -gt 0) {
                    Write-Host "NonInteractive: taskkill /F steam.exe..." -ForegroundColor Yellow
                    try { & taskkill /IM steam.exe /T /F | Out-Null } catch {}
                    Start-Sleep -Seconds 3
                }
            } catch {
                Write-Warning "Attempt to close Steam failed (continuing non-interactively): $_"
            }
            return
        }

        # Interactive behavior: inform user, attempt graceful and forceful close before requesting manual action
        Write-Host "Steam must be closed to update shortcuts. Press Enter to continue; the script will attempt to close Steam now..." -ForegroundColor Cyan
        $null = Read-Host

        try {
            # 1) Graceful window close
            foreach ($p in $procList) { $null = $p.CloseMainWindow() }
            try { Wait-Process -Name steam -Timeout 15 -ErrorAction SilentlyContinue } catch {}
        } catch {
            Write-Warning "Attempt to close Steam gracefully encountered an error: $_"
        }

        # Refresh
        try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
        if ($procList.Count -gt 0) {
            # 2) Try non-forced Stop-Process (in case CloseMainWindow didn't trigger)
            Write-Host "Steam still running; attempting to stop process..." -ForegroundColor Yellow
            try { Stop-Process -Name steam -ErrorAction SilentlyContinue } catch {}
            try { Wait-Process -Name steam -Timeout 5 -ErrorAction SilentlyContinue } catch {}
        }

        # Refresh
        try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
        if ($procList.Count -gt 0) {
            # 3) Forced Stop-Process
            Write-Host "Steam still running; forcing process termination..." -ForegroundColor Yellow
            try { Stop-Process -Name steam -Force -ErrorAction SilentlyContinue } catch {}
            try { Wait-Process -Name steam -Timeout 5 -ErrorAction SilentlyContinue } catch {}
        }

        # Refresh
        try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
        if ($procList.Count -gt 0) {
            # 4) taskkill as a last resort
            Write-Host "Steam still running; using taskkill /F ..." -ForegroundColor Yellow
            try { & taskkill /IM steam.exe /T /F | Out-Null } catch {}
            Start-Sleep -Seconds 3
        }

        # Final refresh and manual fallback
        try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
        if ($procList.Count -gt 0) {
            Write-Host "Steam did not exit automatically." -ForegroundColor Yellow
            while ($true) {
                Write-Host "Please close Steam manually now, then press Enter to continue (or type 'q' to cancel)." -ForegroundColor Yellow
                $resp = Read-Host
                if ($resp -eq 'q') { Write-Host "Cancelled: Steam must be closed to continue." -ForegroundColor Yellow; exit 1 }
                try { $procList = @(Get-Process -Name steam -ErrorAction SilentlyContinue) } catch { $procList = @() }
                if ($procList.Count -eq 0) { break }
                Write-Host "Steam is still running. Let's try again." -ForegroundColor Yellow
            }
        }

        Write-Host "Steam is not running. Proceeding..." -ForegroundColor Green
    }
}

# Seed interactive state so menu has initialized values and tests don't hit uninitialized variables
$script:SteamUserId = $SteamUserId
$script:NamePrefix = $NamePrefix
$script:NameSuffix = $NameSuffix
$script:IncludeTitlePattern = $IncludeTitlePattern
$script:ExcludeTitlePattern = $ExcludeTitlePattern
$script:NoBackup = [bool]$NoBackup
$script:DebugVdf = [bool]$DebugVdf

# Simple interactive options menu (shown unless -NonInteractive)
function Show-OptionsMenu {
    param(
        [Parameter(Mandatory)] [string]$SteamRoot
    )

    while ($true) {
        $users = Get-SteamUsers -SteamRoot $SteamRoot
        $singleUser = ($users -and ($users.Count -eq 1))
        if ($singleUser -and -not $script:SteamUserId) { $script:SteamUserId = $users[0].Id }
        $currentUserLabel = if ($script:SteamUserId) {
            $u = $users | Where-Object { $_.Id -eq $script:SteamUserId } | Select-Object -First 1
            if ($u) { Format-UserLabel -User $u } else { $script:SteamUserId }
        } elseif ($users) {
            $mr = $users | Where-Object { $_.MostRecent } | Select-Object -First 1
            if ($mr) { Format-UserLabel -User $mr } else { '(auto)' }
        } else { '(auto)' }

        $backupState = if ($script:NoBackup) { 'Off' } else { 'On' }
        $debugState = if ($script:DebugVdf) { 'On' } else { 'Off' }
        $includeState = if ($script:IncludeTitlePattern) { $script:IncludeTitlePattern } else { '(none)' }
        $excludeState = if ($script:ExcludeTitlePattern) { $script:ExcludeTitlePattern } else { '(none)' }
        $prefixState = if ($script:NamePrefix) { $script:NamePrefix } else { '(none)' }
        $suffixState = if ($script:NameSuffix) { $script:NameSuffix } else { '(none)' }
        # Render a custom multi-line menu with brief descriptions for each option
        Write-Host "" 
        Write-Host "GoG2Steam Options" -ForegroundColor Cyan
        Write-Host "Configure settings before proceeding:" -ForegroundColor Gray
        Write-Host "" 
        if ($singleUser) {
            Write-Host ("Steam user: {0} (only user detected; fixed)" -f $currentUserLabel) -ForegroundColor Gray
            Write-Host "" 
            $optNum = 1
            Write-Host ("{0}) Name Prefix (current: {1})" -f $optNum, $prefixState) -ForegroundColor White; $optNamePrefix=$optNum; $optNum++
            Write-Host "   Adds text before game names in Steam (e.g., '[GOG] ' makes 'SimCity' become '[GOG] SimCity')." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Include Title Pattern (current: {1})" -f $optNum, $includeState) -ForegroundColor White; $optInclude=$optNum; $optNum++
            Write-Host "   Only include games whose titles match this regex. Examples: '^S' (starts with S), 'City|Sim'." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Exclude Title Pattern (current: {1})" -f $optNum, $excludeState) -ForegroundColor White; $optExclude=$optNum; $optNum++
            Write-Host "   Exclude games whose titles match this regex. Examples: 'Demo|Beta', '^The'." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Backup (current: {1})" -f $optNum, $backupState) -ForegroundColor White; $optBackup=$optNum; $optNum++
            Write-Host "   Create a backup of shortcuts.vdf before writing. Recommended: keep On." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Debug Verify (current: {1})" -f $optNum, $debugState) -ForegroundColor White; $optDebug=$optNum; $optNum++
            Write-Host "   After writing, read back shortcuts.vdf and list entries (optional troubleshooting)." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Proceed" -f $optNum) -ForegroundColor White; $optProceed=$optNum; $optNum++
            Write-Host "   Add GOG games to Steam with the current settings." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("{0}) Cancel" -f $optNum) -ForegroundColor White; $optCancel=$optNum
            Write-Host "   Exit without making any changes." -ForegroundColor DarkGray
            Write-Host "" 
            $maxOpt = $optNum
            $inputChoice = Read-Host ("Enter choice (1-{0}) [default {1}]" -f $maxOpt, $optProceed)
            if ([string]::IsNullOrWhiteSpace($inputChoice)) { $inputChoice = [string]$optProceed }
            $parsed = 0
            if (-not ([int]::TryParse($inputChoice, [ref]$parsed))) { Write-Host ("Invalid input. Please enter a number from 1 to {0}." -f $maxOpt) -ForegroundColor Yellow; continue }
            $choice = $parsed
            if ($choice -lt 1 -or $choice -gt $maxOpt) { Write-Host ("Invalid choice. Please enter a number from 1 to {0}." -f $maxOpt) -ForegroundColor Yellow; continue }

            switch ($choice) {
                {$choice -eq $optNamePrefix} {
                    $script:NamePrefix = Read-Host 'Enter Name Prefix (leave blank for none)'
                    $show = if ($script:NamePrefix) { $script:NamePrefix } else { '(none)' }
                    Write-Host ("Name Prefix set to: {0}" -f $show) -ForegroundColor Green
                }
                {$choice -eq $optInclude} {
                    $script:IncludeTitlePattern = Read-Host 'Enter Include Title Regex (leave blank for none)'
                    $show = if ($script:IncludeTitlePattern) { $script:IncludeTitlePattern } else { '(none)' }
                    Write-Host ("Include Title Pattern set to: {0}" -f $show) -ForegroundColor Green
                }
                {$choice -eq $optExclude} {
                    $script:ExcludeTitlePattern = Read-Host 'Enter Exclude Title Regex (leave blank for none)'
                    $show = if ($script:ExcludeTitlePattern) { $script:ExcludeTitlePattern } else { '(none)' }
                    Write-Host ("Exclude Title Pattern set to: {0}" -f $show) -ForegroundColor Green
                }
                {$choice -eq $optBackup} {
                    $script:NoBackup = -not $script:NoBackup
                    Write-Host ("Backup is now: {0}" -f ($(if ($script:NoBackup) { 'Off' } else { 'On' }))) -ForegroundColor Green
                }
                {$choice -eq $optDebug} {
                    $script:DebugVdf = -not $script:DebugVdf
                    Write-Host ("Debug Verify is now: {0}" -f ($(if ($script:DebugVdf) { 'On' } else { 'Off' }))) -ForegroundColor Green
                }
                {$choice -eq $optProceed} { return }
                {$choice -eq $optCancel} { throw 'User cancelled from options menu' }
            }
        } else {
            Write-Host ("1) Select Steam user (current: {0})" -f $currentUserLabel) -ForegroundColor White
            Write-Host "   Choose which Steam account to add GOG games to." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("2) Name Prefix (current: {0})" -f $prefixState) -ForegroundColor White
            Write-Host "   Adds text before game names in Steam (e.g., '[GOG] ' makes 'SimCity' become '[GOG] SimCity')." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("3) Include Title Pattern (current: {0})" -f $includeState) -ForegroundColor White
            Write-Host "   Only include games whose titles match this regex. Examples: '^S' (starts with S), 'City|Sim'." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("4) Exclude Title Pattern (current: {0})" -f $excludeState) -ForegroundColor White
            Write-Host "   Exclude games whose titles match this regex. Examples: 'Demo|Beta', '^The'." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("5) Backup (current: {0})" -f $backupState) -ForegroundColor White
            Write-Host "   Create a backup of shortcuts.vdf before writing. Recommended: keep On." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host ("6) Debug Verify (current: {0})" -f $debugState) -ForegroundColor White
            Write-Host "   After writing, read back shortcuts.vdf and list entries (optional troubleshooting)." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host "7) Proceed" -ForegroundColor White
            Write-Host "   Add GOG games to Steam with the current settings." -ForegroundColor DarkGray
            Write-Host "" 
            Write-Host "8) Cancel" -ForegroundColor White
            Write-Host "   Exit without making any changes." -ForegroundColor DarkGray
            Write-Host "" 
            $inputChoice = Read-Host "Enter choice (1-8) [default 7]"
            if ([string]::IsNullOrWhiteSpace($inputChoice)) { $inputChoice = '7' }
            $parsed = 0
            if (-not ([int]::TryParse($inputChoice, [ref]$parsed))) {
                Write-Host "Invalid input. Please enter a number from 1 to 8." -ForegroundColor Yellow
                continue
            }
            $choice = $parsed
            if ($choice -lt 1 -or $choice -gt 8) {
                Write-Host "Invalid choice. Please enter a number from 1 to 8." -ForegroundColor Yellow
                continue
            }

            switch ($choice) {
                1 {
                    # Select Steam user (consistent numeric selection style)
                    if ($users -and $users.Count -gt 0) {
                        $selectedUser = Select-SteamUserInteractive -Users $users
                        if ($selectedUser) {
                            $script:SteamUserId = $selectedUser.Id
                        $label = Format-UserLabel -User $selectedUser
                        Write-Host ("Selected user: {0}" -f $label) -ForegroundColor Green
                        }
                    } else {
                        Write-Host 'No Steam users found under userdata.' -ForegroundColor Yellow
                    }
                }
                2 {
                    $script:NamePrefix = Read-Host 'Enter Name Prefix (leave blank for none)'
                    $show = if ($script:NamePrefix) { $script:NamePrefix } else { '(none)' }
                    Write-Host ("Name Prefix set to: {0}" -f $show) -ForegroundColor Green
                }
                3 {
                    $script:IncludeTitlePattern = Read-Host 'Enter Include Title Regex (leave blank for none)'
                    $show = if ($script:IncludeTitlePattern) { $script:IncludeTitlePattern } else { '(none)' }
                    Write-Host ("Include Title Pattern set to: {0}" -f $show) -ForegroundColor Green
                }
                4 {
                    $script:ExcludeTitlePattern = Read-Host 'Enter Exclude Title Regex (leave blank for none)'
                    $show = if ($script:ExcludeTitlePattern) { $script:ExcludeTitlePattern } else { '(none)' }
                    Write-Host ("Exclude Title Pattern set to: {0}" -f $show) -ForegroundColor Green
                }
                5 {
                    $script:NoBackup = -not $script:NoBackup
                    Write-Host ("Backup is now: {0}" -f ($(if ($script:NoBackup) { 'Off' } else { 'On' }))) -ForegroundColor Green
                }
                6 {
                    $script:DebugVdf = -not $script:DebugVdf
                    Write-Host ("Debug Verify is now: {0}" -f ($(if ($script:DebugVdf) { 'On' } else { 'Off' }))) -ForegroundColor Green
                }
                7 { return }
                8 { throw 'User cancelled from options menu' }
            }
        }
    }
}

# In test mode, stop execution after defining functions to allow Pester to dot-source without running
if ($env:GOG2STEAM_TEST -eq '1') { return }

# Show interactive options unless in non-interactive mode
if (-not $NonInteractive) {
    Show-OptionsMenu -SteamRoot $SteamPath
    # Apply interactive choices back to normal variables for the main flow
    if ($script:SteamUserId) { $SteamUserId = $script:SteamUserId }
    $NamePrefix = $script:NamePrefix
    $NameSuffix = $script:NameSuffix
    $IncludeTitlePattern = $script:IncludeTitlePattern
    $ExcludeTitlePattern = $script:ExcludeTitlePattern
    $NoBackup = $script:NoBackup
    $DebugVdf = $script:DebugVdf
}

# Define paths for shortcuts.vdf and create directory structure if needed
Write-Verbose "Looking for Steam userdata directory..."
Write-Host "GoG2Steam - Add your GOG games to Steam" -ForegroundColor Cyan

# Find or create Steam userdata config directory
$userdataPath = Join-Path $SteamPath "userdata"
if (-not (Test-Path $userdataPath)) {
    Write-Verbose "Creating Steam userdata directory..."
    New-Item -ItemType Directory -Path $userdataPath -Force | Out-Null
}

# Determine target user folder
$targetUserId = $SteamUserId

# Optionally allow interactive selection of user (use the same menu style)
if (-not $targetUserId -and $SelectUser -and -not $NonInteractive) {
    $users = Get-SteamUsers -SteamRoot $SteamPath
    if ($users -and $users.Count -gt 0) {
        if ($users.Count -eq 1) {
            $selected = $users[0]
            $targetUserId = $selected.Id
            $label = Format-UserLabel -User $selected
            Write-Host ("Selected user: {0} (only user detected)" -f $label) -ForegroundColor Green
        } else {
            $selected = Select-SteamUserInteractive -Users $users
            if ($selected) {
                $targetUserId = $selected.Id
                $label = Format-UserLabel -User $selected
                Write-Host ("Selected user: {0}" -f $label) -ForegroundColor Green
            }
        }
    }
}

if (-not $targetUserId) { $targetUserId = Get-MostRecentSteamUserId -SteamRoot $SteamPath }
if (-not $targetUserId) {
    # Fallback: pick most recently modified userdata folder
    $candidate = Get-ChildItem -Path $userdataPath -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { $targetUserId = $candidate.Name } else { $targetUserId = '0' }
}

$userFolderPath = Join-Path $userdataPath $targetUserId
if (-not (Test-Path $userFolderPath)) {
    Write-Verbose "Creating userdata folder for Steam user $targetUserId"
    New-Item -ItemType Directory -Path $userFolderPath -Force | Out-Null
}
Write-Host "Target Steam user: $targetUserId" -ForegroundColor Cyan

# Ensure config directory exists
$configPath = Join-Path $userFolderPath "config"
if (-not (Test-Path $configPath)) {
    Write-Verbose "Creating config directory..."
    New-Item -ItemType Directory -Path $configPath -Force | Out-Null
}

$shortcutsVdf = Join-Path $configPath "shortcuts.vdf"
Write-Verbose "Using shortcuts.vdf at: $shortcutsVdf"

# Ensure Steam is not running (or user confirmed proceeding)
Ensure-SteamNotRunning -SkipCheck:$SkipSteamCheck -ForceClose:$ForceCloseSteam -NonInteractive:$NonInteractive

# Read existing shortcuts before making any changes
# Preserves existing Steam shortcuts
$existingShortcuts = @()
if (Test-Path $shortcutsVdf) {
    Write-Host "Found existing shortcuts.vdf, reading existing shortcuts..." -ForegroundColor Cyan
    $existingShortcuts = Read-ExistingShortcuts -InputFilePath $shortcutsVdf
    Write-Host "Existing shortcuts detected: $($existingShortcuts.Count)" -ForegroundColor Green
} else {
    Write-Host "No existing shortcuts.vdf detected; a new one will be created" -ForegroundColor Yellow
}
$existingCount = if ($existingShortcuts) { $existingShortcuts.Count } else { 0 }

# ===[ MAIN WORKFLOW ]===

# Backup existing shortcuts.vdf if requested and present
if (-not $NoBackup -and (Test-Path $shortcutsVdf)) {
    $backupPath = "$shortcutsVdf.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if ($PSCmdlet.ShouldProcess($shortcutsVdf, "Backup to $backupPath")) {
        try {
            Copy-Item -LiteralPath $shortcutsVdf -Destination $backupPath -ErrorAction Stop
            Write-Host "Backed up existing shortcuts.vdf to: $backupPath" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to backup shortcuts.vdf: $_"
            Write-Warning "Continuing without backup..."
        }
    }
} else {
    Write-Verbose "No existing shortcuts.vdf to back up or backup disabled"
}


try {
    # Initialize SQLite connection using the new function
    $connection = Initialize-SQLiteConnection -GogGalaxyDb $GogDb
    
# Query for installed games using PlayTasks integration
# Uses GOG's authoritative PlayTasks data with isPrimary=1 flag
$query = @"
SELECT DISTINCT
    p.id,
    p.name,
    ld.title as display_name,
    ibp.installationPath,
    -- Use PlayTasks with isPrimary = 1 to get the authoritative executable and launch parameters
    (
        SELECT pltp.executablePath
        FROM PlayTasks pt
        JOIN PlayTaskLaunchParameters pltp ON pt.id = pltp.playTaskId
        JOIN ProductsToReleaseKeys ptrk ON pt.gameReleaseKey = ptrk.releaseKey
        WHERE ptrk.gogId = p.id AND pt.isPrimary = 1
        LIMIT 1
    ) as gogExecutablePath,
    (
        SELECT pltp.commandLineArgs
        FROM PlayTasks pt
        JOIN PlayTaskLaunchParameters pltp ON pt.id = pltp.playTaskId
        JOIN ProductsToReleaseKeys ptrk ON pt.gameReleaseKey = ptrk.releaseKey
        WHERE ptrk.gogId = p.id AND pt.isPrimary = 1
        LIMIT 1
    ) as gogCommandLineArgs
FROM Products p
JOIN InstalledProducts ip ON p.id = ip.productId
JOIN InstalledBaseProducts ibp ON ibp.productId = p.id
LEFT JOIN LimitedDetails ld ON ld.productId = p.id
WHERE ibp.installationPath IS NOT NULL
ORDER BY COALESCE(ld.title, p.name)
"@

    $games = @()
    $results = Invoke-SQLiteQuery -Connection $connection -Query $query
    $discovered = 0
    $skippedNoExe = 0
    Write-Host "`nSearching for installed GOG games..." -ForegroundColor Cyan
    foreach ($result in $results) {
        $discovered++
        Write-Host "`nFound game:" -ForegroundColor Green
        $gameName = if ($result.display_name) { $result.display_name } else { $result.name }
        Write-Host "  Title: $gameName" -ForegroundColor Yellow
        Write-Host "  Installation Path: $($result.installationPath)" -ForegroundColor Gray
        
        $mainExe = $null # Initialize mainExe

        # Initialize launch arguments
        $launchArgs = ""
        
        # Use PlayTasks with isPrimary = 1 to get the authoritative executable
        if ($result.gogExecutablePath) {
            Write-Host "  Using GOG PlayTasks primary executable: $($result.gogExecutablePath)" -ForegroundColor Magenta
            $resolvedGogExePath = $result.gogExecutablePath
            
            # Construct full path if relative
            if (-not ([System.IO.Path]::IsPathRooted($resolvedGogExePath))) {
                $resolvedGogExePath = Join-Path $result.installationPath $resolvedGogExePath
            }

            if (Test-Path $resolvedGogExePath -PathType Leaf) {
                $mainExe = Get-Item $resolvedGogExePath
                Write-Host "    Executable found: $($mainExe.FullName)" -ForegroundColor Green
                
                # Capture launch arguments if available
                if ($result.gogCommandLineArgs) {
                    $launchArgs = $result.gogCommandLineArgs
                    Write-Host "    Launch arguments: $launchArgs" -ForegroundColor Cyan
                }
            } else {
                Write-Host "    Executable path not found: $resolvedGogExePath" -ForegroundColor Red
            }
        } else {
            Write-Host "  No executable path found in GOG PlayTasks for this game." -ForegroundColor Yellow
        }

        # Fallback executable detection when PlayTasks data is missing or invalid
        if (-not $mainExe) {
            $fallbackPath = Get-FallbackExecutable -InstallPath $result.installationPath -GameTitle $gameName
            if ($fallbackPath -and (Test-Path $fallbackPath -PathType Leaf)) {
                $mainExe = Get-Item -LiteralPath $fallbackPath
                Write-Host "  Fallback executable selected: $($mainExe.FullName)" -ForegroundColor DarkCyan
            }
        }

        if ($mainExe) {
                Write-Host "  Found executable: $($mainExe.Name)" -ForegroundColor Gray
                
                $game = @{
                    name = $gameName
                    id = $result.id
                    installationPath = $result.installationPath
                    executablePath = $mainExe.FullName
                    launchArgs = $launchArgs
                }
                
                if (-not $game.executablePath -or -not $game.installationPath) {
                    Write-Host "  Skipping: Missing path information" -ForegroundColor Yellow
                    continue
                }
                
                $title = ($NamePrefix + (Clean-GameTitle -title $game.name) + $NameSuffix)
                
                # Apply title filters if provided
                if ($IncludeTitlePattern -and ($title -notmatch $IncludeTitlePattern)) {
                    Write-Host "  Skipping (does not match IncludeTitlePattern): $title" -ForegroundColor DarkYellow
                    continue
                }
                if ($ExcludeTitlePattern -and ($title -match $ExcludeTitlePattern)) {
                    Write-Host "  Skipping (matches ExcludeTitlePattern): $title" -ForegroundColor DarkYellow
                    continue
                }

                $executable = $game.executablePath
                
                # If executable came from GOG PlayTasks, it's authoritative; otherwise rely on normal validation
                $isGogAuth = ($result.gogExecutablePath -and ($mainExe.FullName -like "*$(Split-Path $result.gogExecutablePath -Leaf)"))
                if ($executable -and (Test-GameExecutable -exePath $executable -title $title -IsGogAuthoritative:$isGogAuth)) {
                    $games += @{
                        Title = $title
                        Path = $executable
                        StartDir = Split-Path $executable
                        LaunchOptions = $game.launchArgs
                    }
                    
                    if ($game.launchArgs) {
                        Write-Host "Found game: $title (with launch options: $($game.launchArgs))" -ForegroundColor Green
                    } else {
                        Write-Host "Found game: $title" -ForegroundColor Green
                    }
                }
        } else {
            Write-Host "  No suitable executable found" -ForegroundColor Yellow
            $skippedNoExe++
        }
    } # End of foreach ($result in $results)
    
    # Merge GOG games with existing shortcuts (v1.1.0 - Aug 3, 2025)
    # New intelligent merging system prevents duplicates
    if ($games.Count -gt 0) {
        Write-Host "`nMerging GOG games with existing Steam shortcuts..." -ForegroundColor Cyan
        Write-Host "  New GOG games prepared: $($games.Count)" -ForegroundColor Gray
        Write-Host "  Existing shortcuts: $existingCount" -ForegroundColor Gray
        
        # Use the merging function to avoid duplicates
        $mergeParams = @{ NewGogGames = $games }
        if ($existingShortcuts -and ($existingShortcuts.Count -gt 0)) {
            $mergeParams["ExistingShortcuts"] = $existingShortcuts
        }
        $mergedEntries = Merge-GameShortcuts @mergeParams

        # Show a concise list of what will be written
        Write-Host "\nWill write the following shortcuts:" -ForegroundColor Cyan
        foreach ($e in $mergedEntries) {
            Write-Host ("  - {0} -> {1}" -f $e.Name, $e.ExePath) -ForegroundColor Gray
        }
        
        try {
            if ($PSCmdlet.ShouldProcess($shortcutsVdf, "Write merged shortcuts ($($mergedEntries.Count))")) {
                $result = Build-ShortcutsVdf -Entries $mergedEntries -OutputFilePath $shortcutsVdf
                if ($result) {
                    Write-Host "Successfully wrote $($mergedEntries.Count) total shortcuts to shortcuts.vdf" -ForegroundColor Green
                    $mergedCount = $mergedEntries.Count
                    $addedCount = [Math]::Max(0, $mergedCount - $existingCount)
                    Write-Host "Summary: Added $addedCount, Existing $existingCount, Total $mergedCount" -ForegroundColor Cyan

                    if ($DebugVdf) {
                        Write-Host "\n[Debug] Reading back shortcuts.vdf to verify entries..." -ForegroundColor Magenta
                        $parsed = Read-ExistingShortcuts -InputFilePath $shortcutsVdf
                        Write-Host ("[Debug] Parsed entries: {0}" -f $parsed.Count) -ForegroundColor Magenta
                        if ($DebugTitlePattern) {
                            $matches = $parsed | Where-Object { $_.Name -match $DebugTitlePattern }
                            Write-Host ("[Debug] Entries matching pattern '{0}': {1}" -f $DebugTitlePattern, ($matches | Measure-Object).Count) -ForegroundColor Magenta
                            foreach ($m in $matches) {
                                Write-Host ("   • {0} -> {1}" -f $m.Name, $m.ExePath) -ForegroundColor DarkGray
                            }
                        } else {
                            foreach ($p in $parsed) {
                                Write-Host ("   • {0} -> {1}" -f $p.Name, $p.ExePath) -ForegroundColor DarkGray
                            }
                        }
                    }
                } else {
                    Write-Error "Failed to create shortcuts.vdf"
                    throw "Build-ShortcutsVdf returned failure"
                }
            } else {
                Write-Host "WhatIf: would write $($mergedEntries.Count) shortcuts to $shortcutsVdf" -ForegroundColor Cyan
                if ($DebugVdf) {
                    Write-Host "[Debug] WhatIf mode: cannot read back file, showing what would be written matching pattern..." -ForegroundColor Magenta
                    $previewMatches = if ($DebugTitlePattern) { $mergedEntries | Where-Object { $_.Name -match $DebugTitlePattern } } else { $mergedEntries }
                    foreach ($pm in $previewMatches) {
                        Write-Host ("   • {0} -> {1}" -f $pm.Name, $pm.ExePath) -ForegroundColor DarkGray
                    }
                }
            }
        }
        catch {
            Write-Error "Error generating shortcuts.vdf: $_"
            throw
        }
    } else {
        Write-Host "No GOG games found to add to Steam" -ForegroundColor Yellow
    }

    # Final summary
    Write-Host "\nDone." -ForegroundColor Green
    Write-Host ("Discovered: {0}, Prepared: {1}, Skipped (no exe): {2}" -f $discovered, $games.Count, $skippedNoExe) -ForegroundColor Cyan
    Write-Host ("Target shortcuts file: {0}" -f $shortcutsVdf) -ForegroundColor Gray

    # Offer to relaunch Steam
    if (-not $NonInteractive) {
        $steamExe = Join-Path $SteamPath 'steam.exe'
        $canLaunch = Test-Path -LiteralPath $steamExe -PathType Leaf
        $prompt = if ($canLaunch) { "Launch Steam now? [Y/n]" } else { "Press Enter to exit." }
        $resp = Read-Host $prompt
        if ($canLaunch) {
            if ([string]::IsNullOrWhiteSpace($resp) -or $resp.Trim().ToLowerInvariant().StartsWith('y')) {
                try {
                    Start-Process -FilePath $steamExe -ErrorAction Stop
                    Write-Host "Launching Steam..." -ForegroundColor Green
                } catch {
                    Write-Warning "Failed to launch Steam at '$steamExe': $_"
                }
            } else {
                Write-Host "Not launching Steam. Exiting..." -ForegroundColor Gray
            }
        }
    }
    
} catch {
    Write-Error "Error processing games: $_"
    throw
} finally {
    if ($connection) { 
        $connection.Close()
        $connection.Dispose() 
    }
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
