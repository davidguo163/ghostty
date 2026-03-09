# Plain Click URL Design

**Goal:** Make Ghostty open terminal URLs on plain hover/click in the user's macOS + tmux + Codex workflow, without requiring `Cmd` as a modifier.

**Scope:** `src/config/Config.zig`, `src/Surface.zig`, `src/input/Binding.zig`, `src/input/command.zig`

**Problem:**
- Current default URL link rule uses `hover_mods = ctrlOrSuper(...)`, so plain hover does not activate URL links.
- In the user's real workflow, `Cmd+click` is not reliable enough to serve as the primary URL-open path.

**Chosen approach:**
- Change the default `link-url` matcher from modifier-gated hover to plain `hover`.
- Keep the existing click-to-open path intact so a left click on a hovered URL still routes through the normal system opener.
- Add an explicit fallback action `open_url_under_cursor` plus a default keybind (`Cmd+Shift+O` on macOS, `Ctrl+Alt+O` elsewhere) for cases where terminal URL clicking is still blocked by host integration quirks.
- Make explicit URL actions (`open_url_under_cursor`, `copy_url_to_clipboard`) bypass the default highlight-modifier gate so they still work when the mouse is over a URL but no modifier is held.

**Rejected alternatives:**
- Keep modifier-gated links and only add a shortcut.
  Rejected because the user's main requirement is plain click, not a keyboard fallback.
- Remove click-to-open and only copy the URL.
  Rejected because it does not solve the direct-open workflow.

**Risks:**
- Plain hover makes URLs highlight more aggressively than upstream Ghostty.
- Single-clicking a URL will now prefer opening the link instead of passing the click through to the terminal app.

**Rollback:**
- Revert the default link matcher to `hover_mods = ctrlOrSuper(...)`.
- Keep or remove the explicit fallback action independently.
