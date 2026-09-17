# Extending

## Add or rename a sidebar pane
`SPCatalog.all` in `SPReport.swift` maps Apple's display names to `system_profiler` data
types in Apple's order. `available()` filters to what the machine reports. Rendering is
generic (`MainViewController.append`), so a new data type needs only a catalog entry.

## Change the report look
`MainViewController.append` builds an attributed string: bold 11 pt header, `Label:\tValue`
lines with a tab stop 8 pt past the widest label, 12 pt per nesting level. Node kinds:
`section` (ends with `:`), `pair` (`label: value`), `text` (anything else — payload dumps).

## Change the sidebar
`NSOutlineView`, 15 pt rows, 11 pt font, inside an `NSSplitViewController` sidebar item
(200 pt fixed). Selection is two-way bound to `store.selection` via Combine.

## Custom pane (like Device Management)
Add a `Selection` constant, a branch in `render()` swapping `contentScroll.documentView`,
and a node in `roots()`. Device Management uses an `NSHostingView` of a SwiftUI view.

## Change when we intercept
`shouldIntercept` in `main.swift`. It is consulted at exec **and** by the survivor watcher.
Any relaxation risks bug #12 (LaunchServices relaunch loop). Test all three flows in
`03-verification.md`.

## Change the Device Management detection
Don't, unless the 10-visit test still passes and a fresh System Settings was used. Known
dead ends: idle reaping (backoff), sidebar selection via AX (never changes), mouse-down
click prediction (never fired). The open gap is the occasional survivor of the kill → title
fallback → a few frames.

## Ideas not yet done
- Table-style panes (USB, Applications): Apple shows a table above a detail area; we show the text tree.
- Localisation of pane titles (`"device management"`, `"about"`, `"profiles"` are hardcoded).
- Intel Macs untested.
