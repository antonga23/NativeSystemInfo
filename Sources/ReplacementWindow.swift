import AppKit
import SwiftUI
import Combine

/// AppKit constrains titled windows back onto a display, which silently defeats parking the
/// pre-warmed window off-screen. Opting out keeps it composited but genuinely invisible.
final class PrewarmWindow: NSWindow {
    var allowOffscreen = true
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowOffscreen ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}

/// Owns the replacement window. The window is built and composited off-screen at launch,
/// so presenting it is a single window-server move rather than a construction - that is
/// what removes the race with Apple's app.
final class ReplacementWindowController: NSObject, NSWindowDelegate {

    private let store = SPReportStore()
    private var titleObserver: AnyCancellable?
    private let offscreen = NSPoint(x: -14_000, y: -14_000)
    private let defaultSize = NSSize(width: 1080, height: 720)

    private var window: PrewarmWindow!
    private var presented = false
    private var coverageTimer: Timer?

    // MARK: - lifecycle

    func prewarm() {
        let w = PrewarmWindow(contentRect: NSRect(origin: .zero, size: defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        w.title = "System Information"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 840, height: 560)
        w.titlebarSeparatorStyle = .automatic
        w.delegate = self
        w.contentView = NSHostingView(rootView: RootView(store: store))
        w.setFrameOrigin(offscreen)
        w.orderFrontRegardless()          // composited, just not where anyone can see it

        // Force SwiftUI to lay out and draw now. Ordering the window front is not enough on
        // its own - without this the first real render happened at present() time and the
        // window took ~1.8 s to appear on first use.
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()

        window = w

        // Apple titles the window with the model name ("MacBook Pro"), which is only known
        // once the hardware report has been read.
        titleObserver = store.$modelName.receive(on: DispatchQueue.main).sink { [weak w] name in
            w?.title = name
        }
    }

    // MARK: - presentation

    /// Bring the replacement forward. When `coveringPID` currently has a window on screen,
    /// the replacement is grown to cover it completely so nothing peeks out at the edges.
    func present(coveringPID pid: pid_t?) {
        guard !presented else {
            // Already open: raise and take focus, otherwise a second System Report click
            // leaves the window buried behind whatever the user was looking at.
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.presented else { return }
                self.window.level = .normal
            }
            return
        }
        presented = true
        Log.mark("present() begin")

        // Getting pixels on screen comes first. Everything that is merely tidy - activation
        // policy, Dock icon, coverage checks - happens after, because setActivationPolicy
        // and the window-list query are slow enough to matter on this path.
        window.allowOffscreen = false        // normal constraining while it is a real window
        window.setFrameOrigin(centeredFrame().origin)
        window.level = .floating             // stay above the target while it is dealt with
        window.makeKeyAndOrderFront(nil)
        Log.mark("present() window ordered front")

        NSApp.activate(ignoringOtherApps: true)
        Log.mark("present() activated")

        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.regular)   // Dock icon + menu bar only while visible
            Log.mark("present() activation policy regular")
            self?.startCoverageWatch(pid: pid)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.window.level = .normal
        }
    }

    /// The target got a window back on screen after being hidden. Re-assert: cover it and
    /// come back to the front. Without this the user ends up looking at Apple's window
    /// sitting on top of the replacement.
    func reassert(coveringPID pid: pid_t) {
        guard presented else { return }
        if let target = Coverage.onScreenFrame(pid: pid), !window.frame.contains(target) {
            window.setFrame(Coverage.frameCovering(target, preferred: window.frame), display: true)
        }
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.presented else { return }
            self.window.level = .normal
        }
    }

    /// The suppression should mean the target never composites. If it slips through anyway,
    /// grow to cover it rather than leaving a visible sliver.
    private func startCoverageWatch(pid: pid_t?) {
        coverageTimer?.invalidate()
        guard let pid else { return }
        let deadline = Date().addingTimeInterval(3)
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, Date() < deadline else { t.invalidate(); return }
            guard let target = Coverage.onScreenFrame(pid: pid) else { return }
            guard !self.window.frame.contains(target) else { return }
            self.window.setFrame(Coverage.frameCovering(target, preferred: self.window.frame),
                                 display: true)
        }
    }

    private func centeredFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: defaultSize)
        }
        let size = NSSize(width: min(defaultSize.width, visible.width),
                          height: min(defaultSize.height, visible.height))
        return NSRect(x: visible.midX - size.width / 2,
                      y: visible.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    // MARK: - back to idle

    /// Closing returns the app to its invisible state with the window re-warmed, ready for
    /// the next interception.
    func windowWillClose(_ notification: Notification) {
        presented = false
        coverageTimer?.invalidate()
        coverageTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
            self.window.level = .normal
            self.window.allowOffscreen = true
            self.window.setFrameOrigin(self.offscreen)
            self.window.orderFrontRegardless()
        }
    }

    /// Cmd-Q closes the window instead of terminating, so the agent stays resident and
    /// pre-warmed. Without this the next System Report click would pay the cold-start cost.
    func closeForQuit() {
        if presented { window.performClose(nil) }
    }
}
