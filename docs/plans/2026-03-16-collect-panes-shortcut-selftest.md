# Ghostty Collect Panes Shortcut Selftest Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a repo-owned macOS selftest lane that proves the configured shortcut `super+ctrl+1=collect_all_panes_to_first_tab` collapses `2 tabs / 4 panes` into `1 tab / 4 panes`.

**Architecture:** `scripts/mac.sh` will launch the built Ghostty app binary with an isolated temp home/config and a dedicated selftest env var. The Ghostty macOS runtime will detect that env var after activation, create the tab/pane scenario in-process, synthesize a real `Cmd+Ctrl+1` `NSEvent`, inject it through the focused `SurfaceView.performKeyEquivalent`, verify the binding via `keyIsBinding`, and emit a text report for `mac.sh` to pull into `qa/evidence`.

**Tech Stack:** Bash, Vitest, Swift/AppKit, Ghostty input/runtime APIs, remote Mac via `scripts/mac.sh`

---

### Task 1: Lock The New Lane With Failing Script Tests

**Files:**
- Create: `/data/david-EasyCEO/src/ghostty-collect-panes-shortcut-selftest.test.ts`
- Modify: `/data/david-EasyCEO/scripts/mac.sh`

**Step 1: Write the failing test for the new `mac.sh` command**

Assert that `scripts/mac.sh` contains:

- `cmd_ghostty_collect_panes_shortcut_selftest()`
- the command name `ghostty-collect-panes-shortcut-selftest`
- a dedicated env var such as `GHOSTTY_COLLECT_PANES_SHORTCUT_SELFTEST_ROOT`
- isolated config setup containing `super+ctrl+1=collect_all_panes_to_first_tab`

**Step 2: Run the test and verify it fails**

Run:

```bash
pnpm exec vitest run src/ghostty-collect-panes-shortcut-selftest.test.ts
```

Expected: FAIL because the command/env contract does not exist yet.

### Task 2: Add A Pure macOS Selftest Helper Contract First

**Files:**
- Create: `/data/david-EasyCEO/projects/ghostty/macos/Tests/Ghostty/CollectPanesShortcutSelftestTests.swift`
- Create: `/data/david-EasyCEO/projects/ghostty/macos/Sources/App/macOS/CollectPanesShortcutSelftest.swift`

**Step 1: Write the failing Swift test for the selftest report contract**

The test should cover a pure helper that:

- builds a result from pre/post snapshots plus `keyIsBinding` and `performKeyEquivalentHandled`
- returns PASS only when:
  - pre tabs = `2`
  - pre pane counts = `[2, 2]`
  - post selected tab = `1`
  - post tabs = `1`
  - post pane counts = `[4]`
  - the shortcut key event matched a binding
  - `performKeyEquivalent` reported handled
  - the final pane IDs equal the pre-state pane IDs flattened into one tab

**Step 2: Run the targeted macOS test and verify it fails**

Run on the remote Mac:

```bash
cd /tmp/ghostty-build-<build-id>/ghostty/macos && \
xcodebuild -project Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/CollectPanesShortcutSelftestTests test
```

Expected: FAIL because the helper does not exist yet.

### Task 3: Implement The App-Owned Selftest Hook

**Files:**
- Modify: `/data/david-EasyCEO/projects/ghostty/macos/Sources/App/macOS/AppDelegate.swift`
- Create: `/data/david-EasyCEO/projects/ghostty/macos/Sources/App/macOS/CollectPanesShortcutSelftest.swift`

**Step 1: Add the minimal pure helper to make the Swift test pass**

Create a selftest helper with:

- env parsing (`GHOSTTY_COLLECT_PANES_SHORTCUT_SELFTEST_ROOT`)
- a pure snapshot/report model
- PASS/FAIL evaluation logic

**Step 2: Hook the selftest into app startup**

In `AppDelegate`, after the app becomes active, detect the env var and run the selftest once. Use bounded async polling instead of raw sleeps where possible.

**Step 3: Implement the live scenario**

Inside the selftest:

- create a new window via `TerminalController.newWindow`
- split tab 1 to the right
- create tab 2 via `TerminalController.newTab`
- split tab 2 to the right
- capture a pre-state snapshot from the live controllers
- focus the second tab's focused `SurfaceView`
- create a synthetic `NSEvent` for `Cmd+Ctrl+1`
- record `keyIsBinding(...)` from that event payload
- inject it via `surfaceView.performKeyEquivalent(with:)`
- poll for the post-state collapse
- write `report.txt`
- terminate the app

**Step 4: Re-run the Swift test**

Run the same targeted macOS test again.

Expected: PASS.

### Task 4: Implement The `mac.sh` Lane

**Files:**
- Modify: `/data/david-EasyCEO/scripts/mac.sh`
- Modify: `/data/david-EasyCEO/src/ghostty-collect-panes-shortcut-selftest.test.ts`

**Step 1: Add the new command**

Implement `ghostty-collect-panes-shortcut-selftest` so it:

- reads `REMOTE_APP` from `GHOSTTY_BUILD_META`
- creates a temp remote root
- writes isolated config into `<root>/home`
- launches `Ghostty.app/Contents/MacOS/ghostty` with:
  - `HOME=<root>/home`
  - `XDG_CONFIG_HOME=<root>/home/.config`
  - `GHOSTTY_COLLECT_PANES_SHORTCUT_SELFTEST_ROOT=<root>`
- waits for `report.txt`
- pulls the report into `qa/evidence`

**Step 2: Wire help/usage/case dispatch**

Update:

- usage text
- the command dispatch switch

**Step 3: Re-run the Vitest script test**

Run:

```bash
pnpm exec vitest run src/ghostty-collect-panes-shortcut-selftest.test.ts
```

Expected: PASS.

### Task 5: Verify The End-To-End Lane

**Files:**
- Verify only

**Step 1: Build Ghostty on the remote Mac if needed**

Run:

```bash
bash /data/david-EasyCEO/scripts/mac.sh ghostty-build
```

**Step 2: Run the new selftest lane**

Run:

```bash
bash /data/david-EasyCEO/scripts/mac.sh ghostty-collect-panes-shortcut-selftest
```

Expected report fields:

- `PRE_SELECTED_TAB=2`
- `PRE_TABS=2`
- `PRE_TAB1_TERMINALS=2`
- `PRE_TAB2_TERMINALS=2`
- `KEY_IS_BINDING=1` (or equivalent truthy field)
- `PERFORM_KEY_EQUIVALENT_HANDLED=1`
- `POST_SELECTED_TAB=1`
- `POST_TABS=1`
- `POST_TAB1_TERMINALS=4`
- `POST_TAB1_IDS=<same four IDs from PRE_TAB1_IDS + PRE_TAB2_IDS>`
- `RESULT=PASS`

**Step 3: Re-run the existing relevant script tests**

Run:

```bash
pnpm exec vitest run \
  src/ghostty-mac-build.test.ts \
  src/ghostty-mac-release.test.ts \
  src/ghostty-url-click-selftest.test.ts \
  src/ghostty-collect-panes-shortcut-selftest.test.ts
```

Expected: PASS.
