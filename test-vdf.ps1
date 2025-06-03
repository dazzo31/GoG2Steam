# Import the VdfGeneration module
. (Join-Path $PSScriptRoot "functions\VdfGeneration.ps1")

# Create test entries
$testEntries = @(
    @{
        Name = "Test Game 1"
        ExePath = "C:\Games\TestGame1\game.exe"
        StartDir = "C:\Games\TestGame1"
    },
    @{
        Name = "Test Game 2"
        ExePath = "C:\Games\TestGame2\game.exe"
        StartDir = "C:\Games\TestGame2"
    },
    @{
        Name = "Test Game 3"
        ExePath = "C:\Games\TestGame3\game.exe"
        StartDir = "C:\Games\TestGame3"
    }
)

# Enable verbose output to see the appid bytes
$VerbosePreference = 'Continue'

# Create a test output file
$testOutput = Join-Path $PSScriptRoot "test-shortcuts.vdf"
$result = Build-ShortcutsVdf -Entries $testEntries -OutputFilePath $testOutput

if ($result) {
    Write-Host "`nTest file created at: $testOutput" -ForegroundColor Green
    Write-Host "File size: $((Get-Item $testOutput).Length) bytes" -ForegroundColor Green
} else {
    Write-Host "Failed to create test file" -ForegroundColor Red
}

