# NativeSystemInfo

A native replacement for macOS System Information that appears when you click
**System Settings → General → About → System Report**.

Built and verified on macOS 26.5.2 (Tahoe), `Mac16,1`, Apple silicon.

## Build and run

```bash
./build.sh
open "build/System Information.app"
```

The app is an `LSUIElement` agent: no Dock icon, no menu bar, no window until triggered.
Hold **Option** while clicking System Report to bypass it and get Apple's own UI.

`build.sh` does `rm -rf build`, so the diagnostic helpers live in `tools/` instead:

```bash
swiftc -O flashwatch.swift -o tools/flashwatch && swiftc verify.swift -o tools/verify
```

## How the transition works

Measured on this machine. `probe.swift` established the baseline; `flashwatch.swift`
samples the window list every 2 ms to catch flashes that coarse sampling misses.

Cold launch, wall-clock aligned between the agent log and the sampler:

| Event | Time after clicking System Report |
| --- | --- |
| Target detected at `exec` | ~67 ms |
| `SIGKILL` delivered | ~68 ms |
| Replacement window ordered front | ~82 ms |
| Apple's window *would* have composited | ~763 ms |

Verified across 5 consecutive cold launches: Apple's window never visible, ~1,100 samples
each.

Four mechanisms, each load-bearing:

0. **Detect at `exec`, not via LaunchServices.** `NSWorkspace.runningApplications` only
   reflects LaunchServices registration, which on a *cold* launch lands at ~1072 ms —
   **after** the window is already on screen at ~763 ms. (The earlier ~40 ms figure came
   from relaunching an already-warm app and did not generalise.) `Interceptor` polls
   `proc_listallpids` instead.

   The subtlety: LaunchServices starts an app as `/usr/libexec/xpcproxy`, which then
   `exec`s into the real binary **keeping the same pid**. So the pid is only ever "new"
   while it is still `xpcproxy`; checking its path once, at first sighting, misses the app
   completely and detection silently never fires. Pids seen as `xpcproxy` go into a
   `pending` map and are re-checked every tick until they resolve.

1. **Pre-warm.** The window is built, laid out and drawn at startup, parked off-screen.
   `PrewarmWindow` overrides `constrainFrameRect(_:to:)`; without it AppKit clamps titled
   windows back onto a display and the park silently fails, leaving the window visible at
   the screen edge while the agent is idle.
2. **Terminate, not hide.** `NSRunningApplication.hide()` is not sufficient. Measured with
   a 2 ms retry loop it still let the target hold a window on screen for **457 ms**.
   `isHidden` is also unreliable as an enforcement predicate — it has been observed
   reporting `true` while the target genuinely had a window on screen. The target is
   terminated at detection instead; a dead process cannot render. `CGWindowList` is used
   for any follow-up check, because it is what the user actually sees.
3. **Fast path first.** `present()` orders the window front *before* switching activation
   policy or querying the window list, both of which are slow enough to matter here.
4. **Never `.floating`, and follow the active Space.** Two window-server findings, both
   made with `winprobe.swift` (`kCGWindowIsOnscreen`), both invisible to AppKit:
   - A window whose *first-ever* ordering is at `.floating` level is not placed on screen
     for ~1.2 s. `isVisible` reports `true` the whole time; `onscreen` says `no`. The raised
     level bought nothing (activation already puts us in front) and cost the first present.
   - Ordering the parked window front pins it to whatever Space is active at agent start.
     Presenting later then triggered a Space switch - a ~700 ms desktop slide in which every
     window reports intermediate positions. `.moveToActiveSpace` fixes it; verified with
     `activeSpaceDidChangeNotification` logging: zero changes during present.

   `ensureOnScreen()` remains as a safety net: it polls the window list, not AppKit, and
   re-orders until the window server agrees the window is on screen.

Detection polls every 8 ms. No TCC permission is required for any of this —
`proc_listallpids`, `proc_pidpath`, `kill()` and `CGWindowList` bounds are all ungated.

### The agent must already be resident

The agent cannot intercept a launch that happens before it is running. It is installed as
a LaunchAgent with `RunAtLoad` and `KeepAlive`, so it starts at login and is restarted if
it dies (verified: `kill -9` → new pid within 3 s, `runs = 2`).

## Device Management

Navigating to **System Settings → General → Device Management** presents the replacement's
Device Management pane in front, sized to cover System Settings' window.

System Settings is **not** terminated — unlike System Report, this is a pane inside an app
the user may still want for other panes. That makes coverage load-bearing rather than a
fallback: the replacement frame is unioned with the target's real window bounds so nothing
peeks out at the edges. Verified over three consecutive visits: replacement at
`215,100 1082×853`, System Settings at `261,101 723×851` — fully contained, and stable in
size. (Union against the *default* frame, not the current one; unioning with the current
frame ratchets the window larger on every visit until it fills the screen.)

When the pane is detected: the replacement is presented with Device Management selected
(the sidebar group is expanded first - SwiftUI's `List` drops a selection whose row is not
rendered), and System Settings is navigated back to General **underneath** it with
`NSWorkspace.OpenConfiguration.activates = false`, so closing the replacement never reveals
Apple's pane. General's identifier is `com.apple.systempreferences.GeneralSettings`
(`com.apple.settings.General` is a no-op, `com.apple.preference.general` lands on
Appearance); its window title reads `""`, which is also what resets the in-pane state.

The AX signal is event-driven (`AXObserver` on focused-window and title changes) with a
50 ms poll as fallback. Detection to window-front is ~2 ms.

Two detection signals, because neither is sufficient:

| Signal | Permission | Covers |
| --- | --- | --- |
| `ProfilesSettingsExt.appex` exec | none | first visit per Settings session |
| System Settings' focused-window AX title | Accessibility | every visit |

`ProfilesSettingsExt.appex` genuinely runs as its own process, so its exec is a free
signal. But it is spawned once and then **persists** across navigation — verified: the same
pid after leaving the pane and returning — so on its own it only ever fires the first time.

The Accessibility title covers the rest. The observed titles on this OS version were
confirmed from the log rather than assumed:

```
System Settings focused window title: "Accessibility"
System Settings focused window title: "Wi-Fi"
System Settings focused window title: "Device Management"
device management: entered pane via AX title
```

Window titles via `CGWindowList` (`kCGWindowName`) would have avoided Accessibility, but
that field requires **Screen Recording**, which is the heavier grant — and it returned nil
without it, so it is not a free alternative.

Without the Accessibility grant the app still works; Device Management detection is just
limited to the first visit, and that is logged at startup.

### What the pane reports

Management state is reported exactly as found, with one trap handled explicitly:
`profiles(1)` run unprivileged reports **user scope only**, so it claims "no configuration
profiles" on a machine with many device-scope profiles installed. The pane uses the
device-scope marker file `/var/db/ConfigurationProfiles/Settings/.profilesAreInstalled`
instead, and labels profile contents as requiring administrator privileges rather than
rendering them as "None".

## Full coverage

`Coverage` reads the target's on-screen window bounds from `CGWindowListCopyWindowInfo`
(owner pid, layer, alpha and bounds need no Screen Recording — only window *titles* do),
converts CoreGraphics flipped coordinates to AppKit coordinates, and grows the
replacement to cover the target completely so nothing peeks out at the edges. It covers
the target's **largest** window, not a union: System Settings briefly shows a second window
while changing panes, and unioning with it grew the replacement to full screen width. The
follow-up watch only acts on a target seen at the same place twice, for the same reason.

For System Report this is a fallback, since the target is terminated before it composites.
It becomes the primary mechanism for Device Management, where System Settings stays open
behind the replacement. Other apps the user has open are deliberately not covered —
Apple's System Information does not cover them either.

## UI

The sidebar mirrors Apple's grouping, naming and order: **Hardware** (ATA … USB),
**Network** (Firewall, Locations, Volumes, Wi-Fi), **Software** (Accessibility … Sync
Services). Selecting a group row shows that group's overview, exactly as Apple's does.
The window is titled with the model name and the status bar reads `<serial> › <pane>`.

`SPCatalog.available()` filters the sidebar to the data types this machine actually
reports, so nothing dead-ends.

### Why text output rather than `-json`

`SPReport` parses `system_profiler <type>` text rather than `-json`. The text output
carries the same human labels Apple's UI shows (`Model Name`, `Total Number of Cores`),
whereas the JSON keys are internal identifiers (`machine_name`, `number_processors`).
Matching the native labels is the point. Verify the parse against the source with:

```bash
mkdir -p build/pt && cp parsetest.swift build/pt/main.swift
swiftc Sources/SystemData.swift Sources/SPReport.swift build/pt/main.swift -o build/parsetest
./build/parsetest SPHardwareDataType
diff <(./build/parsetest SPUSBHostDataType) <(system_profiler SPUSBHostDataType)
```

Panes load on demand and are cached. Some (Applications, Fonts) take many seconds —
Apple's own UI spins on those too.

## Code signing

Signed with a **self-signed local identity**, not ad-hoc. This matters: a TCC grant is
bound to the code signature, and an ad-hoc signature changes every build, so an
Accessibility grant would be silently lost on each rebuild. The designated requirement is
pinned to the certificate root:

```
designated => identifier "com.alatha.NativeSystemInfo"
              and certificate root = H"171a115747164bbeb61d04e214bd7f4e58cc41ed"
```

To recreate the identity on another machine:

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout nsi.key -out nsi.crt -config csr.cnf
openssl pkcs12 -export -inkey nsi.key -in nsi.crt -out nsi.p12 \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:nsi -name "NativeSystemInfo Local Signing"
security import nsi.p12 -k ~/Library/Keychains/login.keychain-db -P nsi -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db nsi.crt
```

`csr.cnf` needs `extendedKeyUsage = critical,codeSigning` and
`keyUsage = critical,digitalSignature`. The legacy PKCS#12 algorithms are required —
OpenSSL 3 defaults produce a file macOS rejects with "MAC verification failed". Trust must
be added or `codesign` reports 0 valid identities. Delete `nsi.key` and `nsi.p12`
afterwards; the private key lives in the keychain.

## Run at login — installed

The app runs from `~/Applications/System Information.app`, **not** from `build/`, because
`build.sh` does `rm -rf build` and would delete the binary launchd points at.

Installed state:

```bash
~/Applications/System Information.app
~/Library/LaunchAgents/com.alatha.nativesysteminfo.plist
launchctl print gui/$(id -u)/com.alatha.nativesysteminfo
```

After a rebuild, redeploy and restart the agent:

```bash
./build.sh
rm -rf ~/Applications/"System Information.app"
cp -R "build/System Information.app" ~/Applications/
launchctl kickstart -k gui/$(id -u)/com.alatha.nativesysteminfo
```

To remove completely:

```bash
launchctl bootout gui/$(id -u)/com.alatha.nativesysteminfo
rm ~/Library/LaunchAgents/com.alatha.nativesysteminfo.plist
rm -rf ~/Applications/"System Information.app"
```

## Known gaps

- Interception is keyed on the target's executable path, so it also catches `.spx` files
  and Option-clicking the Apple menu. Hold Option to bypass. A document-aware check was
  considered and deliberately not added — determinism was preferred over the special case.
- Device Management detection falls back to first-visit-only without the Accessibility
  grant. Grant it in Privacy & Security > Accessibility; the stable signature means the
  grant survives rebuilds.
- Cmd-Q closes the window and returns the agent to idle rather than terminating, so the
  pre-warmed window survives. Kill it with `pkill -f MacOS/NativeSystemInfo`.
- `flashwatch`'s "our window on screen" figure is unreliable and sometimes reports
  seconds when the app log and `verify` both show ~16 ms. Its Apple-window metric — the
  one that matters — agrees with every other measurement. Trust `/tmp/nsi.log` and
  `verify` for replacement-window timing.

## Files

| File | Role |
| --- | --- |
| `Sources/main.swift` | Agent lifecycle, menu bar, activation policy |
| `Sources/Interceptor.swift` | Launch detection and suppression |
| `Sources/ReplacementWindow.swift` | Pre-warmed window, presentation, coverage watch |
| `Sources/Coverage.swift` | `CGWindowList` bounds → AppKit frame |
| `Sources/SPReport.swift` | system_profiler parsing, sidebar catalog, report cache |
| `Sources/SystemData.swift` | sysctl / subprocess helpers |
| `Sources/RootView.swift` | SwiftUI sidebar, report and Device Management rendering |
| `Sources/DeviceManagement.swift` | Management and profile state |
| `Sources/DeviceManagementWatcher.swift` | Pane detection (exec + AX title) |
| `Sources/Log.swift` | Timing log at `/tmp/nsi.log` |
| `probe.swift` | Original timing harness |
| `flashwatch.swift` | 2 ms sampler that catches brief flashes |
| `verify.swift` | Prints which windows are actually on screen |
| `pidwatch.swift` | Standalone pid-diff, used to find the xpcproxy exec behaviour |
| `titlewatch.swift` | Checks whether `kCGWindowName` is readable |
| `winprobe.swift` | Window-server view of a pid's windows incl. off-screen (`kCGWindowIsOnscreen`) and display geometry |
| `parsetest.swift` | Dumps the parsed tree for diffing against system_profiler |
