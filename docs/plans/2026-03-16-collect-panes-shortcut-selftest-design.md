# Ghostty Collect Panes Shortcut Selftest Design

**Goal:** Add a repo-owned macOS selftest lane that proves `super+ctrl+1=collect_all_panes_to_first_tab` works without relying on external UI automation.

**Category:** B

## Scope

- Add an app-owned macOS selftest hook in Ghostty
- Add a `scripts/mac.sh` command that launches the built app with an isolated config/home and waits for a report
- Add repo tests that lock the new selftest command and env contract
- Keep the selftest independent from TCC-gated `System Events`, CGEvent injection from SSH, and live user config

## Problem Statement

The current remote Mac environment can prove the action works, but it cannot reliably prove the real shortcut through external input injection:

- Ghostty AppleScript `perform action "collect_all_panes_to_first_tab"` succeeds in a live `2 tabs / 4 panes` scenario
- The configured keybind is visible in `+list-keybinds`
- But both AppleScript `send key` and external CGEvent injection fail to trigger even known default shortcuts such as `Cmd+T`

That means a repo-owned shortcut proof cannot depend on SSH-originated keyboard injection. The selftest must move inside the app process.

## Count / Classification

| Item | Count |
| --- | --- |
| Files / scripts / docs expected to change | 6+ |
| Affected systems | Ghostty macOS runtime, `mac.sh`, local script tests, remote Mac verification workflow |
| External behavior change | Yes, new operator-facing selftest command |

This is **Category B** because it changes workflow/runtime behavior, touches multiple files, and adds an externally visible verification lane.

## Proposer Summary

| Field | Decision |
| --- | --- |
| Selftest owner | Ghostty macOS app runtime |
| Operator entrypoint | `scripts/mac.sh ghostty-collect-panes-shortcut-selftest` |
| Isolation model | Launch built app binary with isolated `HOME` / `XDG_CONFIG_HOME` and temporary config |
| Config under test | isolated home config with `initial-window = false` and `keybind = super+ctrl+1=collect_all_panes_to_first_tab` |
| Proof path | Build `2 tabs / 4 panes`, synthesize a real `NSEvent` for `Cmd+Ctrl+1`, inject it through the focused `SurfaceView.performKeyEquivalent`, then verify tab/pane collapse in-process |
| Report artifact | Text report with pre/post selected-tab index, tab count, pane counts, pane IDs, binding-match status, `performKeyEquivalent` handling result, and final `RESULT=PASS|FAIL` |
| Non-goal | Proving SSH-originated physical keyboard injection works on the remote Mac |

## Considered Approaches

| Approach | Result | Why |
| --- | --- | --- |
| Keep using remote SSH + `System Events` / CGEvent | Rejected | In this environment, external keyboard injection did not trigger even `Cmd+T`, so it is not a stable test owner. |
| Use Ghostty AppleScript `send key` | Rejected | It does not behave like a true shortcut path here; `digit1` with `control,command` left the live tab/pane state unchanged. |
| Add an app-owned selftest hook that uses `Ghostty.Surface.sendKeyEvent` directly | Rejected | That proves Ghostty input/action plumbing, but not macOS `performKeyEquivalent` shortcut routing. |
| Add an app-owned selftest hook that injects a synthetic `NSEvent` into the focused `SurfaceView.performKeyEquivalent` | Chosen | This stays in-process, covers the real macOS shortcut surface, and avoids external TCC/input flakiness. |
| Test only `perform action` | Rejected | That proves the action, not the keybind. The lane must prove that the configured key event resolves to the action. |

## Chosen Approach

### 1. Run the selftest from the app after launch

The macOS app should check a dedicated environment variable such as `GHOSTTY_COLLECT_PANES_SHORTCUT_SELFTEST_ROOT`. When present, the app schedules a one-shot selftest after activation.

The selftest should:

- create a fresh terminal window
- create a right split in tab 1
- create tab 2
- create a right split in tab 2
- capture a pre-state snapshot
- synthesize the keybind through `Ghostty.Surface.sendKeyEvent`
- wait for the pane-consolidation action to complete
- capture a post-state snapshot
- write a report and terminate

### 2. Use isolated config/home from `mac.sh`

The `mac.sh` lane should create an isolated temp root on the remote Mac and launch the built app binary directly with:

- `HOME=<temp>/home`
- `XDG_CONFIG_HOME=<temp>/home/.config`
- a temporary `config.ghostty`

That config should contain only the minimum needed to make the shortcut deterministic:

- `initial-window = false`
- `keybind = super+ctrl+1=collect_all_panes_to_first_tab`

This avoids touching real user config and matches the isolation model already used by the other Ghostty selftests.

### 3. Prove the real shortcut surface, not just the action

Before firing the synthetic key event, the selftest should:

- build a synthetic `NSEvent` for `Cmd+Ctrl+1`
- compute `keyIsBinding(...)` from the same event payload
- call `performKeyEquivalent(with:)` on the focused `SurfaceView`

This gives us stronger evidence than a plain post-state diff alone, because the lane now covers the actual macOS shortcut path used by command/control bindings.

The actual shortcut event should use:

- `keyCode = digit1`
- `modifierFlags = [.command, .control]`
- `characters = "1"`
- `charactersIgnoringModifiers = "1"`

If the state collapses from `2 tabs / [2, 2] panes` to `1 tab / [4] panes`, `performKeyEquivalent` returns handled, and the final pane IDs are exactly the pre-state pane IDs flattened into the first tab, the report is PASS.

## Risks And Mitigations

| Objection | Evidence | Severity | Mitigation |
| --- | --- | --- | --- |
| Direct key-event injection might bypass the normal macOS shortcut path | `SurfaceView.performKeyEquivalent` has additional focus/menu routing logic beyond raw key dispatch. | High | Inject a synthetic `NSEvent` through `performKeyEquivalent(with:)`, not straight through `sendKeyEvent`. |
| Startup timing may race with initial window creation | `applicationDidBecomeActive` currently creates the initial window on first activation. | Medium | Use `initial-window = false` in the isolated config so the selftest owns the only window it creates. |
| Tab creation is async and AppKit tab-group state lags one runloop | `TerminalController.newWindow/newTab` both schedule work on `DispatchQueue.main.async`. | High | Implement bounded polling/wait helpers inside the selftest for “focused surface exists”, tab count, and pane count before taking snapshots. |
| The lane could accidentally mutate real user config | Current ad-hoc verification touched the real user config path. | High | Launch with isolated `HOME` and `XDG_CONFIG_HOME` only; never write to the real home directory. |
| The lane could prove only the action, not the shortcut | Earlier AppleScript `perform action` already proved the action itself works. | High | Require `keyIsBinding=true`, `performKeyEquivalentHandled=true`, and the post-state collapse in the report. |
| Count-only reporting could miss pane recreation/regression | A collapse from four old panes to four new panes would still look green by counts alone. | Medium | Report pane UUIDs per tab and require the final flattened pane IDs to equal the pre-state pane IDs. |

## Files / Systems Affected

- `scripts/mac.sh`
- `src/ghostty-mac-*.test.ts`
- `macos/Sources/App/macOS/AppDelegate.swift`
- new macOS selftest helper source file(s)
- optional macOS unit tests for selftest helper/report logic
- `docs/plans/*`

## Rollback

- The new lane is additive
- Disable by removing the `mac.sh` command and the app-side env check
- No runtime behavior changes happen when the selftest env variable is absent
