# StringProcessing.ps1
# Functions for string handling and encoding

function Clean-GameTitle {
    param([string]$title)
    
    # First pass: Remove trademark and other special symbols
    $title = $title -replace '[\u2122\u00AE\u00A9\u2120\u2117]', ''  # Remove ™®©℠℗
    
    # Second pass: Handle quotes and apostrophes
    $title = $title -replace '[\u2018\u2019\u201A\u201B]', "'"  # Smart single quotes
    $title = $title -replace '[\u201C\u201D\u201E\u201F]', '"'  # Smart double quotes
    
    # Third pass: Handle dashes and punctuation
    $title = $title -replace '[\u2013\u2014\u2015\u2017\u2012]', '-'  # Various dashes
    $title = $title -replace '\u2026', '...'    # Ellipsis
    $title = $title -replace '[\u00B7\u2022]', '*'   # Bullets
    $title = $title -replace '\u00D7', 'x'      # Multiplication sign
    
    # Fourth pass: Replace accented characters
    $charMap = @(
        @{ pattern = '[àáâãäåāăąǎǻÀÁÂÃÄÅĀĂĄǍǺ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'A'} else {'a'} } },
        @{ pattern = '[èéêëēĕėęěȅȇÈÉÊËĒĔĖĘĚȄȆ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'E'} else {'e'} } },
        @{ pattern = '[ìíîïīĭįǐȉȋÌÍÎÏĪĬĮǏȈȊ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'I'} else {'i'} } },
        @{ pattern = '[òóôõöōŏőǒȍȏÒÓÔÕÖŌŎŐǑȌȎ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'O'} else {'o'} } },
        @{ pattern = '[ùúûüũūŭůűųÙÚÛÜŨŪŬŮŰŲ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'U'} else {'u'} } },
        @{ pattern = '[ýÿŷȳÝŸŶȲ]'; replace = { param($m) if ($m -cmatch '[A-Z]') {'Y'} else {'y'} } }
    )

    foreach ($map in $charMap) {
        $title = [regex]::Replace($title, $map.pattern, $map.replace)
    }
    
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

