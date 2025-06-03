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
    ibp.installationPath
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
        
        # Look for the executable in the installation path (recursively)
        $exePath = Join-Path $result.installationPath "*.exe"
        $exeFiles = Get-ChildItem -Path $result.installationPath -Include "*.exe" -File -Recurse -ErrorAction SilentlyContinue
        
        if ($exeFiles) {
            # Filter out common installer/uninstaller executables
            $excludePatterns = @(
                'unins\d*\.exe$',
                'install.*\.exe$',
                'setup.*\.exe$',
                'launcher.*\.exe$',
                'loader\.exe$',
                'language_setup\.exe$',
                'redist\\.*\.exe$',
                '\\support\\.*\.exe$',
                'goggame-.*\.exe$',
                'dosbox\.exe$',      # Exclude DOSBox executable
                'DOSBox\.exe$',      # Case-insensitive variant
                'scummvm\.exe$',     # Exclude ScummVM executable
                'GOGDOSConfig\.exe$' # Exclude GOG DOS config tool
            )
            
            $gameExes = $exeFiles | Where-Object {
                $exclude = $false
                foreach ($pattern in $excludePatterns) {
                    if ($_.Name -match $pattern) {
                        $exclude = $true
                        break
                    }
                }
                -not $exclude
            }
            
            # Try to find the main executable
            $mainExe = $null
            
            # First try: Look for known game-specific executables
            $gameSpecificPatterns = @{
                'SimCity(TM)? 2000.*' = '(sc2000|SC2000|Sim2000|SC2K)\.exe$'  # Add SC2K.EXE pattern
                'SimCity(TM)? 3000.*' = '(sc3u|SC3U)\.exe$'
                'Fallout: London' = '(f4se_loader|fallout4|Fallout4)\.exe$'    # Will also check parent directory for Fallout 4
                'Fallout.*' = 'Fallout\d?\.exe$'
                'Z.*' = 'Z\.exe$'
                'Tomb Raider.*' = 'trl\.exe$'
                'Caesar.*' = 'c3\.exe$'
                'Pharaoh.*' = 'Pharaoh\.exe$'
                'Locomotion.*' = 'LOCO\.exe$'
                'M\.A\.X\.' = 'MAXRUN\.exe$'
                'Warcraft.*' = 'Warcraft.*BNE.*\.exe$'     # Prefer Battle.net Edition executable
            }
            
            foreach ($pattern in $gameSpecificPatterns.Keys) {
                if ($gameName -match $pattern) {
                    $mainExe = $gameExes | Where-Object { $_.Name -match $gameSpecificPatterns[$pattern] } | Select-Object -First 1
                    if ($mainExe) { break }
                }
            }
            
            # Special handling for Fallout: London - try to use Fallout 4's executable if not found
            if ($gameName -match 'Fallout: London' -and -not $mainExe) {
                $fallout4Path = Join-Path (Split-Path $result.installationPath -Parent) "Fallout 4 GOTY\Fallout4.exe"
                if (Test-Path $fallout4Path) {
                    $mainExe = Get-Item $fallout4Path
                }
            }
            
            # Second try: Look for an exe matching the game name
            if (-not $mainExe) {
                $cleanTitle = [regex]::Escape($gameName.Split(':')[0].Trim())
                $mainExe = $gameExes | Where-Object { $_.Name -match "^$cleanTitle.*\.exe$" } | Select-Object -First 1
            }
            
            # Third try: Look for common main executable names
            if (-not $mainExe) {
                $commonNames = @(
                    'game\.exe$',
                    'play\.exe$',
                    'run\.exe$',
                    '\w+run\.exe$'
                )
                foreach ($pattern in $commonNames) {
                    $mainExe = $gameExes | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
                    if ($mainExe) { break }
                }
            }
            
            # Final fallback: Use the largest exe
            if (-not $mainExe -and $gameExes) {
                $mainExe = $gameExes | Sort-Object Length -Descending | Select-Object -First 1
            }
            
            if ($mainExe) {
                Write-Host "  Found executable: $($mainExe.Name)" -ForegroundColor Gray
                
                $game = @{
                    name = $gameName
                    id = $result.id
                    installationPath = $result.installationPath
                    executablePath = $mainExe.FullName
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
                    }
                    Write-Host "Found game: $title" -ForegroundColor Green
                }
            }
        }
    }
    
    # Build new shortcuts.vdf with GOG games
    if ($games.Count -gt 0) {
        # Convert games to the format expected by Build-ShortcutsVdf
        $entries = @()
        foreach ($game in $games) {
            $entries += @{
                Name = $game.Title
                ExePath = $game.Path
                StartDir = $game.StartDir
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
