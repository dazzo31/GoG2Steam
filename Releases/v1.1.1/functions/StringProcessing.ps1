# StringProcessing.ps1
# Functions for string handling and encoding
# Updated: August 3, 2025 - Fixed Unicode character encoding issues and simplified character replacement

function Clean-GameTitle {
    param([string]$title)
    
    # First pass: Remove trademark and other special symbols
    $title = $title -replace '[\u2122\u00AE\u00A9\u2120\u2117]', ''  # Remove trademark symbols
    
    # Second pass: Handle quotes and apostrophes
    $title = $title -replace '[\u2018\u2019\u201A\u201B]', "'"  # Smart single quotes
    $title = $title -replace '[\u201C\u201D\u201E\u201F]', '"'  # Smart double quotes
    
    # Third pass: Handle dashes and punctuation
    $title = $title -replace '[\u2013\u2014\u2015\u2017\u2012]', '-'  # Various dashes
    $title = $title -replace '\u2026', '...'    # Ellipsis
    $title = $title -replace '[\u00B7\u2022]', '*'   # Bullets
    $title = $title -replace '\u00D7', 'x'      # Multiplication sign
    
    # Fourth pass: Replace accented characters with simple ASCII equivalents
    $title = $title -replace '[\u00E0-\u00E6\u0101\u0103\u0105\u01CE\u01FB\u00C0-\u00C6\u0100\u0102\u0104\u01CD\u01FA]', 'a'
    $title = $title -replace '[\u00C0-\u00C6\u0100\u0102\u0104\u01CD\u01FA]', 'A'
    $title = $title -replace '[\u00E8-\u00EB\u0113\u0115\u0117\u0119\u011B\u0205\u0207\u00C8-\u00CB\u0112\u0114\u0116\u0118\u011A\u0204\u0206]', 'e'
    $title = $title -replace '[\u00C8-\u00CB\u0112\u0114\u0116\u0118\u011A\u0204\u0206]', 'E'
    $title = $title -replace '[\u00EC-\u00EF\u0129\u012B\u012D\u012F\u01D0\u0209\u020B\u00CC-\u00CF\u0128\u012A\u012C\u012E\u01CF\u0208\u020A]', 'i'
    $title = $title -replace '[\u00CC-\u00CF\u0128\u012A\u012C\u012E\u01CF\u0208\u020A]', 'I'
    $title = $title -replace '[\u00F2-\u00F6\u014D\u014F\u0151\u01D2\u020D\u020F\u00D2-\u00D6\u014C\u014E\u0150\u01D1\u020C\u020E]', 'o'
    $title = $title -replace '[\u00D2-\u00D6\u014C\u014E\u0150\u01D1\u020C\u020E]', 'O'
    $title = $title -replace '[\u00F9-\u00FC\u0169\u016B\u016D\u016F\u0171\u0173\u00D9-\u00DC\u0168\u016A\u016C\u016E\u0170\u0172]', 'u'
    $title = $title -replace '[\u00D9-\u00DC\u0168\u016A\u016C\u016E\u0170\u0172]', 'U'
    $title = $title -replace '[\u00FD\u00FF\u0177\u0233\u00DD\u0178\u0176\u0232]', 'y'
    $title = $title -replace '[\u00DD\u0178\u0176\u0232]', 'Y'
    $title = $title -replace '[\u00E7\u0107\u0109\u010B\u010D\u00C7\u0106\u0108\u010A\u010C]', 'c'
    $title = $title -replace '[\u00C7\u0106\u0108\u010A\u010C]', 'C'
    $title = $title -replace '[\u00F1\u0144\u0146\u0148\u014B\u00D1\u0143\u0145\u0147\u014A]', 'n'
    $title = $title -replace '[\u00D1\u0143\u0145\u0147\u014A]', 'N'

    # Final cleanup
    $title = $title -replace '[^\x20-\x7E]', ''  # Remove non-ASCII
    $title = $title -replace '\s+', ' '    # Multiple spaces to single
    $title = $title.Trim()

    if ([string]::IsNullOrWhiteSpace($title)) {
        return "Unknown Game"
    }

    return $title
}

function Write-EncodedString {
    param(
        [Parameter(Mandatory=$true)]
        [System.Collections.Generic.List[byte]]$byteList,
        
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$value,
        
        [switch]$isQuoted,
        [switch]$skipCleaning
    )

    try {
        if ([string]::IsNullOrEmpty($value)) {
            $byteList.Add(0x00)
            return
        }

        if ($value -like "*:\*" -or $value -like "\\*") {
            $value = $value.Replace('/', '\')
            if ($isQuoted -and -not $value.StartsWith('"')) {
                $value = "`"$value`""
            }
        }

        if (-not $skipCleaning) {
            $value = $value -replace '[\u2122\u00AE\u00A9\u2120\u2117]', ''
            $value = $value -replace '[^\x20-\x7E]', ''
            $value = $value.Trim()
        }

        $bytes = [System.Text.Encoding]::ASCII.GetBytes($value)
        $byteList.AddRange($bytes)
        $byteList.Add(0x00)
    }
    catch {
        Write-Error -Message "Failed to encode string: $($_.Exception.Message)"
    }
}