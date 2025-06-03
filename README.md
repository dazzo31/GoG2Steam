# Using with GOG Galaxy

## Overview

A PowerShell script that automatically imports your GOG Galaxy games into Steam. Built on top of the Steam VDF Generator module, this script:

- Automatically discovers installed GOG games through Galaxy's database
- Creates non-Steam shortcuts for all installed GOG games
- Intelligently locates main game executables
- Tags games with "GOG" and "GOG Galaxy" for easy identification

## How It Works

1. Reads GOG Galaxy's SQLite database (`galaxy-2.0.db`)
2. For each installed game:
   - Finds the installation directory
   - Locates the main game executable
   - Filters out installers, uninstallers, and support tools
   - Creates a Steam shortcut entry
3. Generates a valid shortcuts.vdf in Steam's userdata directory
4. Backs up existing shortcuts.vdf before making changes

## Usage

```powershell
.\goggames2steam.ps1 [-SteamPath <path>] [-GogPath <path>] [-GogDb <path>] [-NoBackup]
```

Parameters:
- `-SteamPath`: Steam installation directory (default: Program Files)
- `-GogPath`: GOG Galaxy installation directory (default: Program Files)
- `-GogDb`: GOG Galaxy database path (default: ProgramData)
- `-NoBackup`: Skip backing up existing shortcuts.vdf

## Requirements

- Windows 10/11
- PowerShell 5.1+
- GOG Galaxy installed
- Steam installed

## Notes

- Steam must be restarted to see the new shortcuts
- Existing non-Steam shortcuts are preserved
- Database paths are automatically detected
- Special characters in paths are handled correctly

For VDF format details, see Steam VDF Generator documentation below.

# Steam VDF Generator

A PowerShell module that generates Steam's non-Steam game shortcuts in the binary VDF (Valve Data Format) file format. This implementation:

- Accurately replicates Steam's shortcuts.vdf binary format
- Handles all required fields (appname, exe, StartDir, etc.)
- Properly formats binary fields like "hidden"
- Supports tags for game categorization
- Maintains null terminators and type markers according to spec

## VDF Format Implementation

The script implements Steam's binary VDF format for shortcuts:

- String values (0x01): Written as UTF-8 with null terminator
- Binary values (0x02): Written with length prefix and null terminator
- Maps: Marked with 0x00 start and 0x08 end bytes
- Special fields: "hidden" as binary, "tags" as nested map
- Fields ordered as per Steam's expectations

## Usage Example

```powershell
$entries = @(
    @{
        Name = "My Game"
        ExePath = "C:\Games\MyGame.exe"
        StartDir = "C:\Games"
    }
)

Build-ShortcutsVdf -Entries $entries -OutputFilePath "shortcuts.vdf"
```

## Functions

- `Write-VdfString`: Writes strings in VDF format with proper null termination
- `Get-SHA1Hash`: Helper for CRC-based AppID generation
- `Get-AppId`: Generates unique AppIDs matching Steam's format
- `Build-ShortcutsVdf`: Main function for creating shortcuts.vdf

## Testing

Use test-vdf.ps1 to verify correct binary output:
```powershell
.\test-vdf.ps1
```

## Notes

- File format matches official Steam client behavior
- Handles empty strings and binary data properly
- Preserves exact byte sequence required by Steam
- Generated files can be read by Steam client

## Credits

Based on analysis of Steam's shortcuts.vdf format and C# reference implementation.

