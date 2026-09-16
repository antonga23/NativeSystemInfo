import AppKit
import CoreGraphics

// Reports which apps currently have real windows on screen, and where.
// Owner NAME and bounds need no Screen Recording permission (only window titles do).
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

var found: [String] = []
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String,
          let layer = w[kCGWindowLayer as String] as? Int,
          let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.05,
          let b = w[kCGWindowBounds as String] as? [String: Any],
          let x = b["X"] as? Double, let y = b["Y"] as? Double,
          let width = b["Width"] as? Double, let height = b["Height"] as? Double,
          height > 120, width > 120 else { continue }
    guard owner == "System Information" || owner == "NativeSystemInfo" || owner == "System Settings" else { continue }
    let pid = (w[kCGWindowOwnerPID as String] as? pid_t) ?? 0
    found.append(String(format: "  ON SCREEN  %-22@  pid %-6d  layer %-3d  %.0f,%.0f  %.0f×%.0f",
                        owner as NSString, pid, layer, x, y, width, height))
}

print(found.isEmpty ? "  (no matching windows on screen)" : found.joined(separator: "\n"))

let running = NSWorkspace.shared.runningApplications.filter {
    $0.bundleIdentifier == "com.apple.SystemProfiler" || $0.bundleIdentifier == "com.alatha.NativeSystemInfo"
}
for a in running {
    print("  PROCESS    \(a.bundleIdentifier ?? "?")  pid \(a.processIdentifier)  hidden=\(a.isHidden) active=\(a.isActive)")
}
