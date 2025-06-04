# GoG2Steam 🎮

**Automatically import all your GOG Galaxy games as Steam shortcuts with perfect launch fidelity.**

This PowerShell script reads your GOG Galaxy database and creates Steam non-game shortcuts for all your installed GOG games, using GOG's own launch configuration for maximum compatibility.

## ✨ Features

- **🎯 Perfect Launch Fidelity**: Uses GOG Galaxy's own `PlayTasks` database to get the exact executable and launch parameters for each game
- **🚀 100% Automatic**: No manual configuration or game-specific tweaks needed
- **💾 Safe Backup**: Automatically backs up your existing Steam shortcuts before making changes
- **🎮 Complete Launch Arguments**: Preserves complex DOSBox configurations, launcher parameters, and game-specific arguments
- **📁 Accurate Working Directories**: Sets proper start directories for each game
- **🔄 Preserves Existing Shortcuts**: Merges with your current non-Steam games instead of replacing them
- **⚡ High Performance**: Direct database queries with minimal processing overhead

## 🛠️ How It Works

1. **Database Analysis**: Reads GOG Galaxy's SQLite database (`galaxy-2.0.db`) to find all installed games
2. **Authoritative Launch Data**: Queries the `PlayTasks` table with `isPrimary = 1` to get the exact executable and launch parameters that GOG Galaxy uses
3. **Steam Integration**: Generates a properly formatted binary `shortcuts.vdf` file that Steam recognizes
4. **Launch Argument Preservation**: Captures complex launch configurations (DOSBox parameters, compatibility flags, etc.)

## 📋 Requirements

- **Windows 10/11**
- **PowerShell 5.1+** (PowerShell 7+ recommended)
- **GOG Galaxy** installed with games
- **Steam** installed
- **PSSQLite PowerShell module** (automatically installed if missing)

## 🚀 Quick Start

1. **Clone the repository**:
   ```powershell
   git clone https://github.com/yourusername/GoG2Steam.git
   cd GoG2Steam
   ```

2. **Run the script**:
   ```powershell
   .\goggames2steam.ps1
   ```

3. **Restart Steam** to see your GOG games in the library!

## ⚙️ Advanced Usage

### Custom Paths
```powershell
# Specify custom Steam or GOG installation paths
.\goggames2steam.ps1 -SteamPath "D:\Steam" -GogPath "D:\GOG Galaxy"

# Use custom GOG database location
.\goggames2steam.ps1 -GogDb "C:\CustomPath\galaxy-2.0.db"

# Skip backup creation (not recommended)
.\goggames2steam.ps1 -NoBackup
```

### Parameters

| Parameter | Description | Default |
|-----------|-------------|----------|
| `-SteamPath` | Steam installation directory | `C:\Program Files (x86)\Steam` |
| `-GogPath` | GOG Galaxy installation directory | `C:\Program Files (x86)\GOG Galaxy` |
| `-GogDb` | GOG Galaxy database file path | `C:\ProgramData\GOG.com\Galaxy\storage\galaxy-2.0.db` |
| `-NoBackup` | Skip creating backup of existing shortcuts | `false` |

## 📊 What Gets Imported

### Executable Discovery
The script uses GOG Galaxy's authoritative launch data:
- **Primary Executables**: Uses `PlayTasks` table with `isPrimary = 1`
- **Launch Arguments**: Preserves DOSBox configs, compatibility parameters, mod loaders
- **Working Directories**: Sets correct start directories for proper game operation

### Examples of Launch Configurations
- **Modern Games**: Direct executable paths (e.g., `Fallout4Launcher.exe`)
- **DOSBox Games**: Complex configurations with multiple config files
- **Legacy Games**: Compatibility wrappers and custom launchers
- **Modded Games**: Mod loader executables with specific parameters

## 🗂️ Project Structure

```
GoG2Steam/
├── goggames2steam.ps1          # Main script
├── functions/
│   ├── DatabaseFunctions.ps1    # SQLite database operations
│   ├── StringProcessing.ps1     # Game title cleaning utilities
│   ├── ExecutableValidation.ps1 # File validation functions
│   └── VdfGeneration.ps1        # Steam VDF file generation
└── README.md                    # This file
```

## 🔧 Technical Details

### Database Queries
The script uses sophisticated SQL queries to extract launch data:
```sql
SELECT pltp.executablePath, pltp.commandLineArgs
FROM PlayTasks pt
JOIN PlayTaskLaunchParameters pltp ON pt.id = pltp.playTaskId
JOIN ProductsToReleaseKeys ptrk ON pt.gameReleaseKey = ptrk.releaseKey
WHERE ptrk.gogId = [productId] AND pt.isPrimary = 1
```

### Steam VDF Format
Generates binary VDF files that Steam expects:
- Proper data type encoding (strings, integers, binary data)
- Correct field ordering and structure
- Steam-compatible entry formatting

## 🛡️ Safety Features

- **Automatic Backups**: Creates timestamped backups of existing shortcuts
- **Path Validation**: Verifies all executable paths before adding to Steam
- **Error Handling**: Graceful handling of missing files or database issues
- **Non-Destructive**: Preserves existing Steam shortcuts alongside GOG imports

## 🎮 Supported Game Types

- ✅ **Modern Native Games** (Direct executables)
- ✅ **DOSBox Games** (With full configuration preservation)
- ✅ **ScummVM Games** (Engine-based games)
- ✅ **Legacy Windows Games** (Compatibility wrappers)
- ✅ **Modded Games** (Custom launchers and mod loaders)
- ✅ **Multi-Executable Games** (Automatically selects primary executable)

## 🔍 Troubleshooting

### Common Issues

**"GOG Galaxy database not found"**
- Ensure GOG Galaxy is installed and has been run at least once
- Check if the database path is correct with `-GogDb` parameter

**"No GOG games found"**
- Verify games are actually installed in GOG Galaxy
- Check that games show as "Installed" in GOG Galaxy interface

**"Steam userdata directory not found"**
- Ensure Steam is installed and has been run at least once
- Use `-SteamPath` parameter if Steam is in a custom location

### Debug Mode
Run with verbose output for detailed information:
```powershell
.\goggames2steam.ps1 -Verbose
```

## 🤝 Contributing

Contributions are welcome! Please feel free to:
- Report bugs and issues
- Suggest new features
- Submit pull requests
- Improve documentation

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ⚠️ Disclaimer

This script modifies Steam's shortcuts database. While it creates backups and has been tested extensively, use at your own risk. Always ensure you have backups of important data.

## 🙏 Acknowledgments

- Thanks to the GOG Galaxy and Steam communities for reverse engineering the database formats
- Inspired by various game library management tools
- Built with PowerShell and the PSSQLite module

---

**Made with ❤️ for gamers who want their libraries organized!**
