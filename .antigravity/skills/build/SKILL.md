---
name: build-mohaa
description: Builds the OpenMoHAA Godot project for various platforms
---

# Build OpenMoHAA Godot

This skill provides instructions on how to build `mohaa-godot` using the project's build system.

## Usage

When the user asks to build the project, determine the target platform and build variant (debug/release), then run the appropriate command.

### Building for Linux
- Debug: `./build.sh build --platform linux`
- Release: `./build.sh build --platform linux --release`
- Package: `./build.sh package --platform linux`

### Building for Windows
- Debug: `./build.sh build --platform windows`
- Release: `./build.sh build --platform windows --release`
- Package: `./build.sh package --platform windows`

### Building for Web
- Full Pipeline (Debug): `./build.sh web-full --asset-path <path-to-assets>`
- Full Pipeline (Release): `./build.sh web-full --release --asset-path <path-to-assets>`

### Testing
- Smoke test: `./scripts/test.sh`
- All tests: `./scripts/test-all.sh`
- Build matrix: `./scripts/test-build-matrix.sh`

## Rules
- Do NOT invoke `scons` directly. Always use `build.sh` or `cmake`.
- For Web builds, ensure the `scripts/web_assets` patch scripts are used by calling `build.sh web-full`.
