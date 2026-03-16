# Ghostty v1.3.1 Rebase + Pane Consolidation Design

**Goal:** Move the local `runai-remote-paste` customization stack onto Ghostty `v1.3.1`, preserve the existing RunAI features, and add a new action that collects every pane into the first tab and closes the remaining tabs without breaking active hyperlink state.

**Release Target:** Upstream Ghostty `v1.3.1` (release date `2026-03-13`, tag object `22efb0be2bbea73e5339f5426fa3b20edabcaa11`, tagged commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`).

**Category:** B

## Scope

- Rebase strategy for `projects/ghostty` local branch `runai-remote-paste`
- Preserve the existing local feature stack:
  - macOS remote paste bridge
  - plain-click URL / `open_url_under_cursor` behavior currently present on the branch
- Add a new bindable action and command-palette command that:
  - moves all panes from every tab into the first tab
  - closes the other tabs afterwards
  - does not recreate panes/surfaces, so active hyperlink state survives
- Expose the pane-consolidation action in the macOS `Window` menu so it is discoverable without manual config
- Cover both supported tab runtimes:
  - macOS (`NSWindowTabGroup` + one `surfaceTree` per tab window)
  - GTK (`adw.TabView` + one `Surface.Tree` per tab)

## Current State

- `runai-remote-paste` does not fork from `v1.2.3` or `main`; the graph merge-base against both `v1.3.1` and `origin/main` is `v1.2.0`.
- The branch already contains the upstream `1.2.x` line plus `10` local commits after `v1.2.3`.
- The right migration unit is therefore the local stack after `v1.2.3`, not the entire `v1.2.0..HEAD` history.
- The most volatile upstream conflict area is the macOS surface/runtime stack, especially `SurfaceView_AppKit`, `AppDelegate.swift`, config bridging, and Xcode project glue.

## Proposer Summary

| Field | Decision |
| --- | --- |
| Rebase base | Start from `v1.3.1`, not from current branch history |
| Local stack to replay | Replay the `10` commits after `6d2dd585a5d87fa745d48188dd096ca6e63014d0` (`v1.2.3`) |
| History policy | Keep behavior, squash checkpoint-only commits where practical |
| New action name | `collect_all_panes_to_first_tab` |
| Existing URL fallback binding | Preserve the current default `open_url_under_cursor` binding exactly as it exists on the branch |
| New action default binding | Do not add a new default binding for `collect_all_panes_to_first_tab` |
| Suggested binding | macOS: `super+ctrl+1`; others: `ctrl+alt+1` |
| macOS menu surface | Add `Window -> Collect All Panes Into First Tab` and keep it disabled unless the current tab group has more than one tab |
| Link preservation rule | Reuse existing `Surface` / `SurfaceView` objects; do not recreate panes |

## Chosen Approach

### 1. Rebase by replaying the local post-`v1.2.3` stack

The working branch should be recreated from `v1.3.1`, then the local commits after `v1.2.3` should be replayed oldest-first. This avoids re-rebasing the already-upstream `1.2.x` history and keeps conflict resolution focused on the actual private feature stack.

This replay must preserve both sides of the link behavior delta:

- the current branch's plain-click / plain-hover URL behavior
- upstream `v1.3.1` right-click link selection/copy behavior

### 2. Implement the new feature as a first-class action

Add a new action key through the normal Ghostty pipeline:

- `src/input/Binding.zig`
- `src/apprt/action.zig`
- `include/ghostty.h`
- `src/Surface.zig`
- `src/input/command.zig`

This keeps the feature available to:

- keybinds
- command palette / commands surface
- platform runtimes

### 3. Preserve active hyperlinks by moving existing pane objects, not rebuilding them

The feature must not create replacement panes and copy terminal contents. Active hyperlink state spans:

- core surface hover state (`mouse.over_link`, `mouse.link_point`)
- terminal OSC8 backing data
- platform hover URL state (`hoverUrl` / hover URL equivalents)

The safe strategy is to graft existing tab trees into the first tab using the existing split-tree models:

- GTK: reuse `datastruct/split_tree.zig` subtree insertion via `SplitTree.split(... insert: *Self)`
- macOS: add an equivalent helper on Swift `SplitTree` and move the existing `SurfaceView` instances into the destination tree

### 4. Keep the new pane-consolidation action unbound by default

The user asked for a suggested shortcut, not a forced default. The current default tables already use:

- `super+shift+o` / `ctrl+alt+o` for `open_url_under_cursor`
- `super+t` / `ctrl+shift+t` for new tab
- `super+d` / `ctrl+shift+o` and neighbors for split operations

Adding another default binding increases cross-platform collision risk for a specialized power action. The new pane-consolidation feature should therefore ship as an action + command, with a recommended config snippet instead of a new default.

This does **not** change the branch's existing default binding for `open_url_under_cursor`; that current URL fallback contract must remain intact.

### 5. Add a native macOS menu entry, but keep the action unbound by default

The new action should be exposed in the existing `Window` menu so the feature is discoverable even before a user edits their config. This should stay a plain menu entry, not a hardcoded menu shortcut, because the requested `super+ctrl+1` combination is still only a recommended keybind and should remain user-configurable through Ghostty's normal binding system.

The menu item should reuse the current `TerminalController` implementation path instead of introducing a second action pipeline. In practice that means:

- add a first-responder `@IBAction`
- have it call the existing pane-consolidation helper
- validate it through `validateMenuItem(_:)` so it is enabled only when the current tab group has more than one tab

## Rejected Alternatives

| Alternative | Rejected Because |
| --- | --- |
| Rebase the full `v1.2.0..HEAD` history onto `v1.3.1` | This replays `95` upstream `1.2.x` commits that already exist upstream and expands the conflict surface dramatically. |
| Recreate panes in the first tab and copy terminal contents | This risks dropping active hyperlink hover state, platform hover URL state, PTY/session identity, and other runtime-owned state. |
| Implement the action on macOS only | The tab/pane model exists on both macOS and GTK, and a one-sided feature would create needless surface inconsistency. |
| Add a new default shortcut immediately for the pane-consolidation action | Current defaults are already dense around tabs, splits, and URL actions; a recommendation is safer than a forced default. |

## Concrete Risks And Mitigations

| Objection | Evidence | Severity | Mitigation |
| --- | --- | --- | --- |
| macOS runtime conflicts will be noisy during replay | Local and upstream both heavily changed `AppDelegate.swift`, `SurfaceView_AppKit`, config bridge, and `project.pbxproj` between `v1.2.3` and `v1.3.1`. | High | Replay only the `10` local commits after `v1.2.3`, resolve conflicts around the renamed `SurfaceView_AppKit` path first, and verify remote-paste behavior immediately after the migration stack lands. |
| Rebase can preserve plain-click URL behavior but accidentally drop upstream `v1.3.1` right-click link behavior | The branch and upstream `v1.3.1` both changed the same mouse/link path in `Surface.zig`. | High | Add explicit regression coverage for right-click link behavior and do not accept a conflict resolution that keeps only one side of the change. |
| The current URL behavior is branch-global, not macOS-only | The branch changed shared config/input defaults, not only macOS files. | High | Treat plain-click URL behavior as an existing cross-platform branch contract to preserve unless the user explicitly narrows scope. |
| Removing the current default `open_url_under_cursor` binding would be a regression | The branch already has a default keybind and tests for `open_url_under_cursor`. | High | Preserve the existing default URL fallback binding unchanged; only the new pane-consolidation action stays unbound by default. |
| A naive pane merge can silently drop active hyperlink state | Current hyperlink hover state is partly surface-owned and partly platform-owned. | High | Treat object reuse as a hard invariant; add identity-based tests that fail if a new pane/view is created instead of reusing the old one. |
| Reusing objects alone may still leave hover state stale after layout changes | Hover/link activation depends on current cursor position and view geometry, not only durable terminal content. | High | After merge, explicitly verify current hover/link activation state, not only URL text presence or object identity. |
| Empty-source-tab behavior differs by platform | macOS closes empty tab windows through controller lifecycle; GTK closes empty tab pages when the tab tree becomes empty. | Medium | Make transfer explicit: first update destination tree, then clear/close source tabs through their platform owner so lifecycle stays native. |
| A default binding may collide with existing defaults | Existing tables already reserve nearby tab/split/URL combinations. | Medium | Ship without a default binding; document the recommended shortcut in the final result. |
| Checkpoint commits may obscure the final intended local behavior | The local stack contains checkpoint/fixup-style commits around remote paste and plain-click URL work. | Medium | Preserve behavior, but squash checkpoint commits while replaying onto `v1.3.1`. |
| Remote paste lacks a durable repo-local selftest lane | Existing docs refer to a selftest entrypoint that is not present in the repo, and CI does not cover remote paste. | High | Treat remote paste verification as a required manual smoke pass after build/test; do not claim it preserved purely from compile success. |

## Files / Systems Affected

- Git history / branch replay
- Zig input/action plumbing
- C ABI header
- macOS AppKit runtime:
  - `Ghostty.App.swift`
  - `BaseTerminalController.swift`
  - `TerminalController.swift`
  - `SplitTree.swift`
- GTK runtime:
  - `application.zig`
  - `window.zig`
  - `tab.zig`
  - `split_tree.zig`
- Tests:
  - `src/datastruct/split_tree.zig`
  - `macos/Tests/*.swift`

## Rollback

- Safety anchor already created: local backup branch `runai-pre-rebase-backup-20260316`
- Implementation should happen on a fresh working branch rooted at `v1.3.1`
- If replay or feature work regresses remote paste, URL behavior, or pane state:
  - discard the working branch
  - return to `runai-pre-rebase-backup-20260316`

## Decision

Proceed with:

1. a fresh branch from `v1.3.1`
2. replay of the `10` local commits after `v1.2.3`
3. preservation of both remote paste and plain-click URL behavior
4. preservation of the current default `open_url_under_cursor` binding
5. a new action `collect_all_panes_to_first_tab`
6. no default binding for the new action, but recommend:
   - macOS: `keybind = super+ctrl+1=collect_all_panes_to_first_tab`
   - others: `keybind = ctrl+alt+1=collect_all_panes_to_first_tab`
