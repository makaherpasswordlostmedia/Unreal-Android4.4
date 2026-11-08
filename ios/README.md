# iOS (armv7, iOS 7+) port

Everything iOS-specific is plain source in this folder - nothing is generated or patched at build time.

| Path | What |
|------|------|
| `ios/host/` | iOS host: Documents path, file log + crash/heartbeat diagnostics (`ios_diag.mm`), touch controls, config fix-up (`UE1IOSHost.mm`) |
| `ios/overlay/` | iOS-modified copies of engine / SDL2 files. Copied over the shared Android sources (`source/app/src/main/cpp`) before building |
| `ios/cmake/`, `ios/CMakeLists.txt` | armv7 toolchain and top-level build |
| `ios/resources/` | Info.plist, entitlements, icons, launch images |
| `ios/scripts/package_ios.sh` | builds the .ipa |

Build: run the **Build Unreal 98 (iOS armv7)** workflow. It stages `source/.../cpp` into `engine/` + `third_party/`,
overlays `ios/overlay/` on top, copies `ios/CMakeLists.txt` to the root and builds with Theos + iPhoneOS 9.3 SDK.
To change an iOS-specific engine file, edit it under `ios/overlay/` (same relative path).

Tunables in `Unreal.ini` (created on first run) under `[IOSTouch]`: `LookSensitivity`, `ControlsScale`, `RenderScale`.
