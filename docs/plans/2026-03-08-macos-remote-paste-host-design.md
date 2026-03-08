# macOS Remote Paste Host Design

**Goal:** Add a formal Ghostty config key for the macOS remote paste target host so users can set it in normal Ghostty config or CLI args, and existing windows pick up reloads.

**Scope:** `src/config/Config.zig`, macOS config accessors, macOS remote paste bridge, surface reload wiring, and `scripts/mac.sh` selftest coverage.

**Affected files / systems:**
- `src/config/Config.zig`
- `macos/Sources/Ghostty/Ghostty.Config.swift`
- `macos/Sources/Ghostty/RemotePasteBridge.swift`
- `macos/Sources/Ghostty/SurfaceView_AppKit.swift`
- `scripts/mac.sh`
- `docs/plans/2026-03-08-macos-remote-paste-host-plan.md`

**Chosen approach:**
- Add a macOS-scoped config key: `macos-remote-paste-host`.
- Keep the behavior macOS-only, matching the current `Cmd-Shift-V` remote paste bridge.
- Resolve host in this order:
  1. `GHOSTTY_REMOTE_PASTE_HOST` environment variable for automation and selftest overrides
  2. `macos-remote-paste-host` from Ghostty config / CLI args
  3. fallback alias `dev`
- Thread the configured host through `SurfaceView.DerivedConfig` so config reload updates existing surfaces without relaunching the app.
- Replace the single cached remote home with a cache keyed by host so changing targets does not reuse stale home directories.
- Drop the legacy `UserDefaults` fallback so clearing the formal config key really resets behavior.
- Update `scripts/mac.sh ghostty-selftest` to verify the formal config surface via CLI arg instead of env injection.

**Rejected alternatives:**
- Generic `remote-paste-host` top-level key.
  Rejected because the feature is currently macOS-only and Ghostty’s config schema already namespaces platform-only behavior with `macos-*` / `gtk-*`.
- Keep using `UserDefaults` as a legacy fallback.
  Rejected because it breaks the normal config reset/default semantics once a formal key exists; deleting the config key would still silently reactivate hidden state.
- Read global app config lazily inside `RemotePasteBridge`.
  Rejected because `SurfaceView` already maintains `DerivedConfig` snapshots that update on config change, which is the existing reload integration point.

**Risks and mitigations:**
- Reload mismatch on existing windows.
  Mitigation: derive the host in `SurfaceView.DerivedConfig`, which already refreshes on `ghosttyConfigDidChange`.
- Stale cache when switching hosts.
  Mitigation: cache remote home per host instead of globally.
- Silent regression in the only closed-loop path.
  Mitigation: make `ghostty-selftest` use the formal config/CLI path and keep the existing `text/file/image` end-to-end assertions.

**Rollback:**
- Revert the new config field and restore the previous env/UserDefaults-only lookup path.

**Category B gate summary:**
- Total items touched: 6 code/workflow items plus 2 docs items.
- Systems affected: config schema, macOS runtime behavior, release selftest.
- Category: B

**Challenger review:**

| Objection | Evidence | Resolution |
| --- | --- | --- |
| Reload would not work if host stays a `static let` | `macos/Sources/Ghostty/RemotePasteBridge.swift` currently initializes `remoteHost` once, while `Ghostty.App.reloadConfig` creates a fresh `Ghostty.Config` and existing surfaces refresh `DerivedConfig` on config change. | Read the host per request through `SurfaceView.DerivedConfig`, not a process-global constant. |
| A single cached remote home would poison host switches | `RemotePasteBridge` caches one remote home globally, but uploads derive `remotePath` from that cache before choosing the SSH target host. | Cache remote home per host key. |
| “config first but env override” is ambiguous and easy to implement incorrectly | Current bridge uses early-return precedence for env/UserDefaults. | Make precedence explicit: env override first, then formal config, then `dev`. |
| Keeping `UserDefaults` fallback breaks reset semantics | `ghostty_config_get` cannot distinguish “unset” from “nil optional” for this purpose, and Ghostty config docs treat empty/unset values as normal reset paths. | Remove `UserDefaults` fallback once the formal config key exists. |
| A non-namespaced key would leak platform-specific behavior into the public cross-platform config surface | Existing platform-only keys use `macos-*` and `gtk-*` namespaces in `src/config/Config.zig`. | Use `macos-remote-paste-host`. |
