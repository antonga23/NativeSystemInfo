# Upgrading an installed Mac

For an agent updating a Mac that already has the app installed (for example one set up
from commit `5506913` or earlier).

## Do this first if the Mac is on `5506913` or older

That build has a **main-thread hang**: after viewing any table pane, the next re-render
loops forever, our window stops appearing, and because the app owns the menu bar while
active, the **Apple menu spins system-wide**. Fixed in `630c8f4`. If the Mac is showing
those symptoms, stop the agent before anything else:

```bash
launchctl bootout gui/$(id -u)/com.alatha.nativesysteminfo; pkill -9 -f MacOS/NativeSystemInfo
```

## Upgrade

```bash
cd ~/Developer/NativeSystemInfo
git pull --ff-only origin main
./install.sh
```

`install.sh` is idempotent: it reuses the existing signing identity (so the Accessibility
grant survives — TCC binds to the signature, which is why the identity is stable), rebuilds,
replaces `~/Applications/System Information.app`, rewrites the LaunchAgent for this user's
paths, boots the old agent out and loads the new one.

If `git pull` refuses because of local changes, do not force it — check `git status`, stash
or commit them, then pull.

## Verify

```bash
launchctl print gui/$(id -u)/com.alatha.nativesysteminfo | grep -E "state|pid"
git log --oneline -1
```

Then click through the flows in `03-verification.md`. The minimum:

1. System Settings › General › About › **System Report** → our window, Apple's never visible.
2. Sidebar: open Profiles, then Managed Client, then Fonts, then back to Hardware. The
   Apple menu must stay responsive throughout — this is the exact path that hung.
3. Apple menu › **About This Mac** → Apple's small About panel, not our window.
4. System Settings › General › **Device Management** → our pane.
5. No Dock tile at any point.

## Mode after upgrade

Device Management defaults to the **unmanaged demo** screen and, since this release, also
masks Software › Profiles and Software › Managed Client as "No information found." so the
three panes agree. On a Mac used as a real tool rather than a demo rig:

```bash
defaults write com.alatha.NativeSystemInfo DeviceManagementMode real
launchctl kickstart -k gui/$(id -u)/com.alatha.nativesysteminfo
```

See `06-demo-modes.md`.

## What changed since 5506913

| Commit | Change |
| --- | --- |
| `630c8f4` | Fixed the main-thread hang (unbounded outline-column removal) |
| this | Persistent outline column — the "Name \| Name \| Value" duplicate header; demo mode masks Profiles and Managed Client |

Earlier, but included if the Mac is older than `5506913`: table-over-detail panes driven by
Apple's own `*.spreporter` column declarations, `NSPathControl` breadcrumb, "Logs" and
"Rosetta Software" catalog fixes, no Dock icon, Edit menu (Cmd-A/Cmd-C), the System Report
gate fix for a transient empty window title.

## If something is wrong after upgrading

- Read `/tmp/nsi.log` before theorising.
- `02-bugs-and-fixes.md` lists every failure seen so far with its cause; most new-looking
  bugs are one of those again.
- `touch /tmp/nsi.pause` disables interception so Apple's own UI can be compared; `rm` it
  after.
- Rollback: `git checkout <commit> && ./install.sh`.
