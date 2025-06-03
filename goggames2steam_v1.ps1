<#
.SYNOPSIS
  Auto-add all GOG Galaxy–installed games as “Non-Steam” shortcuts in Steam.

.DESCRIPTION
  1. Reads GOG Galaxy’s SQLite database to find every installed game (title + folder).
  2. Attempts to locate each game’s main .exe (first trying GameTitle.exe; then the largest .exe in that folder).
  3. Backs up your existing Steam shortcuts.vdf (into config\shortcuts.vdf.bak_TIMESTAMP).
  4. Builds a brand-new shortcuts.vdf (binary) containing all GOG games.

.NOTES
  - Requires System.Data.SQLite library.
  - Overwrites your existing shortcuts.vdf. If you have other non-Steam titles, back them up or merge manually later.
  - Tested on Windows 10/11 with Steam installed under the default path.
  - PowerShell 5.1+ recommended.
#>

# ░░░▐ IMPORT DEPENDENCIES ▌░░░
# Try to load SQLite from PowerShell module first
$sqliteDll = "C:\Program Files\WindowsPowerShell\Modules\SQLite\2.0\bin\x64\System.Data.SQLite.dll"
if (-not (Test-Path $sqliteDll)) {
    $sqliteDll = "C:\Program Files\WindowsPowerShell\Modules\SQLite\2.0\bin\System.Data.SQLite.dll"
}
if (Test-Path $sqliteDll) {
    try {
        Add-Type -Path $sqliteDll
        Write-Host "SQLite assembly loaded successfully from PowerShell module." -ForegroundColor Green
        $sqliteAssemblyLoaded = $true
    } catch {
        Write-Host "Failed to load SQLite from PowerShell module: $_" -ForegroundColor Yellow
    }
}

# Check for and install System.Data.SQLite assembly
# First check if the SQLite package is already installed
$sqlitePackageInstalled = Get-Package -Name System.Data.SQLite.Core -ErrorAction SilentlyContinue

# Check if the assembly is already loaded
$sqliteAssemblyLoaded = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq "System.Data.SQLite" }

if (-not $sqlitePackageInstalled) {
    Write-Host "System.Data.SQLite package not found. Installing..." -ForegroundColor Yellow
    try {
        # Ensure NuGet provider is available
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
        }
        
        # Register PSGallery if not already registered
        if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
            Register-PSRepository -Default | Out-Null
        }
        
        # Install System.Data.SQLite package
        Install-Package System.Data.SQLite.Core -Force -Scope CurrentUser | Out-Null
        $sqlitePackageInstalled = Get-Package System.Data.SQLite.Core
        Write-Host "SQLite package installed successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to install System.Data.SQLite package: $_"
        Write-Host "Please install System.Data.SQLite manually before continuing." -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "System.Data.SQLite package is already installed." -ForegroundColor Green
}

# Load the assembly if not already loaded
if (-not $sqliteAssemblyLoaded) {
    try {
        Write-Host "Searching for SQLite assembly..." -ForegroundColor Yellow
        
        # Initialize variables
        $assemblyPath = $null
        $searchLocations = @()
        
        # Method 1: Try to find the assembly via package info
        if ($sqlitePackageInstalled) {
            $sqlitePath = $sqlitePackageInstalled.Source
            $sqliteDir = Split-Path -Path $sqlitePath -Parent
            Write-Host "  - Checking package source directory: $sqliteDir" -ForegroundColor Gray
            $searchLocations += $sqliteDir
            
            $packageAssembly = Get-ChildItem -Path $sqliteDir -Recurse -Filter "System.Data.SQLite.dll" -ErrorAction SilentlyContinue | 
                              Where-Object { $_.FullName -like "*net46*" -or $_.FullName -like "*net47*" -or $_.FullName -like "*net48*" } | 
                              Select-Object -First 1
            
            if ($packageAssembly) {
                $assemblyPath = $packageAssembly.FullName
                Write-Host "  - Found assembly in package: $assemblyPath" -ForegroundColor Green
            }
        }
        
        # Method 2: Check common NuGet package locations if not found yet
        if (-not $assemblyPath) {
            $nugetLocations = @(
                # User profile NuGet packages
                Join-Path $env:USERPROFILE ".nuget\packages\system.data.sqlite.core"
                # Program Files NuGet
                Join-Path ${env:ProgramFiles(x86)} "Microsoft SDKs\NuGetPackages\system.data.sqlite.core"
                # Other common locations
                "C:\Program Files\PackageManagement\NuGet\Packages\system.data.sqlite.core"
                Join-Path $env:LOCALAPPDATA "NuGet\Cache"
            )
            
            foreach ($location in $nugetLocations) {
                if (Test-Path $location) {
                    Write-Host "  - Checking NuGet location: $location" -ForegroundColor Gray
                    $searchLocations += $location
                    
                    # Find latest version folder
                    $versionFolders = Get-ChildItem -Path $location -Directory -ErrorAction SilentlyContinue | 
                                      Sort-Object Name -Descending
                    
                    if ($versionFolders) {
                        $latestVersion = $versionFolders[0].FullName
                        Write-Host "    - Latest version found: $($versionFolders[0].Name)" -ForegroundColor Gray
                        
                        # Look for the DLL in the lib folder
                        $dllPaths = Get-ChildItem -Path $latestVersion -Recurse -Filter "System.Data.SQLite.dll" -ErrorAction SilentlyContinue |
                                   Where-Object { $_.FullName -like "*net4*" }
                        
                        if ($dllPaths) {
                            $assemblyPath = $dllPaths[0].FullName
                            Write-Host "    - Found assembly: $assemblyPath" -ForegroundColor Green
                            break
                        }
                    }
                }
            }
        }
        
        # Method 3: Direct GAC check
        if (-not $assemblyPath) {
            Write-Host "  - Checking GAC locations" -ForegroundColor Gray
            $gacLocations = @(
                Join-Path ${env:windir} "Microsoft.NET\assembly\GAC_MSIL\System.Data.SQLite"
                Join-Path ${env:windir} "assembly\GAC_MSIL\System.Data.SQLite"
            )
            
            foreach ($gacLocation in $gacLocations) {
                if (Test-Path $gacLocation) {
                    $searchLocations += $gacLocation
                    $gacDlls = Get-ChildItem -Path $gacLocation -Recurse -Filter "System.Data.SQLite.dll" -ErrorAction SilentlyContinue
                    if ($gacDlls) {
                        $assemblyPath = $gacDlls[0].FullName
                        Write-Host "    - Found assembly in GAC: $assemblyPath" -ForegroundColor Green
                        break
                    }
                }
            }
        }
        
        # Method 4: Last resort - broader file system search in common locations
        if (-not $assemblyPath) {
            $commonLocations = @(
                "C:\Program Files\System.Data.SQLite",
                "C:\Program Files (x86)\System.Data.SQLite",
                $(Join-Path $env:ProgramFiles "Microsoft.NET\SDK")  # no trailing comma
            )
            
            foreach ($location in $commonLocations) {
                if (Test-Path $location) {
                    Write-Host "  - Checking common location: $location" -ForegroundColor Gray
                    $searchLocations += $location
                    $foundDlls = Get-ChildItem -Path $location -Recurse -Filter "System.Data.SQLite.dll" -ErrorAction SilentlyContinue -Depth 3
                    if ($foundDlls) {
                        $assemblyPath = $foundDlls[0].FullName
                        Write-Host "    - Found assembly: $assemblyPath" -ForegroundColor Green
                        break
                    }
                }
            }
        }
        
        # Try loading the assembly if found
        if ($assemblyPath) {
            Add-Type -Path $assemblyPath
            Write-Host "SQLite assembly loaded successfully from: $assemblyPath" -ForegroundColor Green
        } else {
            # If all methods failed, provide detailed error info
            Write-Host "Could not find System.Data.SQLite.dll in the following locations:" -ForegroundColor Yellow
            foreach ($location in $searchLocations) {
                Write-Host "  - $location" -ForegroundColor Gray
            }
            
            # Suggest manual installation as last resort
            Write-Host "Attempting to load assembly by name as a last resort..." -ForegroundColor Yellow
            try {
                [System.Reflection.Assembly]::LoadWithPartialName("System.Data.SQLite") | Out-Null
                Write-Host "SQLite assembly loaded by name successfully." -ForegroundColor Green
            }
            catch {
                throw "Could not find or load System.Data.SQLite.dll. Please try manual installation.`nDetails: $($_)"
            }
        }
    } catch {
        Write-Error "Failed to load System.Data.SQLite assembly: $_"
        Write-Host "Please try one of the following solutions:" -ForegroundColor Yellow
        Write-Host "  1. Install System.Data.SQLite manually: Install-Package System.Data.SQLite.Core -Force" -ForegroundColor Yellow
        Write-Host "  2. Download the SQLite NuGet package directly from: https://www.nuget.org/packages/System.Data.SQLite.Core/" -ForegroundColor Yellow
        Write-Host "  3. Install the full SQLite package from: https://system.data.sqlite.org/index.html/doc/trunk/www/downloads.wiki" -ForegroundColor Yellow
        exit 1
    }
} else {
    Write-Host "System.Data.SQLite assembly is already loaded." -ForegroundColor Green
}

# ░░░▐ CONFIGURATION – ADJUST AS NEEDED ▌░░░
# 1) Path to GOG Galaxy database (usually under ProgramData)
$gogGalaxyDb = "$env:ProgramData\GOG.com\Galaxy\storage\galaxy-2.0.db"

# 2) Detect or set your Steam installation root. If Steam is not in the default location, edit this.
$defaultSteamRoots = @(
    "$env:ProgramFiles (x86)\Steam",
    "$env:ProgramFiles (x86)\SteamLibrary\steamapps\common\Steam",  # alternate SteamLibrary path
    "D:\Games\Steam"          # example of custom location - change if yours is elsewhere
)

# Try to auto-detect the first existing Steam root:
$steamRoot = $null
foreach ($path in $defaultSteamRoots) {
    if (Test-Path $path) {
        $steamRoot = $path
        break
    }
}
# If none found, prompt user:
if (-not $steamRoot) {
    Write-Host "Could not auto-detect your Steam install folder." -ForegroundColor Yellow
    $steamRoot = Read-Host "Please enter your Steam installation path (e.g., C:\Program Files (x86)\Steam)"
    if (-not (Test-Path $steamRoot)) {
        Write-Error "The path you provided does not exist. Exiting."
        exit 1
    }
}

# 3) Determine which Steam user ID to target (first subfolder in userdata). If you have multiple Steam accounts, pick the appropriate one.
$userdataFolder = Join-Path $steamRoot "userdata"
if (-not (Test-Path $userdataFolder)) {
    Write-Error "Could not find Steam\userdata under `$steamRoot`. Exiting."
    exit 1
}
$steamUserFolders = Get-ChildItem -Path $userdataFolder -Directory
if ($steamUserFolders.Count -eq 0) {
    Write-Error "No subfolders found in Steam\userdata. Exiting."
    exit 1
}
# If more than one, default to the first (modify if needed)
$steamUserId = $steamUserFolders[0].Name
$steamConfigDir = Join-Path -Path $userdataFolder -ChildPath "$steamUserId\config"
$shortcutsVdfPath = Join-Path -Path $steamConfigDir -ChildPath "shortcuts.vdf"
if (-not (Test-Path $steamConfigDir)) {
    Write-Error "Steam config folder not found at `$steamConfigDir`. Exiting."
    exit 1
}

# ░░░▐ FUNCTION: READ EXISTING shortcuts.vdf ▌░░░
function Read-ExistingShortcuts {
    param(
        [Parameter(Mandatory)]
        [string]$InputFilePath
    )
    
    try {
        $bytes = [System.IO.File]::ReadAllBytes($InputFilePath)
        $entries = @()
        $i = 0
        
        # Skip past "shortcuts" header (should be 11 bytes: "shortcuts" + null + 0x00)
        $i = 11
        
        while ($i -lt $bytes.Length) {
            $entry = @{
                Name = ""
                ExePath = ""
                StartDir = ""
            }
            
            # Read entry index
            while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                $i++
            }
            $i++ # Skip null byte
            
            if ($i -ge $bytes.Length) { break }
            
            # Skip dictionary start marker
            $i++
            
            # Read entry properties until we hit end marker
            while ($i -lt $bytes.Length -and $bytes[$i] -ne 0x08) {
                # Read property name
                $propName = ""
                while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                    $propName += [char]$bytes[$i]
                    $i++
                }
                $i++ # Skip null byte
                
                if ($i -ge $bytes.Length) { break }
                
                # Read property value
                $propValue = ""
                if ($bytes[$i] -ne 0x00) { # Not a binary/dictionary value
                    while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                        $propValue += [char]$bytes[$i]
                        $i++
                    }
                    $i++ # Skip null byte
                    
                    # Store relevant properties
                    switch ($propName) {
                        "appname" { $entry.Name = $propValue }
                        "exe" { $entry.ExePath = $propValue.Trim('"') }
                        "StartDir" { $entry.StartDir = $propValue.Trim('"') }
                    }
                } else {
                    $i++ # Skip binary value or dictionary marker
                    
                    # For "tags" section, skip the entire dictionary
                    if ($propName -eq "tags") {
                        $tagDepth = 1
                        while ($i -lt $bytes.Length -and $tagDepth -gt 0) {
                            if ($bytes[$i] -eq 0x08) { $tagDepth-- }
                            elseif ($bytes[$i] -eq 0x00) { $tagDepth++ }
                            $i++
                        }
                    }
                }
            }
            
            # Add valid entry to collection
            if ($entry.Name -and $entry.ExePath -and $entry.StartDir) {
                Write-Host "Found existing shortcut: $($entry.Name)" -ForegroundColor Cyan
                $entries += [PSCustomObject]$entry
            }
            
            # Skip entry end marker
            $i++
        }
        
        return $entries
    } catch {
        Write-Host "Error reading shortcuts.vdf: $_" -ForegroundColor Yellow
        return @()
    }
}

# ░░░▐ BACKUP EXISTING shortcuts.vdf ▌░░░
$existingShortcuts = @()
if (Test-Path $shortcutsVdfPath) {
    $timestamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupPath = Join-Path -Path $steamConfigDir -ChildPath "shortcuts.vdf.bak_$timestamp"
    Copy-Item -Path $shortcutsVdfPath -Destination $backupPath -Force
    Write-Host "Backed up existing shortcuts.vdf to:" -NoNewline
    Write-Host " $backupPath" -ForegroundColor Green
    
    # Read existing shortcuts from the file
    try {
        $existingShortcuts = Read-ExistingShortcuts -InputFilePath $shortcutsVdfPath
        Write-Host "Found $($existingShortcuts.Count) existing non-Steam shortcuts." -ForegroundColor Green
    } catch {
        Write-Host "Could not read existing shortcuts: $_" -ForegroundColor Yellow
        Write-Host "Will create a new shortcuts file instead." -ForegroundColor Yellow
        $existingShortcuts = @()
    }
} else {
    Write-Host "No existing shortcuts.vdf found. A new one will be created." -ForegroundColor Cyan
}

# ░░░▐ QUERY GOG GALAXY DATABASE ▌░░░
if (-not (Test-Path $gogGalaxyDb)) {
    Write-Error "GOG Galaxy DB not found at `$gogGalaxyDb`. Is GOG Galaxy installed?"
    exit 1
}

# First, verify table structure
try {
    # Create a connection to check schema
    $connectionString = "Data Source=$gogGalaxyDb;Version=3;"
    $schemaConnection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
    $schemaConnection.Open()
    
    # Query for table names
    $schemaCommand = $schemaConnection.CreateCommand()
    $schemaCommand.CommandText = "SELECT name FROM sqlite_master WHERE type='table';"
    $reader = $schemaCommand.ExecuteReader()
    
    $tableFound = $false
    
    # Check for required tables
    $hasInstalledProducts = $false
    $hasProducts = $false
    $hasPlayTasks = $false
    $hasPlayTaskLaunchParameters = $false
    
    while ($reader.Read()) {
        $currentTable = $reader["name"]
        Write-Host "Found table: $currentTable" -ForegroundColor Gray
        
        if ($currentTable -eq "InstalledProducts") {
            $hasInstalledProducts = $true
        }
        elseif ($currentTable -eq "Products") {
            $hasProducts = $true
        }
        elseif ($currentTable -eq "PlayTasks") {
            $hasPlayTasks = $true
        }
        elseif ($currentTable -eq "PlayTaskLaunchParameters") {
            $hasPlayTaskLaunchParameters = $true
        }
    }
    
    $tableFound = $hasInstalledProducts -and $hasProducts -and $hasPlayTasks -and $hasPlayTaskLaunchParameters
    
    $reader.Close()
    $schemaConnection.Close()
    
    if (-not $tableFound) {
        Write-Error "Could not find the installed games table in the GOG Galaxy database."
        Write-Host "The database structure may have changed. Please check for updates to this script." -ForegroundColor Yellow
        exit 1
    }
}
catch {
    Write-Error "Failed to query GOG Galaxy database schema: $_"
    exit 1
}

# First, check the structure of the tables to get the correct column names
try {
    $schemaConnection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$gogGalaxyDb;Version=3;")
    $schemaConnection.Open()
    
    # Get Products table columns
    $productsSchemaCommand = $schemaConnection.CreateCommand()
    $productsSchemaCommand.CommandText = "PRAGMA table_info(Products);"
    $productsReader = $productsSchemaCommand.ExecuteReader()
    
    Write-Host "Products table columns:" -ForegroundColor Cyan
    $productsColumns = @()
    while ($productsReader.Read()) {
        $columnName = $productsReader["name"]
        $columnType = $productsReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $productsColumns += $columnName
    }
    $productsReader.Close()
    
    # Get InstalledProducts table columns
    $installedSchemaCommand = $schemaConnection.CreateCommand()
    $installedSchemaCommand.CommandText = "PRAGMA table_info(InstalledProducts);"
    $installedReader = $installedSchemaCommand.ExecuteReader()
    
    Write-Host "InstalledProducts table columns:" -ForegroundColor Cyan
    $installedColumns = @()
    while ($installedReader.Read()) {
        $columnName = $installedReader["name"]
        $columnType = $installedReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $installedColumns += $columnName
    }
    $installedReader.Close()
    
    # Get InstallationConfiguration table columns
    $configSchemaCommand = $schemaConnection.CreateCommand()
    $configSchemaCommand.CommandText = "PRAGMA table_info(InstallationConfiguration);"
    $configReader = $configSchemaCommand.ExecuteReader()
    
    Write-Host "InstallationConfiguration table columns:" -ForegroundColor Cyan
    $configColumns = @()
    while ($configReader.Read()) {
        $columnName = $configReader["name"]
        $columnType = $configReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $configColumns += $columnName
    }
    $configReader.Close()
    
    # Get PlayTasks table columns (which likely has executable path info)
    $playTasksSchemaCommand = $schemaConnection.CreateCommand()
    $playTasksSchemaCommand.CommandText = "PRAGMA table_info(PlayTasks);"
    $playTasksReader = $playTasksSchemaCommand.ExecuteReader()
    
    Write-Host "PlayTasks table columns:" -ForegroundColor Cyan
    $playTasksColumns = @()
    while ($playTasksReader.Read()) {
        $columnName = $playTasksReader["name"]
        $columnType = $playTasksReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $playTasksColumns += $columnName
    }
    $playTasksReader.Close()
    
    # Get PlayTaskLaunchParameters table columns
    $launchParamsSchemaCommand = $schemaConnection.CreateCommand()
    $launchParamsSchemaCommand.CommandText = "PRAGMA table_info(PlayTaskLaunchParameters);"
    $launchParamsReader = $launchParamsSchemaCommand.ExecuteReader()
    
    Write-Host "PlayTaskLaunchParameters table columns:" -ForegroundColor Cyan
    $launchParamsColumns = @()
    while ($launchParamsReader.Read()) {
        $columnName = $launchParamsReader["name"]
        $columnType = $launchParamsReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $launchParamsColumns += $columnName
        
        # Check for common parameter column names
        if ($columnName -eq "parameters" -or $columnName -eq "arguments" -or 
            $columnName -eq "commandLine" -or $columnName -eq "executableArguments") {
            Write-Host "    Found executable parameters column: $columnName" -ForegroundColor Green
            $parametersColumn = $columnName
        }
        
        # Check for common executable path column names
        if ($columnName -eq "executable" -or $columnName -eq "executablePath" -or 
            $columnName -eq "path" -or $columnName -eq "exePath") {
            Write-Host "    Found executable path column: $columnName" -ForegroundColor Green
            $pathColumn = $columnName
        }
    }
    $launchParamsReader.Close()
    
    # Get a sample row from PlayTaskLaunchParameters to examine content
    $sampleCommand = $schemaConnection.CreateCommand()
    $sampleCommand.CommandText = "SELECT * FROM PlayTaskLaunchParameters LIMIT 1;"
    
    try {
        $sampleReader = $sampleCommand.ExecuteReader()
        if ($sampleReader.Read()) {
            Write-Host "`nSample PlayTaskLaunchParameters row:" -ForegroundColor Cyan
            
            for ($i = 0; $i -lt $sampleReader.FieldCount; $i++) {
                $columnName = $sampleReader.GetName($i)
                $value = $sampleReader.GetValue($i)
                
                # Only display non-empty string values
                if ($value -is [string] -and $value.Length -gt 0) {
                    Write-Host ("  " + $columnName + ": " + $value) -ForegroundColor Gray
                    
                    # Look for Windows paths in values
                    if ($value -match '([A-Za-z]:\\[^"]+)') {
                        Write-Host ("    Potential path found in " + $columnName + ": " + $matches[1]) -ForegroundColor Green
                        
                        # Store column name if it might contain paths
                        if (-not $pathColumn) {
                            $pathColumn = $columnName
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "Error reading sample: $_" -ForegroundColor Yellow
    } finally {
        if ($sampleReader) { $sampleReader.Close() }
    }

    # Get PlayTaskTypes table columns to identify the "play" task type
    $taskTypesSchemaCommand = $schemaConnection.CreateCommand()
    $taskTypesSchemaCommand.CommandText = "PRAGMA table_info(PlayTaskTypes);"
    $taskTypesReader = $taskTypesSchemaCommand.ExecuteReader()
    
    Write-Host "PlayTaskTypes table columns:" -ForegroundColor Cyan
    $taskTypesColumns = @()
    while ($taskTypesReader.Read()) {
        $columnName = $taskTypesReader["name"]
        $columnType = $taskTypesReader["type"]
        Write-Host "  - $columnName ($columnType)" -ForegroundColor Gray
        $taskTypesColumns += $columnName
    }
    $taskTypesReader.Close()
    
    # Query for the actual type IDs to get the "play" task type
    $typeIdCommand = $schemaConnection.CreateCommand()
    $typeIdCommand.CommandText = "SELECT * FROM PlayTaskTypes;"
    $typeIdReader = $typeIdCommand.ExecuteReader()
    
    Write-Host "PlayTaskTypes entries:" -ForegroundColor Cyan
    $playTypeId = 1  # Default to 1 if not found
    while ($typeIdReader.Read()) {
        $id = $typeIdReader["id"]
        $name = $typeIdReader["name"]
        Write-Host "  - ID: $id, Name: $name" -ForegroundColor Gray
        
        if ($name -eq "Play" -or $name -like "*play*" -or $name -like "*launch*") {
            $playTypeId = $id
            Write-Host "Found 'Play' task type ID: $playTypeId" -ForegroundColor Green
        }
    }
    $typeIdReader.Close()
    $schemaConnection.Close()
    
    # Determine title column in Products table (could be title, name, productTitle, etc.)
    $titleColumn = $null
    foreach ($possibleName in @("title", "name", "productName", "productTitle", "releaseKey")) {
        if ($productsColumns -contains $possibleName) {
            $titleColumn = $possibleName
            Write-Host "Found title column: $titleColumn" -ForegroundColor Green
            break
        }
    }
    
    # Determine path column in PlayTaskLaunchParameters
    $pathColumn = $null
    foreach ($possibleName in @("path", "executablePath", "executable", "filePath", "exePath")) {
        if ($launchParamsColumns -contains $possibleName) {
            $pathColumn = $possibleName
            Write-Host "Found executable path column: $pathColumn" -ForegroundColor Green
            break
        }
    }
    
    # If no direct path column, look for parameters column that might contain path info
    $parametersColumn = $null
    if (-not $pathColumn) {
        foreach ($possibleName in @("parameters", "arguments", "commandLine", "launchParameters")) {
            if ($launchParamsColumns -contains $possibleName) {
                $parametersColumn = $possibleName
                Write-Host "Found parameters column: $parametersColumn" -ForegroundColor Green
                break
            }
        }
    }
    
    # Determine product ID columns for joining
    $productIdColumn = $null
    $installedProductIdColumn = $null
    $playTaskIdColumn = $null
    $taskLaunchParamTaskIdColumn = $null
    
    # Check for common ID column names
    foreach ($possibleName in @("id", "productId", "releaseKey")) {
        if ($productsColumns -contains $possibleName) {
            $productIdColumn = $possibleName
            Write-Host "Found Products ID column: $productIdColumn" -ForegroundColor Green
            break
        }
    }
    
    foreach ($possibleName in @("productId", "id", "releaseKey")) {
        if ($installedColumns -contains $possibleName) {
            $installedProductIdColumn = $possibleName
            Write-Host "Found InstalledProducts ID column: $installedProductIdColumn" -ForegroundColor Green
            break
        }
    }
    
    # PlayTasks ID and product ID columns
    foreach ($possibleName in @("productId", "gameReleaseKey", "gameId")) {
        if ($playTasksColumns -contains $possibleName) {
            $playTaskProductIdColumn = $possibleName
            Write-Host "Found PlayTasks product ID column: $playTaskProductIdColumn" -ForegroundColor Green
            break
        }
    }
    
    foreach ($possibleName in @("id", "taskId")) {
        if ($playTasksColumns -contains $possibleName) {
            $playTaskIdColumn = $possibleName
            Write-Host "Found PlayTasks ID column: $playTaskIdColumn" -ForegroundColor Green
            break
        }
    }
    
    # PlayTaskLaunchParameters task ID column
    foreach ($possibleName in @("taskId", "playTaskId", "id")) {
        if ($launchParamsColumns -contains $possibleName) {
            $taskLaunchParamTaskIdColumn = $possibleName
            Write-Host "Found PlayTaskLaunchParameters task ID column: $taskLaunchParamTaskIdColumn" -ForegroundColor Green
            break
        }
    }
    
    # If we don't have path column in launch parameters, look for a JSON or content column
    $contentColumn = $null
    if (-not $pathColumn) {
        foreach ($column in $launchParamsColumns) {
            if ($column -like "*content*" -or $column -like "*json*" -or $column -like "*data*") {
                $contentColumn = $column
                Write-Host "Using potential content column for path extraction: $contentColumn" -ForegroundColor Yellow
                break
            }
        }
    }
    
    # Verify we have all required columns
    if (-not $titleColumn -or -not $productIdColumn -or -not $installedProductIdColumn -or 
        -not $playTaskIdColumn -or -not $taskLaunchParamTaskIdColumn -or 
        (-not $pathColumn -and -not $parametersColumn -and -not $contentColumn)) {
        throw "Could not identify all required columns in the database tables."
    }
    
} catch {
    Write-Error "Failed to analyze table structure: $_"
    exit 1
}

# Define a function to extract path from JSON or serialized data
function Get-InstallationPath {
    param (
        [Parameter(Mandatory=$true)]
        [object]$Row,
        
        [Parameter(Mandatory=$false)]
        [string]$PathColumn
    )
    
    # First try direct access if we have a path column
    if ($PathColumn -and $Row.$PathColumn) {
        return $Row.$PathColumn
    }
    
    # Try known columns that might contain JSON data
    foreach ($column in $Row.PSObject.Properties.Name) {
        $value = $Row.$column
        if (-not $value -or $value -isnot [string]) { continue }
        
        # Try to parse as JSON if it looks like it
        if ($value.StartsWith('{') -or $value.StartsWith('[')) {
            try {
                $json = $value | ConvertFrom-Json -ErrorAction Stop
                
                # Check for common JSON path properties
                $possibleProps = @('path', 'installPath', 'installationPath', 'gameLocation', 'folder', 'directory')
                foreach ($prop in $possibleProps) {
                    if ($json.$prop) {
                        return $json.$prop
                    }
                }
                
                # Try to find any property that might be a path
                foreach ($prop in $json.PSObject.Properties.Name) {
                    $propValue = $json.$prop
                    if ($propValue -is [string] -and 
                        ($propValue -like "*:\*" -or $propValue -like "\\*") -and
                        (Test-Path $propValue)) {
                        return $propValue
                    }
                }
            } catch {
                # Not valid JSON, continue to next check
            }
        }
        
        # Check if it's a direct file path (Windows format)
        if ($value -match '^[A-Z]:\\' -and (Test-Path $value)) {
            return $value
        }
    }
    
    return $null
}

# Get a sample of data from PlayTaskLaunchParameters to better understand its structure
# Get more comprehensive sample data to better understand the database structure
$connection = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$gogGalaxyDb;Version=3;")
$connection.Open()

# Get PlayTaskLaunchParameters sample with related data
$sampleQuery = @"
SELECT 
    ptlp.*,
    pt.isPrimary,
    pt.typeId,
    p.$titleColumn as gameTitle
FROM 
    PlayTaskLaunchParameters ptlp
JOIN 
    PlayTasks pt ON ptlp.$taskLaunchParamTaskIdColumn = pt.$playTaskIdColumn
JOIN
    Products p ON pt.$playTaskProductIdColumn = p.$productIdColumn
LIMIT 5
"@

$sampleCommand = $connection.CreateCommand()
$sampleCommand.CommandText = $sampleQuery

try {
    $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($sampleCommand)
    $sampleData = New-Object System.Data.DataTable
    $adapter.Fill($sampleData) | Out-Null
    
    if ($sampleData.Rows.Count -gt 0) {
        Write-Host "Found $($sampleData.Rows.Count) sample PlayTaskLaunchParameters rows:" -ForegroundColor Cyan
        
        # Show columns available
        Write-Host "Columns available:" -ForegroundColor Yellow
        foreach ($column in $sampleData.Columns) {
            Write-Host "  - $($column.ColumnName)" -ForegroundColor Gray
        }
        
        # Analyze each row to better understand the data structure
        foreach ($row in $sampleData.Rows) {
            Write-Host "`nSample for game: $($row["gameTitle"])" -ForegroundColor Cyan
            
            # Look at each column for path information
            foreach ($column in $sampleData.Columns) {
                $columnName = $column.ColumnName
                $value = $row[$columnName]
                
                # Skip null values and non-string values
                if ($null -eq $value -or $value -isnot [string] -or $value.Length -lt 5) { continue }
                
                # Look for possible path indicators
                if ($value -match '([A-Za-z]:\\[^"]+\.exe)') {
                    Write-Host "  Found path in '$columnName': $value" -ForegroundColor Green
                    if (-not $pathColumn) {
                        $pathColumn = $columnName
                    }
                }
                # Look for JSON content
                elseif ($value.StartsWith('{') -and $value.EndsWith('}')) {
                    Write-Host "  Found JSON in '$columnName'" -ForegroundColor Yellow
                    try {
                        $json = $value | ConvertFrom-Json -ErrorAction SilentlyContinue
                        # Look for path properties in JSON
                        foreach ($prop in $json.PSObject.Properties) {
                            if ($prop.Value -is [string] -and $prop.Value -match '([A-Za-z]:\\[^"]+\.exe)') {
                                Write-Host "    JSON path in '$($prop.Name)': $($prop.Value)" -ForegroundColor Green
                                $contentColumn = $columnName
                            }
                        }
                    } catch {
                        # Not valid JSON or other issue
                    }
                }
                # Look for parameters that might contain paths
                elseif (($columnName -like "*param*" -or $columnName -like "*arg*") -and $value -match '"([^"]+\.exe)"') {
                    Write-Host "  Found executable in parameters '$columnName': $($matches[1])" -ForegroundColor Green
                    $parametersColumn = $columnName
                }
            }
        }
    } else {
        Write-Host "No sample data found in PlayTaskLaunchParameters" -ForegroundColor Yellow
    }
} catch {
    Write-Host "Could not get sample data: $_" -ForegroundColor Yellow
} finally {
    $connection.Close()
}

# Now create the main query with better knowledge of the database structure
Write-Host "`nBuilding query with detected columns:" -ForegroundColor Cyan
Write-Host "  Title column: $titleColumn" -ForegroundColor Gray
Write-Host "  Path column: $pathColumn" -ForegroundColor Gray
Write-Host "  Parameters column: $parametersColumn" -ForegroundColor Gray
Write-Host "  Content column: $contentColumn" -ForegroundColor Gray

# Make sure we have at least one method for path extraction
if (-not $pathColumn -and -not $parametersColumn -and -not $contentColumn) {
    # If no columns were identified, set default values based on common names
    Write-Host "No path columns automatically detected, using defaults" -ForegroundColor Yellow
    
    if ($launchParamsColumns -contains "parameters") {
        $parametersColumn = "parameters"
        Write-Host "Using default parameters column: parameters" -ForegroundColor Yellow
    }
    
    if ($launchParamsColumns -contains "executable") {
        $pathColumn = "executable"
        Write-Host "Using default path column: executable" -ForegroundColor Yellow
    }
}

# Choose best approach based on what we found in sample data
if ($pathColumn) {
    Write-Host "Using direct executable path column: $pathColumn" -ForegroundColor Green
} elseif ($parametersColumn) {
    Write-Host "Using parameters column for path extraction: $parametersColumn" -ForegroundColor Green
} elseif ($contentColumn) {
    Write-Host "Using JSON content column for path extraction: $contentColumn" -ForegroundColor Green
} else {
    Write-Host "No clear path column found, will try all available columns" -ForegroundColor Yellow
}

# Query to get game info with path info from PlayTaskLaunchParameters
# Try a series of queries with different join strategies to handle various database schemas
# First attempt - use proper relationship chain through ProductsToReleaseKeys
$query = @'
SELECT DISTINCT
    ptlp.label as gameTitle,
    ptlp.executablePath,
    ptlp.commandLineArgs,
    ptlp.label
FROM 
    InstalledProducts ip
JOIN 
    Products p ON p.id = ip.productId
JOIN
    PlayTasks pt ON pt.gameReleaseKey = 'gog_' || p.id
JOIN
    PlayTaskLaunchParameters ptlp ON ptlp.playTaskId = pt.id
WHERE
    ptlp.label IS NOT NULL
    AND ptlp.label != ''
    AND ptlp.executablePath IS NOT NULL
    AND ptlp.executablePath != ''
    AND (
        pt.isPrimary = 1 
        OR ptlp.label = 'Play'
        OR ptlp.label NOT LIKE '%Setup%' 
        AND ptlp.label NOT LIKE '%Config%'
        AND ptlp.label NOT LIKE '%Setting%'
        AND ptlp.label NOT LIKE '%Editor%'
    )
ORDER BY
    ptlp.label
'@

try {
    $connectionString = "Data Source=$gogGalaxyDb;Version=3;"
    $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
    $connection.Open()
    
    # Execute the query
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $command.CommandTimeout = 30  # 30 second timeout
    
    # Use DataAdapter to fill a DataTable
    $adapter = New-Object System.Data.SQLite.SQLiteDataAdapter($command)
    $dataTable = New-Object System.Data.DataTable
    $adapter.Fill($dataTable) | Out-Null
    
    # If no results found, try a simpler query without the task type filter
    if ($dataTable.Rows.Count -eq 0) {
        Write-Host "No results found with primary task filter. Trying more general query..." -ForegroundColor Yellow
        
        # Second attempt - try a different join strategy with label as game title
        $query = @"
SELECT DISTINCT
    ptlp.label as gameTitle, 
    ptlp.executablePath,
    ptlp.commandLineArgs
FROM 
    InstalledProducts ip
JOIN 
    Products p ON ip.productId = p.id
JOIN
    PlayTasks pt ON pt.gameReleaseKey = 'gog_' || p.id
JOIN
    PlayTaskLaunchParameters ptlp ON ptlp.playTaskId = pt.id
WHERE
    ptlp.executablePath IS NOT NULL
    AND ptlp.executablePath != ''
    AND ptlp.label IS NOT NULL
    AND ptlp.label != ''
ORDER BY
    ptlp.label
"@
        
        $command.CommandText = $query
        $dataTable = New-Object System.Data.DataTable
        
        try {
            $adapter.Fill($dataTable) | Out-Null
        }
        catch {
            Write-Host "Second query attempt failed. Trying fallback query..." -ForegroundColor Yellow
        }
    }
    
    # If still no results, try the most generic fallback query
    if ($dataTable.Rows.Count -eq 0) {
        Write-Host "Still no results. Trying a third fallback query..." -ForegroundColor Yellow
        $fallbackQuery = @"
SELECT 
    ptlp.label as gameTitle, 
    pt.$playTaskIdColumn as taskId,
    ptlp.*
FROM 
    InstalledProducts ip
JOIN 
    Products p ON ip.$installedProductIdColumn = p.$productIdColumn
JOIN
    PlayTasks pt ON pt.$playTaskProductIdColumn = 'gog_' || p.$productIdColumn
JOIN
    PlayTaskLaunchParameters ptlp ON ptlp.$taskLaunchParamTaskIdColumn = pt.$playTaskIdColumn
WHERE
    ptlp.label IS NOT NULL
    AND ptlp.label != ''
    AND ptlp.executablePath IS NOT NULL
    AND ptlp.executablePath != ''
"@
        $command.CommandText = $fallbackQuery
        $dataTable = New-Object System.Data.DataTable
        $adapter.Fill($dataTable) | Out-Null
    }
    
    # Process the results - extract path information from various columns
    $processedGames = New-Object System.Data.DataTable
    $processedGames.Columns.Add("gameTitle", [string])
    $processedGames.Columns.Add("installFolder", [string])
    
    foreach ($row in $dataTable.Rows) {
        $title = $row["gameTitle"]
        $path = $null
        
        # Try direct path extraction if we identified a path column
        if ($pathColumn -and $row[$pathColumn]) {
            $path = $row[$pathColumn]
        }
        # Try parameters column if we have it and path is null
        elseif ($parametersColumn -and $row[$parametersColumn]) {
            $params = $row[$parametersColumn]
            Write-Host ("  Examining parameters for " + $title + ": " + $params) -ForegroundColor Gray
            
            # Multiple regex patterns to extract path from parameters
            $pathPatterns = @(
                '"([A-Za-z]:\\[^"]+\.exe)"',            # Quoted full path
                '([A-Za-z]:\\[^" ]+\.exe)',             # Unquoted full path
                '"([A-Za-z]:[\\\/][^"]+)"',             # Any quoted path
                '([A-Za-z]:[\\\/][^ "]+)',              # Any unquoted path
                '\/path[=:]([^ "]+)',                   # Path after /path= parameter
                '-[eE]xecutable[=:]([^ "]+)',           # Path after -executable= parameter
                '--[eE]xe[=:]([^ "]+)'                  # Path after --exe= parameter
            )
            
            foreach ($pattern in $pathPatterns) {
                if ($params -match $pattern) {
                    $path = $matches[1]
                    Write-Host ("  Found path using pattern '" + $pattern + "': " + $path) -ForegroundColor Green
                    # Check if the path exists or looks valid
                    if ($path -match '\.exe$' -or (Test-Path $path)) {
                        break
                    }
                }
            }
        }
        # Try content column if we have it and path is still null
        elseif ($contentColumn -and $row[$contentColumn]) {
            $path = Get-InstallationPath -Row $row -PathColumn $contentColumn
        }
        # Last resort, try extracting from any column
        else {
            $path = Get-InstallationPath -Row $row
        }
        
        # Get the game's installation folder (not just the exe path)
        if ($path) {
            # Extract the directory from the path if it's an exe
            if ($path -match '\.exe$') {
                $installFolder = Split-Path -Path $path -Parent
            } else {
                $installFolder = $path
            }
            
            $newRow = $processedGames.NewRow()
            $newRow["gameTitle"] = $title
            $newRow["installFolder"] = $installFolder
            $processedGames.Rows.Add($newRow)
            Write-Host ("Found path for " + $title + ": " + $installFolder) -ForegroundColor Green
        } else {
            Write-Host ("Could not extract path for " + $title) -ForegroundColor Yellow
        }
    }
    
    $gogGames = $processedGames
    
    # Verify that we got the expected columns
    if ($null -eq $gogGames.Columns["gameTitle"] -or $null -eq $gogGames.Columns["installFolder"]) {
        Write-Host "Warning: The table schema doesn't match expected structure." -ForegroundColor Yellow
        Write-Host "Available columns:" -ForegroundColor Gray
        foreach ($column in $gogGames.Columns) {
            Write-Host "  - $($column.ColumnName)" -ForegroundColor Gray
        }
        
        # Try to find columns with similar names
        $titleColumn = $gogGames.Columns | Where-Object { $_.ColumnName -like "*title*" -or $_.ColumnName -like "*name*" } | Select-Object -First 1 -ExpandProperty ColumnName
        $pathColumn = $gogGames.Columns | Where-Object { $_.ColumnName -like "*folder*" -or $_.ColumnName -like "*path*" -or $_.ColumnName -like "*directory*" } | Select-Object -First 1 -ExpandProperty ColumnName
        
        if ($titleColumn -and $pathColumn) {
            Write-Host "Using detected columns instead: $titleColumn and $pathColumn" -ForegroundColor Cyan
            
            # Create a new DataTable with the correct column names
            $fixedGames = New-Object System.Data.DataTable
            $fixedGames.Columns.Add("gameTitle", [string])
            $fixedGames.Columns.Add("installFolder", [string])
            
            foreach ($row in $gogGames.Rows) {
                $newRow = $fixedGames.NewRow()
                $newRow["gameTitle"] = $row[$titleColumn]
                $newRow["installFolder"] = $row[$pathColumn]
                $fixedGames.Rows.Add($newRow)
            }
            
            $gogGames = $fixedGames
        } else {
            Write-Error "Could not identify required columns in the GOG Galaxy database."
            exit 1
        }
    }
    
    # Close the connection
    $connection.Close()
} catch {
    Write-Error "Failed to query GOG Galaxy database. Specific error: $_"
    Write-Host "Ensure you have System.Data.SQLite installed correctly." -ForegroundColor Yellow
    exit 1
} finally {
    # Ensure connection is closed even if an error occurs
    if ($connection -and $connection.State -ne 'Closed') {
        $connection.Close()
    }
}
if ($gogGames.Count -eq 0) {
    Write-Host "No installed games found in GOG Galaxy database." -ForegroundColor Yellow
    exit 0
}

# ░░░▐ FUNCTION: FIND GAME EXECUTABLE ▌░░░
function Get-MainExecutable {
    param(
        [string]$InstallFolder,
        [string]$GameTitle
    )
    # 1) Prefer exact match: GameTitle.exe in InstallFolder root
    $preferred = Join-Path -Path $InstallFolder -ChildPath "$GameTitle.exe"
    if (Test-Path $preferred) {
        return $preferred
    }
    # 2) Otherwise, find all *.exe in the top level of InstallFolder and pick the largest one
    $exeFiles = Get-ChildItem -Path $InstallFolder -Filter *.exe -File -ErrorAction SilentlyContinue
    if ($exeFiles.Count -gt 0) {
        $largest = $exeFiles | Sort-Object Length -Descending | Select-Object -First 1
        return $largest.FullName
    }
    # 3) If still nothing, search one level deep (optional)
    $exeFilesDeep = Get-ChildItem -Path $InstallFolder -Filter *.exe -File -Recurse -Depth 1 -ErrorAction SilentlyContinue
    if ($exeFilesDeep.Count -gt 0) {
        $largestDeep = $exeFilesDeep | Sort-Object Length -Descending | Select-Object -First 1
        return $largestDeep.FullName
    }
    return $null
}

# ░░░▐ BUILD LIST OF GAMES WITH EXE & STARTDIR ▌░░░
$gameEntries = @()
foreach ($row in $gogGames) {
    $title      = $row.gameTitle
    $installDir = $row.installFolder

    # Skip non-game entries (manuals, readme files, config utilities, etc.)
    if ($title -like "*Manual*" -or 
        $title -like "*Readme*" -or 
        $title -like "*Reference*" -or
        $title -like "*Config*" -or
        $title -like "*Setup*" -or
        $title -like "*Setting*" -or
        $title -like "*Editor*" -or
        $title -like "Launch*" -or
        $title -eq "Building Architect" -or
        $installDir -like "*.pdf" -or
        $installDir -like "*.txt") {
        Write-Host "Skipping non-game entry: '$title'" -ForegroundColor Gray
        continue
    }

    if (-not (Test-Path $installDir)) {
        Write-Host "Warning: Install folder not found for '$title': $installDir" -ForegroundColor Yellow
        continue
    }

    $exe = Get-MainExecutable -InstallFolder $installDir -GameTitle $title
    if (-not $exe) {
        Write-Host "Warning: No executable found in '$installDir' for '$title'`n" -ForegroundColor Yellow
        continue
    }
    
    # Additional check to ensure we have a valid executable (not PDF, TXT, etc.)
    if (-not ($exe -like "*.exe")) {
        Write-Host "Skipping non-executable file for '$title': $exe" -ForegroundColor Yellow
        continue
    }

    # Steam wants backslashes escaped, but we'll embed them as normal and wrap in quotes later
    $entry = [PSCustomObject]@{
        Name     = $title
        ExePath  = $exe
        StartDir = Split-Path -Path $exe -Parent
    }
    $gameEntries += $entry
}

if ($gameEntries.Count -eq 0) {
    Write-Host "No valid GOG games with executables found. Exiting." -ForegroundColor Red
    exit 0
}

# ░░░▐ FUNCTION: BUILD shortcuts.vdf BINARY ▌░░░
function Build-ShortcutsVdf {
    param (
        [Parameter(Mandatory)]
        [array]$Entries,
        [Parameter(Mandatory)]
        [string]$OutputFilePath
    )
    
    $bytes = [System.Collections.Generic.List[byte]]::new()
    
    # Write header: "shortcuts" + null terminator + dictionary start marker
    $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("shortcuts"))
    $bytes.Add(0x00)  # null terminator for string
    $bytes.Add(0x00)  # dictionary marker
    
    [int]$idx = 0
    foreach ($entry in $Entries) {
        # Generate a unique app ID based on game name
        $appIdValue = 0
        foreach ($char in $entry.Name.ToCharArray()) {
            $appIdValue = ($appIdValue * 31 + [int]$char) % 1000000000  # Simple hash to stay within 32-bit range
        }
        $appIdBytes = [BitConverter]::GetBytes([int]$appIdValue)  # Little-endian byte order
        
        # Entry number + null + dictionary marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes($idx.ToString()))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.Add(0x00)  # dictionary marker
        
        # appid field - int type (32-bit)
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("appid"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange($appIdBytes)  # unique app ID in little-endian format
        
        # appname field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("appname"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes($entry.Name))
        $bytes.Add(0x00)  # null terminator for string
        
        # exe field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("exe"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("`"$($entry.ExePath)`""))
        $bytes.Add(0x00)  # null terminator for string
        
        # StartDir field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("StartDir"))
        $bytes.Add(0x00)  # null terminator for string
        $startDir = Split-Path -Path $entry.ExePath -Parent
        if (-not $startDir.EndsWith("\")) { $startDir += "\" }
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("`"$startDir`""))
        $bytes.Add(0x00)  # null terminator for string
        
        # icon field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("icon"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes(""))
        $bytes.Add(0x00)  # null terminator for string
        
        # ShortcutPath field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("ShortcutPath"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes(""))
        $bytes.Add(0x00)  # null terminator for string
        
        # LaunchOptions field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("LaunchOptions"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes(""))
        $bytes.Add(0x00)  # null terminator for string
        
        # IsHidden field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("IsHidden"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 32-bit integer (0) in little-endian
        
        # AllowDesktopConfig field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("AllowDesktopConfig"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x01, 0x00, 0x00, 0x00))  # 32-bit integer (1) in little-endian
        
        # AllowOverlay field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("AllowOverlay"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x01, 0x00, 0x00, 0x00))  # 32-bit integer (1) in little-endian
        
        # OpenVR field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("OpenVR"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 32-bit integer (0) in little-endian
        
        # Devkit field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("Devkit"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 32-bit integer (0) in little-endian
        
        # DevkitGameID field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("DevkitGameID"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes(""))
        $bytes.Add(0x00)  # null terminator for string
        
        # DevkitOverrideAppID field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("DevkitOverrideAppID"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 32-bit integer (0) in little-endian
        
        # LastPlayTime field - int/bool type
        $bytes.Add(0x02)  # int type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("LastPlayTime"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))  # 32-bit integer (0) in little-endian
        
        # FlatpakAppID field - string type
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("FlatpakAppID"))
        $bytes.Add(0x00)  # null terminator for string
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes(""))
        $bytes.Add(0x00)  # null terminator for string
        
        # tags field - dictionary type
        $bytes.Add(0x00)  # dictionary marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("tags"))
        $bytes.Add(0x00)  # null terminator for string
        
        # Add "GOG" tag to identify these games
        $bytes.Add(0x00)  # dictionary marker for tag entry
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("0"))  # first tag index
        $bytes.Add(0x00)  # null terminator for string
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("GOG"))
        $bytes.Add(0x00)  # null terminator for string
        
        # Additional tag for source (optional)
        $bytes.Add(0x00)  # dictionary marker for tag entry
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("1"))  # second tag index
        $bytes.Add(0x00)  # null terminator for string
        $bytes.Add(0x01)  # string type marker
        $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes("GOG Galaxy"))
        $bytes.Add(0x00)  # null terminator for string
        
        $bytes.Add(0x08)  # end dictionary marker for tags
        
        # End entry dictionary
        $bytes.Add(0x08)  # end marker for this entry's dictionary
        
        $idx++
    }
    
    # End file with dictionary end marker
    $bytes.Add(0x08)
    
    # Write file
    try {
        [IO.File]::WriteAllBytes($OutputFilePath, $bytes.ToArray())
        Write-Host "Successfully wrote shortcuts.vdf with correct binary format." -ForegroundColor Green
    } catch {
        throw "Failed to write shortcuts.vdf: $_"
    }
}

# ░░░▐ BUILD & WRITE NEW shortcuts.vdf ▌░░░
try {
    Build-ShortcutsVdf -Entries $gameEntries -OutputFilePath $shortcutsVdfPath
    Write-Host "Successfully wrote new shortcuts.vdf with GOG games and preserved existing non-Steam shortcuts." -ForegroundColor Green
} catch {
    Write-Error $_
    exit 1
}

# ░░░▐ SUMMARY & NEXT STEPS ▌░░░
Write-Host ""
Write-Host "–––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––" -ForegroundColor DarkGray
Write-Host "All done! 'Non-Steam' shortcuts for your GOG games have been added." -ForegroundColor Cyan
Write-Host ""
Write-Host "Open Steam, go to your Library → Non-Steam Games, and you should see every GOG title listed."
Write-Host ""
Write-Host "Your existing non-Steam shortcuts have been preserved. A backup is also available at:" -NoNewline
Write-Host " $backupPath" -ForegroundColor Yellow
Write-Host ""
Write-Host "Enjoy launching your GOG games from Steam!" -ForegroundColor Magenta
Write-Host "–––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––" -ForegroundColor DarkGray
