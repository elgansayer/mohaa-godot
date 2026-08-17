# AI Agent Production Factory (`AGENTS.md`)

This repository is optimized for AI-driven development. Various LLM tools and agents can operate on this repository effectively using the files provided below.

## Subagents Architecture

To scale development, we use specialized subagents for different layers of the codebase:

1. **Build Architect (`build-agent`)**:
   - Focus: Maintaining `build.sh`, `CMakeLists.txt`, and `scripts/`.
   - Expertise: Bash, CMake, SCons.
   - Task: Ensure all platforms (Linux, Windows via MinGW, macOS via osxcross, Web via Emscripten) cross-compile smoothly.

2. **Web Pipeline Engineer (`web-agent`)**:
   - Focus: `scripts/web_assets/`.
   - Expertise: Python, Emscripten JS patching, HTML templates, WebSockets.
   - Task: Manage the patching step `scripts/web_assets/patch_web_js.py` and `render_html_template.py`.

3. **GDExtension Developer (`godot-agent`)**:
   - Focus: The bridge between OpenMoHAA and Godot.
   - Expertise: C++, Godot 4 GDExtension, GDScript (`project/`).
   - Task: Integrate engine logic (entities, networking, scene management) seamlessly into Godot nodes.

4. **Engine Specialist (`engine-agent`)**:
   - Focus: `openmohaa/` submodule.
   - Expertise: Legacy Quake 3 / id Tech 3 style C codebase, memory arenas, cvars.
   - Task: Porting legacy systems, memory safety improvements.

## Configuration Files

The repository is equipped with specific rules for various IDEs and CLIs:
- **Cursor**: `.cursorrules`
- **Claude Code**: `CLAUDE.md`
- **GitHub Copilot**: `.github/copilot-instructions.md`
- **Antigravity**: `.antigravity/skills/build/SKILL.md`

## AI Workflow
When modifying the repo, AI should:
1. Refer to the current `README.md` to ensure the platform matrix is respected.
2. Delegate tasks to the appropriate subagent context.
3. Keep the web pipeline separated from the native engine logic.
4. Run `./scripts/test-all.sh` or `./scripts/test-build-matrix.sh` after major changes.
