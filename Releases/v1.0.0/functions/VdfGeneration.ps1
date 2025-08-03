# VdfGeneration.ps1
# Functions for Steam shortcuts.vdf file generation

# Function to read existing shortcuts from VDF file
function Read-ExistingShortcuts {
    param (
        [Parameter(Mandatory=$true)]
        [string]$InputFilePath
    )
    
    if (-not (Test-Path $InputFilePath)) {
        Write-Verbose "No existing shortcuts.vdf found at: $InputFilePath"
        return @()
    }
    
    try {
        $existingShortcuts = @()
        $fileBytes = [System.IO.File]::ReadAllBytes($InputFilePath)
        
        # Simple but effective approach: extract key information from VDF binary format
        # Look for exe and appname patterns in the binary data
        $pos = 0
        $length = $fileBytes.Length
        
        while ($pos -lt $length - 10) {
            # Look for "exe" field marker
            if ($fileBytes[$pos] -eq 0x01 -and 
                $pos + 4 -lt $length -and
                $fileBytes[$pos + 1] -eq 0x65 -and  # 'e'
                $fileBytes[$pos + 2] -eq 0x78 -and  # 'x'
                $fileBytes[$pos + 3] -eq 0x65 -and  # 'e'
                $fileBytes[$pos + 4] -eq 0x00) {    # null terminator
                
                # Found exe field, now extract the value
                $pos += 5 # Skip past "exe\0"
                
                # Skip opening quote if present
                if ($pos -lt $length -and $fileBytes[$pos] -eq 0x22) { # quote
                    $pos++
                }
                
                # Extract executable path until quote or null
                $exePathBytes = @()
                while ($pos -lt $length -and $fileBytes[$pos] -ne 0x22 -and $fileBytes[$pos] -ne 0x00) {
                    $exePathBytes += $fileBytes[$pos]
                    $pos++
                }
                
                if ($exePathBytes.Count -gt 0) {
                    $exePath = [System.Text.Encoding]::UTF8.GetString($exePathBytes)
                    
                    # Only process if it looks like a valid exe path
                    if ($exePath -and $exePath.Contains('.exe')) {
                        # Try to find the corresponding appname (search backwards)
                        $name = "Unknown Game"
                        $searchPos = $pos - 100 # Search in nearby area
                        if ($searchPos -lt 0) { $searchPos = 0 }
                        
                        # Look for appname pattern
                        for ($i = $searchPos; $i -lt $pos - 10; $i++) {
                            if ($fileBytes[$i] -eq 0x01 -and
                                $i + 8 -lt $length -and
                                $fileBytes[$i + 1] -eq 0x61 -and  # 'a'
                                $fileBytes[$i + 2] -eq 0x70 -and  # 'p'
                                $fileBytes[$i + 3] -eq 0x70 -and  # 'p'
                                $fileBytes[$i + 4] -eq 0x6E -and  # 'n'
                                $fileBytes[$i + 5] -eq 0x61 -and  # 'a'
                                $fileBytes[$i + 6] -eq 0x6D -and  # 'm'
                                $fileBytes[$i + 7] -eq 0x65 -and  # 'e'
                                $fileBytes[$i + 8] -eq 0x00) {    # null
                                
                                # Extract the app name
                                $namePos = $i + 9
                                $nameBytes = @()
                                while ($namePos -lt $length -and $fileBytes[$namePos] -ne 0x00) {
                                    $nameBytes += $fileBytes[$namePos]
                                    $namePos++
                                }
                                
                                if ($nameBytes.Count -gt 0) {
                                    $name = [System.Text.Encoding]::UTF8.GetString($nameBytes)
                                    break
                                }
                            }
                        }
                        
                        $existingShortcuts += @{
                            Name = $name
                            ExePath = $exePath
                            StartDir = Split-Path $exePath -ErrorAction SilentlyContinue
                            LaunchOptions = ""
                        }
                        
                        Write-Verbose "Found existing shortcut: $name -> $exePath"
                    }
                }
            }
            $pos++
        }
        
        Write-Verbose "Found $($existingShortcuts.Count) existing shortcuts"
        return $existingShortcuts
        
    } catch {
        Write-Warning "Failed to read existing shortcuts: $_"
        return @()
    }
}

# Function to check if a game already exists in shortcuts
function Test-GameExists {
    param (
        [Parameter(Mandatory=$true)]
        [array]$ExistingShortcuts,
        
        [Parameter(Mandatory=$true)]
        [string]$GamePath,
        
        [Parameter(Mandatory=$true)]
        [string]$GameName
    )
    
    foreach ($existing in $ExistingShortcuts) {
        # Check if executable path matches (case-insensitive)
        if ($existing.ExePath -and ($existing.ExePath -ieq $GamePath)) {
            return $true
        }
        
        # Also check if the game name is very similar (to catch renamed executables)
        if ($existing.Name -and ($existing.Name -ieq $GameName)) {
            return $true
        }
    }
    
    return $false
}

# Function to merge GOG games with existing shortcuts, avoiding duplicates
function Merge-GameShortcuts {
    param (
        [Parameter(Mandatory=$true)]
        [array]$NewGogGames,
        
        [Parameter(Mandatory=$true)]
        [array]$ExistingShortcuts
    )
    
    $mergedShortcuts = @()
    $addedCount = 0
    $skippedCount = 0
    
    # Add existing shortcuts first
    $mergedShortcuts += $ExistingShortcuts
    
    # Add new GOG games, but only if they don't already exist
    foreach ($gogGame in $NewGogGames) {
        if (-not (Test-GameExists -ExistingShortcuts $ExistingShortcuts -GamePath $gogGame.Path -GameName $gogGame.Title)) {
            $mergedShortcuts += @{
                Name = $gogGame.Title
                ExePath = $gogGame.Path
                StartDir = $gogGame.StartDir
                LaunchOptions = $gogGame.LaunchOptions
            }
            $addedCount++
            Write-Verbose "Added new GOG game: $($gogGame.Title)"
        } else {
            $skippedCount++
            Write-Verbose "Skipped duplicate game: $($gogGame.Title)"
        }
    }
    
    Write-Host "Merged shortcuts: $addedCount new GOG games added, $skippedCount duplicates skipped" -ForegroundColor Cyan
    return $mergedShortcuts
}

# Helper function to write strings to VDF format
function Write-VdfString {
    param (
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[byte]]$bytes,
        
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$value,
        
        [Parameter(Mandatory=$false)]
        [switch]$addQuotes
    )
    
    # Handle empty strings and null values
    if ([string]::IsNullOrEmpty($value)) {
        $bytes.Add(0x00)  # Just add null terminator for empty strings
        return
    }
    
    # Add quotes if requested
    if ($addQuotes) {
        $value = '"' + $value + '"'
    }
    
    # Convert string to bytes and add null terminator
    $stringBytes = [System.Text.Encoding]::UTF8.GetBytes($value)
    $bytes.AddRange($stringBytes)
    $bytes.Add(0x00)  # Null terminator
}

# Helper function to compute SHA1 hash of a string
function Get-SHA1Hash {
    param([string]$value)
    $data = [System.Text.Encoding]::ASCII.GetBytes($value)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hashBytes = $sha1.ComputeHash($data)
        return -join ($hashBytes | ForEach-Object { $_.ToString("X2") })
    }
    finally {
        $sha1.Dispose()
    }
}

# Function to generate appid based on executable path
function Get-AppId {
    param([string]$exePath)
    
    # Get SHA1 hash of the exe path
    $hash = Get-SHA1Hash -value $exePath
    
    # Convert hash to numeric value (CRC)
    $crcValue = [uint32]("0x" + $hash.Substring(0, 8))
    Write-Verbose "Initial CRC value: $([BitConverter]::ToString([BitConverter]::GetBytes($crcValue)))"
    
    # Create duplicated 64-bit value with high bit set in lower 32 bits
    $modifiedCrc = $crcValue -bor 0x80000000
    $longValue = ([uint64]$crcValue -shl 32) -bor [uint64]$modifiedCrc
    Write-Verbose "After CRC duplication and high bit: $([BitConverter]::ToString([BitConverter]::GetBytes($longValue)))"
    
    # Shift entire value left 32 bits
    $longValue = $longValue -shl 32
    Write-Verbose "After shift left 32: $([BitConverter]::ToString([BitConverter]::GetBytes($longValue)))"
    
    # Set bit 25 in result
    $longValue = $longValue -bor 0x02000000
    Write-Verbose "After setting bit 25: $([BitConverter]::ToString([BitConverter]::GetBytes($longValue)))"
    
    # Convert to bytes
    $allBytes = [BitConverter]::GetBytes($longValue)
    Write-Verbose "All bytes: $([BitConverter]::ToString($allBytes))"
    
    # Create final 4-byte result
    $resultBytes = [byte[]]::new(4)
    [Array]::Copy($allBytes, 4, $resultBytes, 0, 3)  # Take 3 bytes from position 4
    $resultBytes[3] = 0x01                           # Set last byte to 0x01
    
    Write-Verbose "Final bytes: $([BitConverter]::ToString($resultBytes))"
    
    return $resultBytes
}

function Build-ShortcutsVdf {
    param (
        [Parameter(Mandatory=$true)]
        [array]$Entries,
        
        [Parameter(Mandatory=$true)]
        [string]$OutputFilePath
    )

    try {
        # Create output directory if needed
        $outputDir = Split-Path -Parent $OutputFilePath
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        # Initialize byte list for binary data
        $bytes = New-Object System.Collections.Generic.List[byte]
        
        # Write root map header
        $bytes.Add(0x00)  # Type marker
        Write-VdfString -bytes $bytes -value "shortcuts"
        
        # Process each game entry
        [int]$idx = 0
        foreach ($entry in $Entries) {
            # Start entry's map
            $bytes.Add(0x00)
            Write-VdfString -bytes $bytes -value $idx.ToString()
            
            # Commented out to match C# code where it was commented out
            # # Write appid field (matches C# code structure exactly)
            # $bytes.Add(0x02)                  # \u0002
            # Write-VdfString -bytes $bytes -value "appid"
            # $appIdBytes = Get-AppId -exePath $entry.ExePath
            # $bytes.AddRange($appIdBytes)      # Write binary appid value
            # $bytes.Add(0x00)                  # \u0000
            
            # Write fields in exact order from C# code
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "appname"
            Write-VdfString -bytes $bytes -value $entry.Name
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "exe"
            Write-VdfString -bytes $bytes -value $entry.ExePath -addQuotes
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "StartDir"
            Write-VdfString -bytes $bytes -value $entry.StartDir -addQuotes
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "icon"
            Write-VdfString -bytes $bytes -value ""
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "ShortcutPath"
            Write-VdfString -bytes $bytes -value ""
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "LaunchOptions"
            $launchOptions = if ($entry.LaunchOptions) { $entry.LaunchOptions } else { "" }
            Write-VdfString -bytes $bytes -value $launchOptions
            
            # Write hidden field
            $bytes.Add(0x02)  # Binary type
            Write-VdfString -bytes $bytes -value "hidden"
            $bytes.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))
            
            # Write tags section
            $bytes.Add(0x00)  # Start tags
            Write-VdfString -bytes $bytes -value "tags"
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "0"
            Write-VdfString -bytes $bytes -value "GOG"
            
            $bytes.Add(0x01)  # String type
            Write-VdfString -bytes $bytes -value "1"
            Write-VdfString -bytes $bytes -value "GOG Galaxy"
            
            # Close tags and entry
            $bytes.Add(0x08)  # Close tags
            $bytes.Add(0x08)  # Close entry
            
            $idx++
        }
        
        # Close root map
        $bytes.Add(0x08)
        $bytes.Add(0x08)
        
        # Write binary file
        [System.IO.File]::WriteAllBytes($OutputFilePath, $bytes.ToArray())
        Write-Host "Successfully wrote shortcuts.vdf with correct binary format." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Error -Message "Error building shortcuts.vdf: $_"
        return $false
    }
}
