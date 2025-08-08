# GoG2Steam - GOG Galaxy to Steam Integration

## Overview

Bring your entire GOG Galaxy library into Steam in minutes — with zero manual tedium. GoG2Steam scans your GOG installs, finds the right executables (using GOG’s authoritative PlayTasks data), and writes polished, duplicate‑free non‑Steam shortcuts straight into Steam.

Why you’ll love it:
- One‑click import: Automatically discovers every installed GOG game
- Looks great in Steam: Clean names with optional prefixes/suffixes and consistent formatting
- Uses the right EXE: Leverages GOG PlayTasks (isPrimary=1) and smart fallbacks when needed
- Respects your setup: Preserves your existing non‑Steam shortcuts and avoids duplicates
- Safe by default: Backs up shortcuts.vdf (unless you opt out) and checks that Steam isn’t running
- Smooth UX: Interactive menu to pick your Steam user and tweak options, or run fully unattended
- Optional verification: Debug mode can read back the written file and show what’s inside

Make Steam your single launcher — keep friends, overlays, controller configs, and playtime tracking in one place.

## Recent Updates

### Version 1.1.1 - August 8, 2025
- Unified interactive options menu with numeric input and consistent Steam user selection
- Improved Steam shutdown workflow with escalation and manual close; clean cancel on 'q'
- Added end-of-run prompt to launch Steam in interactive mode
- Simplified Steam user labels to numeric IDs (with [MostRecent]) to avoid mislabeling
- Minor comment cleanup and transcript logging option

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

Quick start (interactive):
```powershell
# Opens the menu to select Steam user and tweak options
pwsh -NoProfile -File .\GoG2Steam.ps1
```

Unattended run (safe with pre‑checks and backup):
```powershell
pwsh -NoProfile -File .\GoG2Steam.ps1 -NonInteractive
```

Dry run (no file writes, full preview with optional debug):
```powershell
pwsh -NoProfile -File .\GoG2Steam.ps1 -NonInteractive -DryRun -DebugVdf
```

Filter and naming examples:
```powershell
# Add a prefix to names and only import Sim titles
pwsh -File .\GoG2Steam.ps1 -NamePrefix '[GOG] ' -IncludeTitlePattern 'Sim|City'

# Exclude demos/betas and append a suffix
pwsh -File .\GoG2Steam.ps1 -ExcludeTitlePattern 'Demo|Beta' -NameSuffix ' (GOG)'
```

All parameters:
- `-SteamPath <string>`: Steam installation directory (default: Program Files (x86)\Steam)
- `-GogPath <string>`: GOG Galaxy installation directory (default: Program Files (x86)\GOG Galaxy)
- `-GogDb <string>`: Path to GOG Galaxy SQLite DB (default: ProgramData\GOG.com\Galaxy\storage\galaxy-2.0.db)
- `-SteamUserId <string>`: Target Steam user ID (numeric). If omitted, most‑recent user is selected automatically
- `-SelectUser` (switch): Show a user selector even if a default can be inferred (interactive mode)
- `-NamePrefix <string>` / `-NameSuffix <string>`: Text to add before/after each game title
- `-IncludeTitlePattern <regex>` / `-ExcludeTitlePattern <regex>`: Filter which titles are imported
- `-NoBackup` (switch): Skip creating a timestamped backup of shortcuts.vdf
- `-SkipSteamCheck` (switch): Don’t check/close Steam before writing (not recommended)
- `-ForceCloseSteam` (switch): Allow forced close in non‑interactive mode if Steam is running
- `-NonInteractive` (switch): Disable menus and run unattended with provided parameters
- `-DryRun` (switch): Don’t write files; combines well with `-DebugVdf` to preview results
- `-LogPath <string>`: Write a transcript log to this path
- `-DebugVdf` (switch): After writing, read back shortcuts.vdf and print a summary
- `-DebugTitlePattern <regex>`: When debugging, only print entries matching this pattern (default: SimCity)

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

- After writing, you’ll be prompted to launch Steam (interactive mode). Otherwise, restart Steam to see new shortcuts
- Existing non‑Steam shortcuts are preserved and merged intelligently — no duplicates
- Database and installation paths are auto‑detected in most setups
- Special characters in titles/paths are handled correctly
- Re‑running the script is safe; it will only add new games
- Launch arguments from GOG Galaxy are preserved in Steam shortcuts

## Changelog

### Version 1.1.1 - August 8, 2025
#### Added
- Unified interactive options menu with numeric input
- End-of-run prompt to launch Steam (interactive mode)

#### Changed
- Improved Steam shutdown workflow (graceful -> stop -> force -> taskkill -> manual) with clean cancel
- Simplified Steam user labels to numeric IDs (with [MostRecent])
- Consistent interactive Steam user selection using the same menu style

#### Fixed
- Clean cancellation path on manual-close prompt ('q' exits with message and non-zero code)
- Minor comment cleanup and documentation updates

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

Additional assistance and iteration provided by:
- Agent Mode (Warp AI terminal) for repo automation, conflict resolution, and scripting assistance
- Claude Sonnet 4 for UX refinements to the interactive menu and shutdown flow
- OpenAI GPT-4 for implementation guidance and code review suggestions

