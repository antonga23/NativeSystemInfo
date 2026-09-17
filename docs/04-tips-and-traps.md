# Tips and traps

## macOS behaviours discovered here
- **LaunchServices launches via `xpcproxy` which execs in place.** A pid's path changes ~17 ms after it appears. Any exec-based detection must re-check young pids.
- **`proc_listallpids(nil, 0)` returns 0**, not the required size.
- **Killing an app during launch = crash to LaunchServices.** It relaunches ~10× and then refuses to launch the app until logout or a few minutes pass.
- **ExtensionKit backs off relaunching an extension you keep killing.** Once per visit is tolerated; reaping while idle breaks the pane entirely.
- **A window first ordered at `.floating` level is not on screen for ~1.2 s** even though `isVisible` is true. `kCGWindowIsOnscreen` tells the truth.
- **Ordering a window front pins it to the current Space.** Use `.moveToActiveSpace` for anything pre-warmed.
- **`NSRunningApplication.hide()` / `isHidden` are unreliable during launch.**
- **`runningApplications` lags exec by ~1 s on cold launch.**
- **AppKit constrains titled windows onto a display** — override `constrainFrameRect` to park off-screen.
- **A window with a `contentViewController` sizes itself to the view's fitting size.**
- **`CGWindowList` owner pid, layer, alpha, bounds need no permission; window *titles* need Screen Recording.**
- **TCC attributes a Terminal-spawned binary to Terminal.** Test permissions via launchd.
- **System Settings pane URLs:** General = `com.apple.systempreferences.GeneralSettings` (title `""`), About = `com.apple.AboutSettings.extension` (title `About`), Device Management = `com.apple.Profiles-Settings.extension`. `com.apple.settings.General` is a no-op; `com.apple.preference.general` lands on Appearance. `open -g` navigates without activating.
- **About This Mac** = `/System/Library/CoreServices/Applications/About This Mac.app` (`com.apple.AboutThisMacLauncher`) → `showAboutThisMac` on `com.apple.systemprofiler`. Same binary, identical args, ppid 1; the About panel is 280×487, the report window 910×602. The real Apple menu does **not** always go through the launcher process.
- **System Information's UI is the `system_profiler` text output** with Apple's labels; `-json` has internal keys. Whole UI is 11 pt.

## Build / signing
- Command Line Tools only; `swiftc` directly, ~90 s per build.
- Self-signed identity needs `extendedKeyUsage = codeSigning`, legacy PKCS#12 (`-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1`) or macOS rejects the import, and `security add-trusted-cert` or `codesign` reports 0 identities.
- `build.sh` does `rm -rf build` — never store anything there.

## Working habits
- Sample at 2 ms, not 200 ms, when the question is "did it flash".
- Align the app log and the sampler on epoch ms before drawing conclusions.
- When a fix "works", re-run with a **fresh** System Settings — ExtensionKit state carries over.
- Drive the agent through launchd, not from Terminal.
