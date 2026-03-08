# macOS Remote Paste Host Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a formal macOS Ghostty config key for the remote paste host and verify it through the existing closed-loop selftest and release flow.

**Architecture:** Add a macOS-scoped config field in Zig, expose it through Swift config accessors, thread it into `SurfaceView.DerivedConfig`, and make the remote paste bridge resolve host per request with host-keyed caches. Keep environment override support for automation, remove the hidden `UserDefaults` fallback, and update the closed-loop selftest to pass the host through the formal config surface instead of environment-only injection.

**Tech Stack:** Zig config schema, Swift AppKit/macOS runtime, shell selftest via `scripts/mac.sh`

---

### Task 1: Add the formal config surface

**Files:**
- Modify: `src/config/Config.zig`
- Modify: `macos/Sources/Ghostty/Ghostty.Config.swift`

**Steps:**
1. Add `macos-remote-paste-host` to the macOS config section in `src/config/Config.zig` with docs that explain scope, precedence, and macOS-only behavior.
2. Expose the new field in `Ghostty.Config.swift` as an optional Swift string property.
3. Keep the field nullable so existing installs preserve current fallback behavior.

**Verification:**
- Run a local repo search to confirm the new config key exists in both Zig schema and Swift accessor:
  `rg -n "macos-remote-paste-host|macosRemotePasteHost" src/config/Config.zig macos/Sources/Ghostty/Ghostty.Config.swift`

### Task 2: Wire reload-aware host resolution into the paste bridge

**Files:**
- Modify: `macos/Sources/Ghostty/SurfaceView_AppKit.swift`
- Modify: `macos/Sources/Ghostty/RemotePasteBridge.swift`

**Steps:**
1. Add the new host field to `SurfaceView.DerivedConfig`.
2. Pass the derived host into live remote paste uploads and selftest verification helpers.
3. Replace the single cached remote home with a host-keyed cache.
4. Keep env override support for automation and remove the `UserDefaults` fallback.

**Verification:**
- Build Ghostty and ensure the macOS target compiles:
  `scripts/mac.sh ghostty-build`

### Task 3: Make selftest verify the formal config path

**Files:**
- Modify: `scripts/mac.sh`

**Steps:**
1. Change `ghostty-selftest` to launch Ghostty with `--macos-remote-paste-host=<host>` instead of relying on `GHOSTTY_REMOTE_PASTE_HOST` inside the app process.
2. Keep the shell wrapper variable so CI/ops can still choose which host value is injected into the CLI arg.
3. Preserve the existing `text/file/image` assertions.

**Verification:**
- Run:
  `scripts/mac.sh ghostty-selftest`
- Expected:
  `RESULT=PASS` in `qa/evidence/ghostty-ctrl-v-selftest-<BUILD_ID>.txt`

### Task 4: Rebuild and republish the release artifact

**Files:**
- Modify: release artifact only

**Steps:**
1. Rebuild Ghostty after the code and selftest changes.
2. Run `ghostty-selftest` on the rebuilt app.
3. If selftest passes, run `ghostty-publish`.
4. Verify both versioned and latest URLs return `HTTP 200`.

**Verification:**
- `scripts/mac.sh ghostty-build`
- `scripts/mac.sh ghostty-selftest`
- `scripts/mac.sh ghostty-publish`
- `curl -I -s https://i.run.ceo/downloads/Ghostty-remote-paste-latest.dmg`
