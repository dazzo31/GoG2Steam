# VdfGeneration.ps1
# Functions for Steam shortcuts.vdf file generation

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
