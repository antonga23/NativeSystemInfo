# Architecture

## Processes and files

| Thing | Where |
| --- | --- |
| Agent binary | `~/Applications/System Information.app/Contents/MacOS/NativeSystemInfo` |
| LaunchAgent | `~/Library/LaunchAgents/com.alatha.nativesysteminfo.plist` (RunAtLoad + KeepAlive) |
| Log | `/tmp/nsi.log` — `[epoch ms] [ms since first mark] message` |
| Pause switch | `/tmp/nsi.pause` (exists → intercept nothing) |
| Signing identity | `NativeSystemInfo Local Signing`, self-signed, in the login keychain |
| Redeploy | `./build.sh && rm -rf ~/Applications/"System Information.app" && cp -R "build/System Information.app" ~/Applications/ && launchctl kickstart -k gui/$(id -u)/com.alatha.nativesysteminfo` |

The app is `LSUIElement` and stays `.accessory` **permanently** — there is no Dock icon at
any point. Cmd-W/Cmd-Q/Cmd-A/Cmd-C work because `NSApp.mainMenu` acts as an invisible
key-equivalent table even though an accessory app never draws a menu bar. (Apple's own
System Information promotes to `.regular` and does show a Dock tile; this is a chosen
divergence.) Cmd-Q closes the window
and returns to idle rather than exiting; launchd restarts it if it does die.

## Sources

| File | Role |
| --- | --- |
| `main.swift` | Wires everything; holds the `shouldIntercept` rule |
| `Interceptor.swift` | Process-table poll (8 ms). Detects System Information, the profiles extension, the About This Mac launcher. Kills at exec. |
| `DeviceManagementWatcher.swift` | AXObserver + 50 ms poll on System Settings' window title; navigates Settings back to General |
| `ReplacementWindow.swift` | Pre-warmed off-screen window, present/cover/reassert, coverage watch, `ensureOnScreen` |
| `Coverage.swift` | `CGWindowList` bounds of another pid → AppKit frame that covers it |
| `MainView.swift` | AppKit shell: sidebar, table-over-detail split, `NSPathControl` breadcrumb |
| `SPColumns.swift` | Table columns read from Apple's `*.spreporter` bundles at runtime |
| `SPReport.swift` | `system_profiler` text parser, sidebar catalog, report cache |
| `DeviceManagement.swift`, `RootView.swift` | Device Management data and its SwiftUI pane (hosted) |
| `Log.swift` | The log |
| `*.swift` in repo root | Diagnostic tools — see `03-verification.md` |

## System Report flow

```
user clicks System Report (System Settings frontmost, pane "About")
  → LaunchServices spawns xpcproxy → execs System Information   (~+40 ms)
  → Interceptor sees the exec (8 ms poll, re-checks xpcproxy pids)
  → shouldIntercept(): Settings frontmost AND title == "About" AND mouse not top-left
  → SIGKILL (+1 ms) ; presentSystemReport(): selection = Hardware, window ordered front (+16 ms)
  → Apple's window would have composited at ~+763 ms — it never exists
```

Why each piece exists is in `02-bugs-and-fixes.md`; the short version: detection must be
at **exec** (LaunchServices registration is too late), suppression must be **kill** (hide is
unreliable), the window must be **pre-warmed** (first render is slow) and never `.floating`.

## Device Management flow

```
user clicks Device Management
  → System Settings launches ProfilesSettingsExt.appex (separate process)
  → Interceptor sees exec → SIGKILL → presentDeviceManagement()
      (Management group expanded, DM row selected, window sized to cover Settings)
  → DeviceManagementWatcher.sendSettingsToGeneral() (activates: false)
  fallback: AX title of Settings' window becomes "Device Management" → same present
```

Killing the extension matters twice: the pane cannot draw, and because it is dead Settings
must relaunch it on every visit — so the free exec signal fires every time. The extension
sometimes survives; then the title fallback is used and a few frames of Apple's pane can
show. Do **not** reap it while idle (bug #17).

## About This Mac

Apple menu → About This Mac launches the *same* System Information binary
(`About This Mac.app` → `showAboutThisMac`). Launch arguments are identical to System
Report. Intent comes only from context, hence `shouldIntercept`. A non-intercepted
instance is watched: a report-sized window (≥600 pt) opened from the About pane is
intercepted; when its About panel closes, the process is reaped so the next System Report
is a clean exec.

## Permissions

None are required for System Report. Accessibility is used only for the Device Management
title fallback. TCC grants bind to the code signature — that is why the identity is stable.
Screen Recording is never needed by the app.
