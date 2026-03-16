# Ghostty v1.3.1 Rebase + Pane Consolidation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebase the local Ghostty customization stack onto `v1.3.1`, preserve existing RunAI behavior, and add a cross-platform action that collects all panes into the first tab without recreating surfaces.

**Architecture:** Recreate the working branch from `v1.3.1`, replay only the local commits after `v1.2.3`, then add the new action through the normal Ghostty binding/action/runtime pipeline. The pane-consolidation feature must reuse existing `Surface` / `SurfaceView` objects so active hyperlink state survives. During rebase, preserve both the branch's plain-click URL behavior and upstream `v1.3.1` right-click link behavior. Use subtree merge helpers for GTK/Zig and equivalent tree grafting for macOS Swift.

**Tech Stack:** Git, Zig, AppKit/Swift, GTK/libadwaita, xcodebuild via `zig build test`

---

### Task 1: Recreate The Branch On v1.3.1

**Files:**
- Modify: replay result for the existing local stack after `v1.2.3`
- Verify: `git log`, `git diff --stat`, `zig build`

**Step 1: Create the fresh working branch from `v1.3.1`**

Run:

```bash
git -C /data/david-EasyCEO/projects/ghostty switch -c runai-v1-3-1-work v1.3.1
```

Expected: branch starts from `v1.3.1`.

**Step 2: Replay the local commits after `v1.2.3` oldest-first**

Run:

```bash
git -C /data/david-EasyCEO/projects/ghostty cherry-pick \
  9ea200801 \
  082355483 \
  3aefbf7be \
  6b68cbfe8 \
  981b90626 \
  1db1b3649 \
  280d1ce14 \
  f16759fee \
  6e69e2b13 \
  5e41a8cce
```

Expected: conflicts only in the local customization surface, not the entire `1.2.x` history.

**Step 3: Resolve replay conflicts by preserving behavior, not checkpoint history**

Focus first on:

- `macos/Sources/App/macOS/AppDelegate.swift`
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- `macos/Sources/Ghostty/Ghostty.Config.swift`
- `src/config/Config.zig`
- `src/Surface.zig`
- `src/input/Binding.zig`
- `src/input/command.zig`
- `macos/Ghostty.xcodeproj/project.pbxproj`

Expected: remote paste and plain-click URL behavior still exist on the fresh branch, and upstream `v1.3.1` right-click link behavior is not regressed.

**Step 4: Run a baseline build before adding new behavior**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build
```

Expected: the rebased branch builds before the new feature starts.

**Step 5: Re-run the existing branch URL defaults tests**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='default keybind includes open url under cursor'
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='default url link is hover activated'
```

Expected: PASS. These are the branch's current URL fallback/default-behavior guardrails and must stay green.

### Task 2: Add The Failing Tree-Merge Tests First

**Files:**
- Modify: `src/datastruct/split_tree.zig`
- Create: `macos/Tests/SplitTreeTests.swift`
- Modify: `src/Surface.zig` if a right-click link regression test is needed

**Step 1: Write the failing Zig test for subtree grafting**

Add a test that:

- builds a destination split tree with more than one leaf
- builds a source split tree with more than one leaf
- inserts the source tree into the destination tree
- asserts leaf order and pointer identity are preserved

**Step 2: Run the targeted Zig test and confirm it fails for the missing helper/API**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='SplitTree: collect all panes'
```

Expected: FAIL because the consolidation helper or expected semantics do not exist yet.

**Step 3: Write the failing macOS SplitTree test**

Add a new Swift test that:

- constructs two non-trivial `SplitTree` values
- grafts the second into the first with the new helper
- asserts the same `SurfaceView` objects remain present after the merge
- asserts hover/link-facing state survives on the moved views

**Step 4: Run the test suite and confirm the new Swift test fails**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test
```

Expected: FAIL because the Swift helper/runtime glue does not exist yet.

**Step 5: Add a failing regression test for upstream `v1.3.1` right-click link behavior if coverage is missing**

Expected: FAIL until the rebased mouse/link path preserves both upstream and local URL behavior.

### Task 3: Add The New Action Plumbing

**Files:**
- Modify: `src/input/Binding.zig`
- Modify: `src/apprt/action.zig`
- Modify: `include/ghostty.h`
- Modify: `src/Surface.zig`
- Modify: `src/input/command.zig`

**Step 1: Add the failing binding/command test**

Add tests that prove:

- `collect_all_panes_to_first_tab` parses as a valid action
- it appears in the command set / command palette surface
- the existing `open_url_under_cursor` default binding remains intact

**Step 2: Run the targeted parse/command tests**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='collect_all_panes_to_first_tab'
```

Expected: FAIL because the action key does not exist yet.

**Step 3: Implement the minimal action plumbing**

Add:

- the new binding enum key
- the new apprt action key
- the C ABI entry
- `Surface.performBindingAction` dispatch
- command palette metadata

**Step 4: Re-run the targeted tests**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='collect_all_panes_to_first_tab'
```

Expected: PASS for the parse/command tests.

### Task 4: Implement GTK Pane Consolidation

**Files:**
- Modify: `src/apprt/gtk/class/application.zig`
- Modify: `src/apprt/gtk/class/window.zig`
- Modify: `src/apprt/gtk/class/tab.zig`
- Modify: `src/apprt/gtk/class/split_tree.zig`
- Modify: `src/datastruct/split_tree.zig` if a helper is needed

**Step 1: Keep the failing Zig subtree test red**

Do not write GTK runtime code until the helper semantics are still captured by the failing test.

**Step 2: Implement the minimal GTK runtime path**

Use the existing `Surface.Tree.split(... insert: *Self)` model to:

- locate tab `0`
- merge each later tab tree into tab `0`
- keep the same `Surface` objects
- clear/close the emptied tabs via native tab ownership
- preserve or explicitly refresh link-hover state after layout changes

**Step 3: Re-run the targeted Zig test**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test -Dtest-filter='SplitTree: collect all panes'
```

Expected: PASS.

### Task 5: Implement macOS Pane Consolidation

**Files:**
- Modify: `macos/Sources/Ghostty/Ghostty.App.swift`
- Modify: `macos/Sources/Features/Splits/SplitTree.swift`
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift`
- Modify: `macos/Sources/Features/Terminal/TerminalController.swift`

**Step 1: Keep the failing Swift test red**

Use the new `macos/Tests/SplitTreeTests.swift` test as the red bar.

**Step 2: Add the minimal macOS helper and controller flow**

Implement:

- a Swift `SplitTree` helper that can graft a whole source tree into a destination tree while reusing the same `SurfaceView` instances
- a `Ghostty.App` runtime action hook
- a controller method that:
  - finds the first tab window
  - merges every other tab `surfaceTree` into it
  - closes the emptied source tabs after transfer
  - preserves or explicitly refreshes current hover/link-facing state after layout changes

**Step 3: Re-run the full test suite**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build test
```

Expected: PASS for both Zig and macOS tests.

### Task 6: Verify Existing RunAI Features Still Work

**Files:**
- Verify only:
  - `macos/Sources/App/macOS/AppDelegate.swift`
  - `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  - `macos/Sources/Ghostty/Ghostty.Config.swift`
  - `src/config/Config.zig`
  - `src/Surface.zig`
  - `src/input/Binding.zig`
  - `src/input/command.zig`

**Step 1: Run the complete build and test pass**

Run:

```bash
cd /data/david-EasyCEO/projects/ghostty && zig build && zig build test
```

Expected: PASS.

**Step 2: Sanity-check the preserved local behaviors in code and tests**

Verify that the rebased branch still contains:

- macOS remote paste bridge code paths
- plain-click URL / `open_url_under_cursor` behavior
- upstream `v1.3.1` right-click link behavior
- the new pane-consolidation action

**Step 3: Run a manual remote-paste smoke pass**

There is no durable repo-local automated remote-paste selftest in this checkout. After build/test, run a manual smoke verification on macOS before claiming the feature survived the rebase.

**Step 4: Capture the recommended shortcut in the final handoff**

Use:

```text
macOS: keybind = super+ctrl+1=collect_all_panes_to_first_tab
Other platforms: keybind = ctrl+alt+1=collect_all_panes_to_first_tab
```

**Step 5: Diff review**

Run:

```bash
git -C /data/david-EasyCEO/projects/ghostty status --short
git -C /data/david-EasyCEO/projects/ghostty diff --stat
```

Expected: only the intended rebase resolutions, new action, and new tests remain.
