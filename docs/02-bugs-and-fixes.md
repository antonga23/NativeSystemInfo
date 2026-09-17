# Bugs encountered, root causes, fixes

Chronological. Each was verified before being called fixed; the verification method is
noted because several "fixes" earlier looked fine under a weaker check.

| # | Symptom | Root cause | Fix | Verified by |
| --- | --- | --- | --- | --- |
| 1 | Pre-warmed window visible at screen edge while idle | AppKit `constrainFrameRect` clamps titled windows back onto a display; the off-screen park silently failed | `PrewarmWindow` overrides `constrainFrameRect` | `verify` showed window at `0,178`; after fix at `-14000,…` |
| 2 | Apple's window still showed for ~450 ms | `NSRunningApplication.hide()` returns false during launch; even a 2 ms retry loop left the window up 457 ms | Kill instead of hide | `flashwatch` 2 ms sampler |
| 3 | Enforcement loop believed window hidden while it was on screen | `isHidden` reported true with the window genuinely visible | Enforcement reads `CGWindowList`, never `isHidden` | `verify` + `isHidden` side by side |
| 4 | Cold-launch flash of ~300 ms despite kill | `NSWorkspace.runningApplications` only reflects LaunchServices registration (~1072 ms), after the window (~763 ms). The earlier "40 ms" was measured on a warm relaunch | Poll `proc_listallpids` (exec time, ~67 ms) | wall-clock aligned log vs flashwatch |
| 5 | Exec detection found nothing at all | (a) `proc_listallpids(nil,0)` returns 0, not a size — sizing call disabled detection; (b) LaunchServices starts apps as `xpcproxy` which execs **keeping the pid**, so a one-time path check sees only xpcproxy | Preallocated buffer; `pending` map re-checks xpcproxy pids each tick | `pidwatch` standalone |
| 6 | First present after agent start took 1–2.5 s | Window's first-ever ordering at `.floating` level is not placed on screen by the window server for ~1.2 s while AppKit says `isVisible == true` | Never use `.floating`; `ensureOnScreen` safety net polls window list | `winprobe` (`kCGWindowIsOnscreen`) experiments A/B/C |
| 7 | Window opened on a different desktop / ~700 ms slide | Parked window ordered front at agent start pinned it to that Space; presenting triggered a Space switch | `collectionBehavior = [.moveToActiveSpace]` | `activeSpaceDidChangeNotification` log: 0 during present |
| 8 | Window ratcheted to full screen width | Coverage unioned with the *current* frame; System Settings shows a transient second window while changing panes | Cover the target's **largest** window; union against default frame; watch requires a stable target | `verify` over repeat visits |
| 9 | Device Management pane didn't switch in sidebar | SwiftUI `List` drops a selection whose row is inside a collapsed group | Expand group before selecting (now AppKit outline, moot) | log `sidebar selection ->` |
| 10 | Apple's DM pane visible 8+ frames | Title-change detection is by construction post-render | Kill `ProfilesSettingsExt` at exec | recording frame-by-frame; log shows title never reached "Device Management" |
| 11 | About This Mac opened our app; then System Report showed Apple's on top of ours | Same binary; left alive, System Report opens a new window in the existing process — no exec to see | Context rule `shouldIntercept` + watch/reap survivor | log decisions; three flows tested |
| 12 | Our window kept reappearing, couldn't be closed; later nothing intercepted at all | Killing an About-This-Mac launch → LaunchServices relaunch loop (~10×), then LS stops honouring launches | Never kill unless the rule passes; launcher-based detection was insufficient (real Apple menu skips the launcher) | log: 10 kills 1 s apart |
| 13 | About This Mac still misfired with Settings frontmost | Apple menu belongs to the frontmost app | Rule requires title "About" **and** mouse not in the top-left menu region | mouse warped to both positions, decisions logged |
| 14 | System Report opened on Device Management pane | Last selection persisted | `presentSystemReport` resets to Hardware | recording |
| 15 | Spotlight/`open` launch of System Information killed post-render | Survivor watcher ignored the rule | Rule applied to the survivor path too | log |
| 16 | 8 DM visits, only 1 triggered; pane wouldn't open | Reaping the idle extension tripped ExtensionKit relaunch backoff | **Reverted.** Kill once per visit only | 10-visit test |
| 17 | Content column collapsed to 1 pt | With `contentViewController` the window adopts the split view's fitting width | `preferredContentSize` + min width on content column | layout log |
| 18 | Profiles/SmartCards panes bold and spaced wrongly | Parser treated any line without `": "` as a section | Node kinds section/pair/text | parsetest + user screenshots |
| 19 | Fonts/rows/columns didn't match Apple | Guessed 13 pt; Apple is 11 pt small system font, 15 pt sidebar rows, tab-aligned columns | Measured from 2× captures with interception paused | side-by-side captures |

| 20 | List panes showed only text, no table | Apple's panes are a table over a detail area; we rendered the detail full-height | Table built from Apple's own `SPProperties.plist` column declarations | Profiles/Managed Client captures vs screenshots |
| 21 | Profiles' first column header read "Apple Internal Card Readers" | Header strings were pooled across all reporter bundles; key names like `_name` are reused with different meanings | Per-bundle strings win, pooled table is fallback only | capture |
| 22 | Detail pane had zero height under the table | `NSSplitView` gave the table everything | Explicit divider position + holding priorities | capture |
| 23 | Breadcrumb showed the serial number | It read `SPHardwareDataType`; Apple uses the **ComputerName**. Only looked right because MDM renamed this Mac to its serial | `NSPathControl` with computer name > group > pane > row ancestry | capture |
| 24 | "Log Reports" / "Legacy Software" / missing "Rosetta Software" | Two mislabelled catalog entries; Rosetta is `SPLegacySoftwareDataType`, never missing | Renamed and reordered | reporter banners |
| 25 | Cmd-A / Cmd-C dead on report text | No Edit menu in `NSApp.mainMenu` | Added Edit menu (invisible under `.accessory`, key equivalents still fire) | measured selection range |
| 26 | **System Report interception silently stopped** | The gate required the pane title == "About", but the title was read from the *focused* window, which after a focus change is a transient with an empty title — the cached "" made the gate decline | Read the **main** window; an empty/unknown title no longer declines, it falls through to the mouse test | 3/3 intercepts after fix |

Non-bugs that looked like bugs:

- `flashwatch` reporting "our window at 2 s" — that metric is unreliable; use the app log.
- `flashwatch` saying "never visible" for Device Management — it only tracks
  `com.apple.SystemProfiler` windows; the DM pane is inside System Settings' window.
- A harness that leaves *our* window frontmost makes the next System Report decline with
  "Settings not frontmost" — correct behaviour, not a bug. Re-activate Settings between runs.
- "accessibility not granted" when the agent is launched from Terminal — TCC attributes a
  Terminal-spawned process to Terminal. Judge AX only via the launchd instance.
