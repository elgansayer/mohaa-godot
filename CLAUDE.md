# CLAUDE.md - Developer Guide for Claude Code

## Project Context
`mohaa-godot` is a Godot 4 port of OpenMoHAA using GDExtension.

## Core Commands
- **Build Linux Engine**: `./build.sh build --platform linux`
- **Build Windows Engine (Cross)**: `./build.sh build --platform windows`
- **Web Export (Full Pipeline)**: `./build.sh web-full --asset-path /path/to/assets`
- **Testing**: `./scripts/test.sh` (smoke test) or `./scripts/test-all.sh`

## Code Style
- **Bash Scripts**: Use `set -e` and double-quote variables.
- **Python**: Use descriptive argument parsing. Web asset strings should only be loaded from `scripts/web_assets/templates/` or `js/`, not inlined.
- **C++**: Follow Godot's GDExtension style guidelines for the binding layer. Respect OpenMoHAA's legacy engine code in `openmohaa/`.

## Important Limitations
- Android and iOS are not fully wired end-to-end.
- MSVC is not supported for native Windows; use MSYS2 MINGW64.
- Assets are not included; require external `pak0.pk3` files in `main/`.
