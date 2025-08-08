# DatabaseFunctions.ps1
# Functions for interacting with GOG Galaxy SQLite database
# Updated: August 3, 2025 - Enhanced SQL queries for PlayTasks integration and improved error handling

function Initialize-SQLiteConnection {
    <#
    .SYNOPSIS
        Initializes and returns a SQLite connection for the GOG Galaxy database.
    
    .DESCRIPTION
        Attempts to load the SQLite assembly and establish a connection to the GOG Galaxy database.
        First tries to use the PowerShell SQLite module, then falls back to NuGet package if needed.
    
    .PARAMETER GogGalaxyDb
        Path to the GOG Galaxy database file. If not specified, uses the default location.
    
    .EXAMPLE
        $connection = Initialize-SQLiteConnection
        # Use the connection...
        $connection.Close()
    #>
    [CmdletBinding()]
    param(
        [string]$GogGalaxyDb = "$env:ProgramData\GOG.com\Galaxy\storage\galaxy-2.0.db"
    )

    try {
        # First try PowerShell module paths
        $sqliteDll = "C:\Program Files\WindowsPowerShell\Modules\SQLite\2.0\bin\x64\System.Data.SQLite.dll"
        if (-not (Test-Path $sqliteDll)) {
            $sqliteDll = "C:\Program Files\WindowsPowerShell\Modules\SQLite\2.0\bin\System.Data.SQLite.dll"
        }
        
        # Try to load SQLite assembly if found
        if (Test-Path $sqliteDll) {
            try {
                Add-Type -Path $sqliteDll
                Write-Host "SQLite assembly loaded successfully from PowerShell module." -ForegroundColor Green
                $sqliteAssemblyLoaded = $true
            } catch {
                Write-Host "Failed to load SQLite from PowerShell module: $_" -ForegroundColor Yellow
            }
        }

        # Check if the assembly is already loaded
        $sqliteAssemblyLoaded = [System.AppDomain]::CurrentDomain.GetAssemblies() | 
            Where-Object { $_.GetName().Name -eq "System.Data.SQLite" }

        # If not loaded, try installing and loading via NuGet
        if (-not $sqliteAssemblyLoaded) {
            # Check if package is installed
            $sqlitePackageInstalled = Get-Package -Name System.Data.SQLite.Core -ErrorAction SilentlyContinue

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
                    Write-Host "SQLite package installed successfully." -ForegroundColor Green
                } catch {
                    throw "Failed to install System.Data.SQLite package: $_"
                }
            }

            # Try to load the assembly after installation
            try {
                [System.Reflection.Assembly]::LoadWithPartialName("System.Data.SQLite") | Out-Null
                Write-Host "SQLite assembly loaded successfully." -ForegroundColor Green
            } catch {
                throw "Failed to load System.Data.SQLite assembly: $_"
            }
        }

        # Verify database exists
        if (-not (Test-Path $GogGalaxyDb)) {
            throw "GOG Galaxy database not found at: $GogGalaxyDb"
        }

        # Create and return the connection
        $connectionString = "Data Source=$GogGalaxyDb;Version=3;"
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        $connection.Open()

        return $connection
    }
    catch {
        throw "Failed to initialize SQLite connection: $_"
    }
}

function Invoke-SQLiteQuery {
    <#
    .SYNOPSIS
        Executes a SQLite query and returns the results.
    
    .DESCRIPTION
        Helper function to execute SQLite queries and handle data reader cleanup properly.
        Supports both scalar queries and those returning multiple rows.
    
    .PARAMETER Connection
        SQLite connection object returned by Initialize-SQLiteConnection.
    
    .PARAMETER Query
        SQL query to execute.
    
    .PARAMETER Parameters
        Optional hashtable of parameters to use in the query.
    
    .EXAMPLE
        $connection = Initialize-SQLiteConnection
        $results = Invoke-SQLiteQuery -Connection $connection -Query "SELECT * FROM Products"
        $connection.Close()
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [System.Data.SQLite.SQLiteConnection]$Connection,
        
        [Parameter(Mandatory=$true)]
        [string]$Query,
        
        [Parameter(Mandatory=$false)]
        [hashtable]$Parameters
    )
    
    $command = $null
    $reader = $null
    
    try {
        Write-Host "Executing SQLite query:" -ForegroundColor Cyan
        Write-Host $Query -ForegroundColor Gray
        
        $command = $Connection.CreateCommand()
        $command.CommandText = $Query
        
        if ($Parameters) {
            foreach ($param in $Parameters.GetEnumerator()) {
                $command.Parameters.AddWithValue($param.Key, $param.Value) | Out-Null
            }
        }
        
        Write-Host "Executing query..." -ForegroundColor Cyan
        $reader = $command.ExecuteReader()
        $results = New-Object System.Collections.ArrayList
        
        Write-Host "Processing results..." -ForegroundColor Cyan
        $rowCount = 0
        
        try {
            while ($reader.Read()) {
                $row = @{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $row[$reader.GetName($i)] = $reader.GetValue($i)
                }
                $results.Add([PSCustomObject]$row) | Out-Null
                $rowCount++
                
                Write-Host "Found game: $($row['name'])" -ForegroundColor Green
                Write-Host "  Path: $($row['installationPath'])" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "Error reading results: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Stack trace: $($_.Exception.StackTrace)" -ForegroundColor Red
            throw
        }
        
        Write-Host "Query completed. Found $rowCount results." -ForegroundColor Cyan
        return $results
    }
    catch {
        Write-Host "Error executing query: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Stack trace: $($_.Exception.StackTrace)" -ForegroundColor Red
        throw
    }
    finally {
        if ($reader) { 
            $reader.Dispose()
            Write-Host "Reader disposed." -ForegroundColor Gray
        }
        if ($command) { 
            $command.Dispose()
            Write-Host "Command disposed." -ForegroundColor Gray
        }
    }
}

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

function Read-ExistingShortcuts {
    param(
        [Parameter(Mandatory)]
        [string]$InputFilePath
    )
    
    try {
        $bytes = [System.IO.File]::ReadAllBytes($InputFilePath)
        $entries = @()
        $i = 0
        
        # Skip past the first MapItem
        $i = 11
        
        while ($i -lt $bytes.Length) {
            $entry = @{
                Name     = ""
                ExePath  = ""
                StartDir = ""
            }
            
            # Read entry index
            $nameBuf = ""
            while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                $nameBuf += [char]$bytes[$i]
                $i++
            }
            $i++  # skip null
            
            if ($i -ge $bytes.Length) { break }
            
            $i++  # Next byte (0x00)
            
            while ($i -lt $bytes.Length -and $bytes[$i] -ne 0x08) {
                $itemType = $bytes[$i]
                $i++
                
                $propName = ""
                while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                    $propName += [char]$bytes[$i]
                    $i++
                }
                $i++
                
                switch ($itemType) {
                    0x01 {
                        $propValue = ""
                        while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) {
                            $propValue += [char]$bytes[$i]
                            $i++
                        }
                        $i++
                        
                        switch ($propName) {
                            "appname" { $entry.Name    = $propValue }
                            "exe"     { $entry.ExePath = $propValue.Trim('"') }
                            "StartDir"{ $entry.StartDir = $propValue.Trim('"') }
                        }
                    }
                    0x02 {
                        $i += 4  # Skip number
                    }
                    0x00 {
                        $depth = 1
                        while ($i -lt $bytes.Length -and $depth -gt 0) {
                            if ($bytes[$i] -eq 0x00) {
                                $depth++
                                $i++
                                while ($i -lt $bytes.Length -and $bytes[$i] -ne 0) { $i++ }
                                $i++
                            }
                            elseif ($bytes[$i] -eq 0x08) {
                                $depth--
                                $i++
                            }
                            else {
                                $i++
                            }
                        }
                    }
                    default {
                        break
                    }
                }
            }
            
            $i++
            
            if ($entry.Name -and $entry.ExePath -and $entry.StartDir) {
                Write-Host "Found existing shortcut: $($entry.Name)" -ForegroundColor Cyan
                $entries += [PSCustomObject]$entry
            }
        }
        
        return $entries
    } catch {
        Write-Host "Error reading shortcuts.vdf: $_" -ForegroundColor Yellow
        return @()
    }
}

