import AppKit
import CoreGraphics

// Window-server-side view of one process's windows, including ones NOT on screen, plus
// display geometry. Used to tell "window exists but is not on screen" apart from
// "window is somewhere unexpected".
//
// usage: winprobe <pid>

let pid = pid_t(CommandLine.arguments.dropFirst().first ?? "0") ?? 0

print("displays (NSScreen, AppKit coords, bottom-left origin):")
for (i, s) in NSScreen.screens.enumerated() {
    print(String(format: "  [%d] frame %@  visible %@  scale %.0fx%@", i,
                 NSStringFromRect(s.frame), NSStringFromRect(s.visibleFrame), s.backingScaleFactor,
                 s == NSScreen.main ? "  (main)" : ""))
}

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}
print("windows for pid \(pid) (CG coords, top-left origin):")
var n = 0
for w in list {
    guard let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double else { continue }
    n += 1
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let alpha = w[kCGWindowAlpha as String] as? Double ?? -1
    let onscreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
    let wid = w[kCGWindowNumber as String] as? Int ?? -1
    print(String(format: "  win %-6d  layer %-3d  alpha %.2f  onscreen %@  %.0f,%.0f  %.0fx%.0f",
                 wid, layer, alpha, onscreen ? "YES" : "no ", x, y, width, height))
}
if n == 0 { print("  (none)") }
