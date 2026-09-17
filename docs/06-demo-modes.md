# Demo modes (Device Management)

The Device Management pane can render either this machine's real state or a scripted
unmanaged state, so both screens can be captured for UI/UX demos on a single Mac.

## Why this exists

The development Mac is MDM-enrolled (Microsoft Intune, DEP). The unmanaged screen
therefore cannot be produced from real data on it, but is needed for the website demo.

## Modes

| Mode | Shows | Selected by |
| --- | --- | --- |
| `unmanaged` | Scripted unmanaged screen. **Default.** | nothing, or `NSI_DM_MODE=unmanaged` |
| `real` | This machine's actual management state | `NSI_DM_MODE=real` |
| `managed` | Alias for `real` — it selects the machine's real state, it does **not** fabricate a managed one | `NSI_DM_MODE=managed` |

Precedence: `NSI_DM_MODE` env, then the `DeviceManagementMode` user default, then
`unmanaged`. The active mode is written to `/tmp/nsi.log` on every load:
`device management mode: <mode>`.

Only the management claims are scripted. Hardware rows (Model, Chip, Memory, Serial
Number) stay real in demo mode — they are facts about the machine, not claims about
management. `DeviceManagementInfo.isDemo` is set so the UI can mark the screen if wanted;
nothing currently renders a badge, because a badge would appear in recordings.

## Switching

Persistent (survives agent restarts, what you want for a recording session):

```bash
defaults write com.alatha.NativeSystemInfo DeviceManagementMode real      # or unmanaged
launchctl kickstart -k gui/$(id -u)/com.alatha.nativesysteminfo
```

For the agent via environment instead:

```bash
launchctl setenv NSI_DM_MODE real
launchctl kickstart -k gui/$(id -u)/com.alatha.nativesysteminfo
launchctl unsetenv NSI_DM_MODE          # back to the default
```

Back to default: `defaults delete com.alatha.NativeSystemInfo DeviceManagementMode`.

## Capturing the pane directly

`NSI_SHOW_ON_LAUNCH=dm` opens the window straight onto Device Management, bypassing
System Settings — useful for screenshots and recordings:

```bash
launchctl bootout gui/$(id -u)/com.alatha.nativesysteminfo          # stop the agent first
env NSI_SHOW_ON_LAUNCH=dm NSI_DM_MODE=unmanaged \
    ~/Applications/"System Information.app"/Contents/MacOS/NativeSystemInfo &
# capture, then:
pkill -f MacOS/NativeSystemInfo
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.alatha.nativesysteminfo.plist
```

`NSI_SHOW_ON_LAUNCH=1` (any other value) opens on Hardware.

## Things to know

- **The default is a demo state, not the truth.** On an enrolled Mac the pane will say
  "This Mac is not managed" unless `real` is selected. Set `DeviceManagementMode real` on
  any machine being used as a real tool rather than a demo rig.
- Screenshots include the real **serial number**; crop or change it before publishing.
- Only this pane has modes. Every other pane always reports the real machine.
- On a genuinely unmanaged Mac, `real` and `unmanaged` produce nearly the same screen —
  `real` additionally shows the true managed-preference-domain count.
