# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [1.1.1] - 2025-08-08
### Added
- Unified interactive options menu with numeric input
- End-of-run prompt to launch Steam (interactive mode)

### Changed
- Improved Steam shutdown workflow (graceful -> stop -> force -> taskkill -> manual) with clean cancel
- Simplified Steam user labels to numeric IDs (with [MostRecent])
- Consistent interactive Steam user selection using the same menu style

### Fixed
- Clean cancellation path on manual-close prompt ('q' exits with message and non-zero code)
- Minor comment cleanup and documentation updates

## [1.1.0] - 2025-08-03
### Major Enhancements
- PlayTasks Integration: Now uses GOG Galaxy's PlayTasks database with `isPrimary = 1` for authoritative executable detection
- Existing Shortcuts Preservation: Added `Read-ExistingShortcuts` function to preserve existing Steam shortcuts
- Smart Merging: New `Merge-GameShortcuts` function prevents duplicate entries
- Launch Arguments: Full support for GOG-specific command line arguments

### Technical Improvements
- Enhanced ExecutableValidation: Added `IsGogAuthoritative` parameter to bypass utility filters for GOG-verified executables
- Improved String Processing: Simplified Unicode character replacement for better compatibility
- VDF Generation: Comprehensive rewrite with existing shortcuts reading and merging capabilities
- Database Functions: Enhanced SQL queries for better game detection and metadata extraction

### Bug Fixes
- Fixed Unicode character handling in game titles
- Improved path validation and normalization
- Better error handling for missing GOG database entries
- Enhanced executable validation for edge cases
- Fixed Unicode character encoding issues in verbose output (2025-08-03)

[1.1.1]: https://github.com/your-org/GoG2Steam/releases/tag/v1.1.1
[1.1.0]: https://github.com/your-org/GoG2Steam/releases/tag/v1.1.0

