import AppKit
import CoreGraphics

// Does System Settings' window title track the selected pane, and is kCGWindowName
// readable? Window names require Screen Recording permission; bounds and pid do not.

for _ in 0..<Int(Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20) {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { break }
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String,
              owner == "System Settings",
              let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let h = b["Height"] as? Double, h > 200 else { continue }
        let name = w[kCGWindowName as String] as? String
        print("  title = \(name.map { "\"\($0)\"" } ?? "<nil - no Screen Recording permission>")")
    }
    usleep(500_000)
}
