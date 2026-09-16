import AppKit
import CoreGraphics

/// Reads another process's on-screen window geometry so the replacement window can be
/// guaranteed to fully cover it.
///
/// `CGWindowListCopyWindowInfo` returns owner pid, layer, alpha and bounds **without**
/// Screen Recording permission - only window *titles* are gated. So this needs no TCC grant.
enum Coverage {

    /// The target process's largest real, visible window, in AppKit screen coordinates.
    /// Returns nil when the process currently has nothing on screen.
    ///
    /// Largest, not a union: System Settings briefly shows a second window while it
    /// navigates panes, and unioning with it grew the replacement to full screen width.
    static func onScreenFrame(pid: pid_t) -> NSRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var largest: NSRect?
        for win in list {
            guard let owner = win[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let bounds = win[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double,
                  let y = bounds["Y"] as? Double,
                  let w = bounds["Width"] as? Double,
                  let h = bounds["Height"] as? Double,
                  h > 120, w > 120
            else { continue }

            let rect = flip(CGRect(x: x, y: y, width: w, height: h))
            if let current = largest, current.width * current.height >= rect.width * rect.height {
                continue
            }
            largest = rect
        }
        return largest
    }

    /// CoreGraphics global space is flipped (origin top-left of the primary display);
    /// AppKit is bottom-left. Convert using the primary screen's height.
    static func flip(_ cg: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return cg }
        let h = primary.frame.height
        return NSRect(x: cg.origin.x,
                      y: h - cg.origin.y - cg.height,
                      width: cg.width,
                      height: cg.height)
    }

    /// Frame that covers `target` completely while staying on a sensible screen, never
    /// smaller than `preferred`. One pixel of bleed on each edge avoids a hairline seam
    /// from fractional scaling.
    static func frameCovering(_ target: NSRect, preferred: NSRect) -> NSRect {
        var frame = preferred.union(target).insetBy(dx: -1, dy: -1)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            // Grow to cover, but never push the titlebar off the usable area.
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.minX < visible.minX { frame.origin.x = visible.minX }
        }
        return frame
    }
}
