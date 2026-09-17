# Agent handbook — start here

You are working on **NativeSystemInfo**, a macOS 26 (Tahoe) LaunchAgent that replaces two
Apple UIs with a native AppKit window: **System Settings → General → About → System Report**
(Apple's System Information.app) and **System Settings → General → Device Management**.

Read in this order:

1. `01-architecture.md` — what runs, where, and why each mechanism exists.
2. `02-bugs-and-fixes.md` — every bug hit so far, its root cause and fix. Most "new" bugs
   are one of these again.
3. `03-verification.md` — how to prove a change works. Never claim a flash is gone from a
   screenshot; use the tools here.
4. `04-tips-and-traps.md` — macOS behaviours that cost hours to discover.
5. `05-extending.md` — how to add panes, change the UI, change interception rules.
6. `06-demo-modes.md` — the Device Management demo/real switch. **Read this before trusting
   what that pane says: it defaults to a scripted unmanaged state.**

Ground rules learned the hard way:

- **Measure, don't assume.** Every wrong turn in this project came from a plausible
  assumption (LaunchServices timing, `isHidden`, `isVisible`, launcher detection). The
  window server (`CGWindowList`) and the process table are the truth; AppKit's view of its
  own state is not.
- **Never kill a System Information launch you are not sure is the System Report button.**
  LaunchServices treats the death as a crash, relaunches ~10×, and then refuses further
  launches. See bug #12.
- **Do not change the Device Management flow** without re-running the 10-visit test in
  `03-verification.md`. It is the most fragile part and the user has signed it off.
- The log is `/tmp/nsi.log`, wall-clock stamped. Read it before theorising.
- `touch /tmp/nsi.pause` disables all interception (to look at Apple's UI); `rm` it after.
