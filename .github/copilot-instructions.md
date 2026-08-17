# GitHub Copilot Instructions for OpenMoHAA-Godot

This repository uses a layered build system to compile OpenMoHAA into a Godot 4 GDExtension.

## When writing code:
- Check `README.md` for platform support before making platform-specific changes.
- C++ code interacting with Godot is found in the GDExtension layer. Use Godot 4's C++ bindings appropriately.
- If modifying web builds, changes to javascript and HTML must be made in `scripts/web_assets/js/` or `scripts/web_assets/templates/`. The Python scripts in `scripts/web_assets/` just inject these files.
- The root build script is `build.sh`. There is also a CMake orchestrator. Do not assume CMake builds the engine directly; it delegates to the repository's shell scripts, which call SCons.

## Suggested Contexts
- If helping with the engine build, look at `openmohaa/SConstruct`.
- If helping with export, look at `scripts/export-godot.sh`.
- For web patches, review `scripts/web_assets/patch_web_js.py`.
