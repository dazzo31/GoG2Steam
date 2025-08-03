# GoG2Steam - GOG Galaxy to Steam Integration

## Overview

A PowerShell script that automatically imports your GOG Galaxy games into Steam. Built on top of the Steam VDF Generator module, this script:

- Automatically discovers installed GOG games through Galaxy's database
- Creates non-Steam shortcuts for all installed GOG games
- Intelligently locates main game executables using GOG's authoritative PlayTasks data
- Preserves existing Steam shortcuts while adding new GOG games
- Avoids duplicate entries through intelligent merging
- Tags games with "GOG" and "GOG Galaxy" for easy identification

## Recent Updates

### Version 1.1.0 - August 3, 2025
- **Enhanced Executable Detection**: Now uses GOG's PlayTasks database with `isPrimary = 1` flag for authoritative executable detection
- **Existing Shortcuts Preservation**: Added functionality to read and preserve existing Steam shortcuts before adding GOG games
- **Duplicate Prevention**: Intelligent merging system prevents duplicate entries when re-running the script
- **Improved Validation**: Added `IsGogAuthoritative` parameter to bypass utility pattern checks for GOG-verified executables
- **Better String Processing**: Simplified Unicode character handling for better compatibility
- **Enhanced VDF Generation**: Added comprehensive VDF reading and merging capabilities
- **Modular Architecture**: Improved separation of concerns across function modules

## How It Works

1. Reads GOG Galaxy's SQLite database (`galaxy-2.0.db`)
2. Uses GOG's PlayTasks table to get authoritative executable information
3. Reads existing Steam shortcuts to preserve them
4. For each installed game:
   - Uses GOG's `isPrimary = 1` PlayTasks to get the correct executable
   - Extracts launch arguments from GOG's database
   - Creates a Steam shortcut entry with proper tagging
5. Merges new GOG games with existing shortcuts (avoiding duplicates)
6. Generates a valid shortcuts.vdf in Steam's userdata directory
7. Backs up existing shortcuts.vdf before making changes

## Usage

```powershell
.\GoG2Steam.ps1 [-SteamPath <path>] [-GogPath <path>] [-GogDb <path>] [-NoBackup]
```

Parameters:
- `-SteamPath`: Steam installation directory (default: Program Files)
- `-GogPath`: GOG Galaxy installation directory (default: Program Files)
- `-GogDb`: GOG Galaxy database path (default: ProgramData)
- `-NoBackup`: Skip backing up existing shortcuts.vdf

## Requirements

- Windows 10/11
- PowerShell 5.1+
- GOG Galaxy installed with games
- Steam installed

## Key Features

- **Intelligent Executable Detection**: Uses GOG's own PlayTasks database for accurate executable identification
- **Launch Arguments Support**: Preserves GOG-specific launch parameters and arguments
- **Existing Shortcuts Preservation**: Safely merges with existing Steam shortcuts without data loss
- **Duplicate Prevention**: Smart detection prevents duplicate entries on subsequent runs
- **Comprehensive Validation**: Enhanced executable validation with GOG authority bypass
- **Modular Design**: Clean separation of database, validation, string processing, and VDF generation functions

## Notes

- Steam must be restarted to see the new shortcuts
- Existing non-Steam shortcuts are automatically preserved
- Database paths are automatically detected
- Special characters in paths are handled correctly
- Re-running the script will only add new GOG games, not create duplicates
- Launch arguments from GOG Galaxy are preserved in Steam shortcuts

## Changelog

### Version 1.1.0 - August 3, 2025
#### Major Enhancements
- **PlayTasks Integration**: Now uses GOG Galaxy's PlayTasks database with `isPrimary = 1` for authoritative executable detection
- **Existing Shortcuts Preservation**: Added `Read-ExistingShortcuts` function to preserve existing Steam shortcuts
- **Smart Merging**: New `Merge-GameShortcuts` function prevents duplicate entries
- **Launch Arguments**: Full support for GOG-specific command line arguments

#### Technical Improvements
- **Enhanced ExecutableValidation**: Added `IsGogAuthoritative` parameter to bypass utility filters for GOG-verified executables
- **Improved String Processing**: Simplified Unicode character replacement for better compatibility
- **VDF Generation**: Comprehensive rewrite with existing shortcuts reading and merging capabilities
- **Database Functions**: Enhanced SQL queries for better game detection and metadata extraction

#### Bug Fixes
- Fixed Unicode character handling in game titles
- Improved path validation and normalization
- Better error handling for missing GOG database entries
- Enhanced executable validation for edge cases
- Fixed Unicode character encoding issues in verbose output (August 3, 2025)

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

## Development Notes

### Recent Architecture Improvements (v1.1.0)

The codebase has been significantly enhanced with better separation of concerns:

1. **DatabaseFunctions.ps1**: Enhanced with PlayTasks queries and existing shortcuts reading
2. **ExecutableValidation.ps1**: Added authoritative validation bypass for GOG-verified executables  
3. **StringProcessing.ps1**: Simplified Unicode handling for better cross-platform compatibility
4. **VdfGeneration.ps1**: Comprehensive rewrite with merging and duplicate detection capabilities

### Key Technical Changes

- **Database Integration**: Enhanced SQL queries leverage GOG's PlayTasks table with `isPrimary=1` filtering
- **Preservation Logic**: New VDF binary reader preserves existing Steam shortcuts
- **Merging Algorithm**: Intelligent path and name-based duplicate detection
- **Error Handling**: Improved robustness with better exception handling and logging
- **Validation Logic**: Context-aware executable validation with GOG authority bypass

## Notes

- File format matches official Steam client behavior
- Handles empty strings and binary data properly
- Preserves exact byte sequence required by Steam
- Generated files can be read by Steam client

## Credits

Based on analysis of Steam's shortcuts.vdf format and C# reference implementation.

