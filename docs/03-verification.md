# Verification

Build the tools once (`build.sh` wipes `build/`, so they live in `tools/`):

```bash
swiftc -O flashwatch.swift -o tools/flashwatch
swiftc verify.swift -o tools/verify
mkdir -p tools/wp && cp winprobe.swift tools/wp/main.swift && swiftc -O tools/wp/main.swift -o tools/winprobe
mkdir -p tools/pw && cp pidwatch.swift tools/pw/main.swift && swiftc -O tools/pw/main.swift -o tools/pidwatch
```

| Tool | Answers |
| --- | --- |
| `tools/verify` | Which relevant windows are on screen right now, front-to-back, with pid and bounds |
| `tools/flashwatch <s>` | Was **Apple's System Information** window visible for even one 2 ms sample? (Does not see the DM pane.) |
| `tools/winprobe <pid>` | Window-server view of a pid's windows incl. `onscreen` flag and display geometry |
| `tools/pidwatch` | Standalone pid diff — proves exec detection independent of the app |
| `/tmp/nsi.log` | The app's own timeline, epoch-stamped |

## System Report (cold, must be clean every time)
```bash
osascript -e 'tell application "System Settings" to activate'   # rule requires Settings frontmost on About
open "x-apple.systempreferences:com.apple.AboutSettings.extension"; sleep 2
for i in 1 2 3; do pkill -x "System Information"; sleep 1.5
  (./tools/flashwatch 3 &); sleep 0.3; open -g -b com.apple.SystemProfiler; sleep 3.2; done
```
Expect `APPLE WINDOW: never visible` ×3 and in the log `decision: System Report` → `SIGKILL` → `present() window ordered front` within ~20 ms.

## Device Management (10 visits)
```bash
open "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings"; sleep 3
for i in $(seq 1 10); do osascript -e 'tell application id "com.alatha.NativeSystemInfo" to quit'; sleep 1
  open -g "x-apple.systempreferences:com.apple.Profiles-Settings.extension"; sleep 2.7; done
sed 's/.*entered pane //' /tmp/nsi.log | grep '^via' | sort | uniq -c
```
Expect 10 presents. `via extension exec` is the flash-free path; `via AX title` visits may show a few frames. Anything below ~50% exec, or fewer than 10 presents, is a regression.

## About This Mac
```bash
open -b com.apple.AboutThisMacLauncher; sleep 3; ./tools/verify
```
Expect Apple's 280×487 panel, **no** `present() begin`, **no** `SIGKILL` in the log. Test with Settings frontmost on General *and* on About (mouse top-left: `tools/mousewarp 60 45`).

## UI parity with Apple
```bash
touch /tmp/nsi.pause; open -a "/System/Applications/Utilities/System Information.app"
# capture with screencapture -l <windowid> (needs Screen Recording for the capturing app)
rm /tmp/nsi.pause
```
Compare text widths between captures: a constant ratio means a font-size mismatch.

## Recordings
The user's screen recordings are the final arbiter. `ffprobe -show_entries frame=pts_time`
finds activity bursts (recordings are VFR); `ffmpeg -ss T -frames:v 24 -vf tile=6x4`
makes contact sheets. Look for the transition *into* a pane, not our window closing.
