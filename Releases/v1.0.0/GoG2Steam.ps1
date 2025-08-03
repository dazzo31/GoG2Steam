<#
.SYNOPSIS
  Auto-add all GOG Galaxy–installed games as "Non-Steam" shortcuts in Steam.

.DESCRIPTION
  1. Reads GOG Galaxy's SQLite database to find every installed game (title + folder).
  2. Attempts to locate each game's main .exe (first trying GameTitle.exe; then the largest .exe in that folder).
  3. Backs up your existing Steam shortcuts.vdf (into config\shortcuts.vdf.bak_TIMESTAMP).
  4. Builds a brand-new shortcuts.vdf (binary) containing all GOG games.

.NOTES
  - Uses DatabaseFunctions.ps1 module for SQLite database operations
  - Overwrites your existing shortcuts.vdf. If you have other non-Steam titles, back them up or merge manually later.
  - Tested on Windows 10/11 with Steam installed under the default path.
  - PowerShell 5.1+ recommended.
#>

param(
    [string]$SteamPath = (Join-Path ${env:ProgramFiles(x86)} "Steam"),
    [string]$GogPath = (Join-Path ${env:ProgramFiles(x86)} "GOG Galaxy"),
    [string]$GogDb = (Join-Path $env:ProgramData "GOG.com\Galaxy\storage\galaxy-2.0.db"),
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
        Write-Host "Required module not found: $module" -ForegroundColor Red
        exit 1
    }
    try {
        . $modulePath
    }
    catch {
        Write-Host "Error loading module $module : $_" -ForegroundColor Red
        exit 1
    }
}

# ░░░▐ CONFIGURATION ▌░░░

# Validate paths
if (-not (Test-Path $SteamPath)) {
    Write-Host "Steam installation not found at: $SteamPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $GogPath)) {
    Write-Host "GOG Galaxy installation not found at: $GogPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $GogDb)) {
    Write-Host "GOG Galaxy database not found at: $GogDb" -ForegroundColor Red
    exit 1
}

# Define paths for shortcuts.vdf and create directory structure if needed
Write-Verbose "Looking for Steam userdata directory..."

# Find or create Steam userdata config directory
$userdataPath = Join-Path $SteamPath "userdata"
if (-not (Test-Path $userdataPath)) {
    Write-Verbose "Creating Steam userdata directory..."
    New-Item -ItemType Directory -Path $userdataPath -Force | Out-Null
}

# Look for existing userdata folders or create a new one
$userFolder = Get-ChildItem -Path $userdataPath -Directory | Select-Object -First 1
if (-not $userFolder) {
    Write-Verbose "No userdata folder found, creating default one..."
    $userFolder = New-Item -ItemType Directory -Path (Join-Path $userdataPath "0") -Force
}

# Ensure config directory exists
$configPath = Join-Path $userFolder.FullName "config"
if (-not (Test-Path $configPath)) {
    Write-Verbose "Creating config directory..."
    New-Item -ItemType Directory -Path $configPath -Force | Out-Null
}

$shortcutsVdf = Join-Path $configPath "shortcuts.vdf"
Write-Verbose "Using shortcuts.vdf at: $shortcutsVdf"

# If shortcuts.vdf exists, try to read it
$existingShortcuts = @()
if (Test-Path $shortcutsVdf) {
    Write-Verbose "Found existing shortcuts.vdf, attempting to read..."
    $existingShortcuts = Read-ExistingShortcuts -InputFilePath $shortcutsVdf
}

# ░░░▐ MAIN WORKFLOW ▌░░░

# Backup existing shortcuts.vdf if requested
if (-not $NoBackup) {
    $backupPath = "$shortcutsVdf.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    try {
        Copy-Item $shortcutsVdf $backupPath
        Write-Host "Backed up existing shortcuts.vdf to: $backupPath" -ForegroundColor Green
    } catch {
        Write-Host "Failed to backup shortcuts.vdf: $_" -ForegroundColor Yellow
        Write-Host "Continuing without backup..." -ForegroundColor Yellow
    }
}


try {
    # Initialize SQLite connection using the new function
    $connection = Initialize-SQLiteConnection -GogGalaxyDb $GogDb
    
    # Query for installed games using the new helper function
    
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
    Write-Host "`nSearching for installed GOG games..." -ForegroundColor Cyan
    foreach ($result in $results) {
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
            Write-Host "  No executable path found in GOG PlayTasks for this game." -ForegroundColor Red
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
                
                $title = Clean-GameTitle -title $game.name
                $executable = $game.executablePath
                
                if ($executable -and (Test-GameExecutable -exePath $executable -title $title)) {
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
        }
    } # End of foreach ($result in $results)
    
    # Build new shortcuts.vdf with GOG games
    if ($games.Count -gt 0) {
        # Convert games to the format expected by Build-ShortcutsVdf
        $entries = @()
        foreach ($game in $games) {
            $entries += @{
                Name = $game.Title
                ExePath = $game.Path
                StartDir = $game.StartDir
                LaunchOptions = $game.LaunchOptions
            }
        }
        
        # Add existing shortcuts to preserve them
        if ($existingShortcuts) {
            $entries += $existingShortcuts
        }
        
        try {
            $result = Build-ShortcutsVdf -Entries $entries -OutputFilePath $shortcutsVdf
            if ($result) {
                Write-Host "Successfully wrote $($games.Count) GOG games to shortcuts.vdf" -ForegroundColor Green
            } else {
                Write-Host "Failed to create shortcuts.vdf" -ForegroundColor Red
                exit 1
            }
        }
        catch {
            Write-Host "Error generating shortcuts.vdf: $_" -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "No GOG games found to add to Steam" -ForegroundColor Yellow
    }
    
} catch {
    Write-Host "Error processing games: $_" -ForegroundColor Red
    exit 1
} finally {
    if ($connection) { 
        $connection.Close()
        $connection.Dispose() 
    }
}