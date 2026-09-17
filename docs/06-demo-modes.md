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

## The two layouts differ structurally

They are not the same tables with different values:

| | Managed | Unmanaged |
| --- | --- | --- |
| Status headline + coloured dot | yes | no |
| This Mac / Management / Configuration Profiles tables | yes | no |
| "Work or School Account" row with Sign In… | no | yes |
| Empty profiles list with +/- footer | no | yes |

`UnmanagedPane` in `Sources/RootView.swift` mirrors Apple's unmanaged pane; the managed
path keeps the table layout. The branch is on `info.managed`, so a genuinely unmanaged Mac
in `real` mode also gets the Apple-style layout, which is correct.

Fidelity notes found by review and worth not regressing:
- The badge glyph is a **fixed white**, not a background-role semantic colour. The tile is
  mid-grey in both appearances, so a colour that inverts paints a near-black badge in dark
  mode.
- The footer strip carries its own `quaternaryLabelColor` overlay (measured 242 vs the card
  body's 251 in light mode) plus a `clipShape`, because `background(_:in:)` does not clip
  descendants and the strip's square corners would otherwise escape the card radius.
- The disabled "−" uses `disabledControlTextColor`, not `secondary`. An explicit
  foreground style suppresses SwiftUI's own disabled attenuation, so the dimmed value has
  to be stated; `secondary` measured ~126 where AppKit's own disabled footer buttons land
  near 199.
- "Sign In…" deliberately does nothing — enrolment is Apple's flow, not this app's.
- Dark mode verified by capture, not inference: badge glyph 255,255,255 on the grey tile,
  card body 34,33,32, footer strip 42,41,40 (still tinted in the right direction), window
  30,29,28.

## The "+" button (demo only)

"+" opens a file picker and appends the chosen file to the list; the selected row can be
removed with "−". **Nothing is installed, enrolled, uploaded or written.** The picker only
reads the file: if a real `.mobileconfig` is chosen its `PayloadDisplayName` and
`PayloadOrganization` are read so the row looks plausible, otherwise the filename is used.
The list lives in the view's `@State` and is gone when the window closes.

This exists so a recording can show a profile appearing in the list. It is not a profile
installer and must not be presented as one.

## Forcing an appearance for capture

`NSI_APPEARANCE=dark` (or `light`) overrides the app's appearance without touching the
system setting:

```bash
env NSI_SHOW_ON_LAUNCH=dm NSI_APPEARANCE=dark \
    ~/Applications/"System Information.app"/Contents/MacOS/NativeSystemInfo &
```

A manually launched instance can land on a different Space; `osascript -e 'tell application
id "com.alatha.NativeSystemInfo" to activate'` brings it over before capturing.

## Panes masked in demo mode

`SPReportStore.demoMaskedTypes` — Software › **Profiles** and Software › **Managed Client**
— read "No information found." while the mode is `unmanaged`, so they agree with the Device
Management pane instead of exposing the real MDM state. In `real` mode they show the machine.

## Things to know

- **The default is a demo state, not the truth.** On an enrolled Mac the pane will say
  "This Mac is not managed" unless `real` is selected. Set `DeviceManagementMode real` on
  any machine being used as a real tool rather than a demo rig.
- Screenshots include the real **serial number**; crop or change it before publishing.
- Only this pane has modes. Every other pane always reports the real machine.
- On a genuinely unmanaged Mac, `real` and `unmanaged` produce nearly the same screen —
  `real` additionally shows the true managed-preference-domain count.
