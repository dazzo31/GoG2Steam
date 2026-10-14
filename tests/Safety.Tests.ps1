# Standalone regression suite; runs on Windows PowerShell 5.1 and PowerShell 7.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../functions/VdfGeneration.ps1"
$script:passed = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert $threw $Message
}
function Add-Text($Bytes, [string]$Text) {
    $Bytes.AddRange([Text.Encoding]::UTF8.GetBytes($Text)); $Bytes.Add(0)
}
function Add-String($Bytes, [string]$Key, [string]$Value) {
    $Bytes.Add(1); Add-Text $Bytes $Key; Add-Text $Bytes $Value
}
function Signature([byte[]]$Bytes) { [Convert]::ToBase64String($Bytes) }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('gog2steam-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
try {
    # Fixture built independently of Build-ShortcutsVdf. Includes a non-EXE target,
    # a long Unicode title, custom metadata, nested tags and 0/8 inside integers.
    $payload = New-Object 'System.Collections.Generic.List[byte]'
    $title = ('Long title ' * 20) + [char]0x00e9 + [char]0x65e5
    Add-String $payload 'appname' $title
    Add-String $payload 'exe' '"C:\Games\launcher.cmd"'
    Add-String $payload 'StartDir' '"C:\Custom Working Directory"'
    Add-String $payload 'LaunchOptions' '--game 42'
    Add-String $payload 'icon' 'C:\Icons\custom.ico'
    foreach ($key in @('appid','AllowOverlay','IsHidden','LastPlayTime')) {
        $payload.Add(2); Add-Text $payload $key; $payload.AddRange([byte[]]@(0,8,0,128))
    }
    $payload.Add(0); Add-Text $payload 'tags'
    Add-String $payload '0' 'My favourites'
    Add-String $payload '1' 'Family'
    $payload.Add(8)
    Add-String $payload 'futureField' 'preserve me'
    $payload.Add(8)
    $fixture = New-Object 'System.Collections.Generic.List[byte]'
    $fixture.Add(0); Add-Text $fixture 'shortcuts'
    $fixture.Add(0); Add-Text $fixture '0'
    $fixture.AddRange($payload.ToArray()); $fixture.Add(8); $fixture.Add(8)
    $path = Join-Path $temp 'shortcuts.vdf'
    [IO.File]::WriteAllBytes($path, $fixture.ToArray())
    $entries = @(Read-ExistingShortcuts $path)
    Assert ($entries.Count -eq 1) 'single shortcut is read'
    Assert ($entries[0].Name -ceq $title) 'long Unicode title is decoded'
    Assert ($entries[0].ExePath -eq 'C:\Games\launcher.cmd') 'non-EXE shortcut is retained'
    Assert ($entries[0].LaunchOptions -eq '--game 42') 'launch arguments are read'
    Assert ($entries[0].StartDir -eq 'C:\Custom Working Directory') 'custom working directory is read'
    Assert (Build-ShortcutsVdf $entries $path) 'existing destination is replaced successfully'
    Assert ((Signature ([IO.File]::ReadAllBytes($path))) -ceq (Signature $fixture.ToArray())) 'full existing record survives byte-for-byte'
    $games = @(
        @{Title='Different display name'; Path='c:\games\LAUNCHER.cmd'; StartDir='C:\Games'; LaunchOptions='--game 42'},
        @{Title=$title; Path='C:\Games\launcher.cmd'; StartDir='C:\Games'; LaunchOptions='--game 99'},
        @{Title=$title; Path='C:\Games\other.exe'; StartDir='C:\Games'; LaunchOptions=''}
    )
    $merged = @(Merge-GameShortcuts $games $entries)
    Assert ($merged.Count -eq 3) 'matching launch is skipped but different arguments and same-name games remain'
    Assert ($merged[0].Name -ceq $title) 'existing display name is not overwritten'
    Assert (@(Merge-GameShortcuts $games $merged).Count -eq 3) 'repeat import is idempotent'
    Assert (Build-ShortcutsVdf $merged $path) 'merged file is written'
    $reread = @(Read-ExistingShortcuts $path)
    Assert ($reread.Count -eq 3) 'merged file contains all entries'
    Assert ((Signature $reread[0].RawPayload) -ceq (Signature $payload.ToArray())) 'custom fields remain after adding games'
    $before = Signature ([IO.File]::ReadAllBytes($path))
    Assert-Throws { Build-ShortcutsVdf @(@{RawPayload=[byte[]]@(1,65)}) $path } 'invalid generated record is rejected'
    Assert ((Signature ([IO.File]::ReadAllBytes($path))) -ceq $before) 'failed validation leaves destination unchanged'
    Assert (@(Get-ChildItem $temp -Force -Filter '*.tmp').Count -eq 0) 'temporary file is removed on failure'
    $bad = Join-Path $temp 'bad.vdf'
    foreach ($length in @(0, 1, 10, ($fixture.Count - 3))) {
        $truncated = New-Object byte[] $length
        [Array]::Copy($fixture.ToArray(), $truncated, $length)
        [IO.File]::WriteAllBytes($bad, $truncated)
        Assert-Throws { Read-ExistingShortcuts $bad } "truncated input ($length bytes) is rejected"
    }
    $unsupported = $fixture.ToArray(); $unsupported[14] = 99
    [IO.File]::WriteAllBytes($bad, $unsupported)
    Assert-Throws { Read-ExistingShortcuts $bad } 'unsupported field type is rejected'
    $empty = Join-Path $temp 'empty.vdf'
    Assert (Build-ShortcutsVdf @() $empty) 'empty collection can be written'
    Assert (@(Read-ExistingShortcuts $empty).Count -eq 0) 'empty collection round-trips'
    Assert (@(Read-ExistingShortcuts (Join-Path $temp 'missing.vdf')).Count -eq 0) 'missing file means no shortcuts'

    # Parse all shipping source files and extract the process guard without running
    # the application or touching real Steam processes.
    $mainAst = $null
    foreach ($file in @(Get-Item "$PSScriptRoot/../GoG2Steam.ps1") + @(Get-ChildItem "$PSScriptRoot/../functions/*.ps1")) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "PowerShell parses $($file.Name)"
        if ($file.Name -eq 'GoG2Steam.ps1') { $mainAst = $ast }
    }
    $guard = $mainAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-SteamNotRunning' }, $true)
    . ([scriptblock]::Create($guard.Extent.Text))
    $script:closeCalls = 0
    $script:running = $true
    function Get-Process { param($Name, $ErrorAction) if ($script:running) { $p = [pscustomobject]@{}; $p | Add-Member ScriptMethod CloseMainWindow { $script:closeCalls++; return $true }; $p } }
    function Wait-Process { param($Name, $Timeout, $ErrorAction) }
    function Stop-Process { param($Name, [switch]$Force, $ErrorAction) $script:closeCalls++ }
    function taskkill { $script:closeCalls++ }
    function Start-Sleep { param($Seconds) }
    Assert-Throws { Assert-SteamNotRunning -NonInteractive } 'unattended mode requires explicit close permission'
    Assert ($script:closeCalls -eq 0) 'no process close was attempted without permission'
    Assert-Throws { Assert-SteamNotRunning -NonInteractive -ForceClose } 'guard refuses to continue if forced close fails'
    $script:running = $false
    Assert-SteamNotRunning -NonInteractive
    Assert $true 'guard permits writing when Steam is closed'
    Write-Host "PASS: $script:passed safety assertions"
} finally {
    [IO.Directory]::Delete($temp, $true)
}
