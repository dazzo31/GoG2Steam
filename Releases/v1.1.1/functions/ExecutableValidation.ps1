# ExecutableValidation.ps1
# Functions for validating game executables
# Updated: August 3, 2025 - Added IsGogAuthoritative parameter for bypassing utility checks on GOG-verified executables

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
    # 2) Otherwise, find all *.exe in the top level and pick the largest
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

function Test-GameExecutable {
    param(
        [Parameter(Mandatory=$true)]
        [string]$exePath,
        [Parameter(Mandatory=$false)]
        [string]$title = "",
        [Parameter(Mandatory=$false)]
        [switch]$IsGogAuthoritative  # Added Aug 3, 2025 - Bypasses utility checks for GOG-verified executables
    )
    
    try {
        # Initial validation
        if ([string]::IsNullOrWhiteSpace($exePath)) {
            Write-Verbose "Empty executable path"
            return $false
        }

        # Normalize path and get filename
        $exePath = $exePath.Replace('/', '\').Trim('"')
        $exePath = [System.IO.Path]::GetFullPath($exePath)
        $exeName = [System.IO.Path]::GetFileName($exePath).ToLower()
        $exeDir = [System.IO.Path]::GetDirectoryName($exePath).ToLower()

        # Validate file exists
        if (-not (Test-Path $exePath)) {
            Write-Verbose "Executable does not exist: $exePath"
            return $false
        }

        # Check known utility patterns (but skip if this is GOG-authoritative)
        # Enhancement Aug 3, 2025: GOG PlayTasks data is considered authoritative
        if (-not $IsGogAuthoritative) {
            $utilityPatterns = @(
                '^unins(?:\d+)?\.exe$',
                '^uninst(?:all)?\.exe$',
                '^setup\.exe$',
                '^install(?:er)?\.exe$',
                '^launcher\.exe$',
                '^config.*\.exe$',
                '^patch.*\.exe$',
                '^update.*\.exe$'
            )

            foreach ($pattern in $utilityPatterns) {
                if ($exeName -match $pattern) {
                    Write-Verbose "Rejecting utility executable: $exeName"
                    return $false
                }
            }
        } else {
            Write-Verbose "Skipping utility pattern check for GOG-authoritative executable: $exeName"
        }

        # Additional validation for generic titles
        if ($title -match '^(Play|Launch|Start)') {
            if ($exeName -match '(unins|setup|config|launcher)' -or 
                $exeDir -match '(\\redist\\|\\system\\|\\utility\\)') {
                Write-Verbose "Rejecting utility for generic title: $exePath"
                return $false
            }
        }

        # Check PE header
        $stream = [System.IO.File]::OpenRead($exePath)
        try {
            $reader = New-Object System.IO.BinaryReader($stream)
            $mzHeader = $reader.ReadUInt16()
            if ($mzHeader -ne 0x5A4D) { # "MZ" magic number
                return $false
            }
            return $true
        }
        finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }
    catch {
        Write-Verbose "Error validating executable: $_"
        return $false
    }
}

