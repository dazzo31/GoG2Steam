Describe 'GoG2Steam interactive menu' {
  BeforeAll {
    # Prevent main flow from running while dot-sourcing
    $env:GOG2STEAM_TEST = '1'
    # Load the script functions
    . "$PSScriptRoot/../GoG2Steam.ps1"
  }

  BeforeEach {
    # Reset script-scoped variables
    $script:SteamUserId = $null
    $script:NamePrefix = ''
    $script:IncludeTitlePattern = $null
    $script:ExcludeTitlePattern = $null
    $script:NoBackup = $false
    $script:DebugVdf = $false

    # Provide fake Steam users
    Mock -CommandName Get-SteamUsers -MockWith {
      @(
        [pscustomobject]@{ Id='111111111'; PersonaName='Alpha'; MostRecent=$true;  Timestamp=100 },
        [pscustomobject]@{ Id='222222222'; PersonaName='Beta';  MostRecent=$false; Timestamp=200 }
      )
    }

    # Capture Write-Host to validate confirmations (optional)
    $script:HostLog = New-Object System.Collections.Generic.List[object]
    Mock -CommandName Write-Host -MockWith {
      param($Message, $ForegroundColor)
      $script:HostLog.Add([pscustomobject]@{ Message=$Message; Color=$ForegroundColor })
    }
  }

  It 'selects a Steam user via numeric menu' {
    # Inputs: 1) choose "Select user", then "2" to pick Beta, then "7" to Proceed
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('1','2','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }

    Show-OptionsMenu -SteamRoot 'C:\\Steam'

    $script:SteamUserId | Should -Be '222222222'
    # Optional: confirmation lines are best-effort; assert state only in this test
  }

  It 'toggles backup and debug, then proceeds' {
    # Inputs: '5' toggle Backup, '6' toggle Debug, '7' Proceed
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('5','6','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }

    Show-OptionsMenu -SteamRoot 'C:\\Steam'

    $script:NoBackup | Should -Be $true
    $script:DebugVdf | Should -Be $true

    # Confirmation lines are best-effort; assert state only in this test
  }

  It 'sets include/exclude and prefix, then proceeds' {
    # Sequence:
    # 2 -> Name Prefix -> "[GOG] "
    # 3 -> Include -> "^Sim"
    # 4 -> Exclude -> "Beta"
    # 7 -> Proceed
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('2','[GOG] ','3','^Sim','4','Beta','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }

    Show-OptionsMenu -SteamRoot 'C:\\Steam'

    $script:NamePrefix | Should -Be '[GOG] '
    $script:IncludeTitlePattern | Should -Be '^Sim'
    $script:ExcludeTitlePattern | Should -Be 'Beta'
  }

  It 'Select-SteamUserInteractive returns correct user for input "1"' {
    # Directly test the helper with stable inputs
    $users = @(
      [pscustomobject]@{ Id='111111111'; PersonaName='Alpha'; MostRecent=$true;  Timestamp=100 },
      [pscustomobject]@{ Id='222222222'; PersonaName='Beta';  MostRecent=$false; Timestamp=200 }
    )

    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('1') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }

    $sel = Select-SteamUserInteractive -Users $users
    $sel.Id | Should -Be '111111111'
  }

  It 'Select-SteamUserInteractive defaults to most recent on blank input' {
    $users = @(
      [pscustomobject]@{ Id='111111111'; PersonaName='Alpha'; MostRecent=$true;  Timestamp=100 },
      [pscustomobject]@{ Id='222222222'; PersonaName='Beta';  MostRecent=$false; Timestamp=200 }
    )
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }
    $sel = Select-SteamUserInteractive -Users $users
    $sel.Id | Should -Be '111111111'
  }

  It 'menu handles invalid non-numeric input then proceeds on next input' {
    # 'abc' invalid, then default proceed '7'
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('abc','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }
    { Show-OptionsMenu -SteamRoot 'C:\\Steam' } | Should -Not -Throw
  }

  It 'menu handles out-of-range input then proceeds' {
    # '9' out of range, then '7' proceed
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('9','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }
    { Show-OptionsMenu -SteamRoot 'C:\\Steam' } | Should -Not -Throw
  }

  It 'menu proceeds immediately on blank input (default 7)' {
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }
    { Show-OptionsMenu -SteamRoot 'C:\\Steam' } | Should -Not -Throw
  }

  It 'menu shows message when no Steam users and selection attempted, but does not set SteamUserId' {
    # Override Get-SteamUsers to return empty
    Mock -CommandName Get-SteamUsers -MockWith { @() } -Verifiable -ParameterFilter { $true }
    $inputs = [System.Collections.Generic.Queue[string]]::new()
    @('1','7') | ForEach-Object { $inputs.Enqueue($_) }
    Mock -CommandName Read-Host -MockWith { param($Prompt) $inputs.Dequeue() }
    Show-OptionsMenu -SteamRoot 'C:\\Steam'
    $script:SteamUserId | Should -Be $null
  }
}
