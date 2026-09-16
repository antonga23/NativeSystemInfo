import AppKit
import CoreGraphics

// Continuously samples the window list to catch any moment Apple's System Information
// is visible, however brief. Coarse sampling misses flashes; this polls every 2 ms.
//
// usage: flashwatch <seconds>

let duration = Double(CommandLine.arguments.dropFirst().first ?? "8") ?? 8
let start = CFAbsoluteTimeGetCurrent()
let startEpoch = Date().timeIntervalSince1970 * 1000
func epochAt(_ offsetMs: Double) -> Double { startEpoch + offsetMs }
func ms() -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }

var firstSeen: Double?
var lastSeen: Double?
var samplesVisible = 0
var samplesTotal = 0
var maxRect = ""
var ourFirstSeen: Double?

func targetPIDs() -> Set<pid_t> {
    Set(NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == "com.apple.SystemProfiler" }
        .map { $0.processIdentifier })
}
func ourPIDs() -> Set<pid_t> {
    Set(NSWorkspace.shared.runningApplications
        .filter { $0.bundleIdentifier == "com.alatha.NativeSystemInfo" }
        .map { $0.processIdentifier })
}

var targets = targetPIDs()
var ours = ourPIDs()
var lastRefresh = 0.0

while CFAbsoluteTimeGetCurrent() - start < duration {
    if ms() - lastRefresh > 100 {          // refresh pid sets periodically, not every tick
        targets = targetPIDs()
        ours = ourPIDs()
        lastRefresh = ms()
    }
    samplesTotal += 1

    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                             kCGNullWindowID) as? [[String: Any]] {
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? Double, let y = b["Y"] as? Double,
                  let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                  width > 100, height > 100 else { continue }

            if targets.contains(pid) {
                let t = ms()
                if firstSeen == nil { firstSeen = t }
                lastSeen = t
                samplesVisible += 1
                maxRect = String(format: "%.0f,%.0f %.0fx%.0f", x, y, width, height)
            }
            if ours.contains(pid), x > -5000, ourFirstSeen == nil {
                ourFirstSeen = ms()
            }
        }
    }
    usleep(2_000)
}

print("--- flashwatch (\(samplesTotal) samples over \(Int(duration))s) ---")
if let f = firstSeen, let l = lastSeen {
    print(String(format: "  APPLE WINDOW VISIBLE: first %.0f ms, last %.0f ms, span %.0f ms, %d samples  [%@]",
                 f, l, l - f, samplesVisible, maxRect))
    print(String(format: "     epoch first %.0f  last %.0f", epochAt(f), epochAt(l)))
} else {
    print("  APPLE WINDOW: never visible")
}
if let o = ourFirstSeen {
    print(String(format: "  our window on screen at %.0f ms", o))
} else {
    print("  our window: not seen on screen")
}
