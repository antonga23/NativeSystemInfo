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
    private let defaultSize = NSSize(width: 910, height: 602)

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
        w.minSize = NSSize(width: 700, height: 400)
        w.titlebarSeparatorStyle = .automatic
        // Ordering the parked window front pins it to whatever Space is active at agent
        // start. Presenting it later then triggers a Space switch - a ~700 ms desktop slide
        // during which every window reports intermediate positions. Follow the user instead.
        w.collectionBehavior = [.moveToActiveSpace]
        w.delegate = self
        // Title sits to the right of the sidebar, as in Apple's window: a unified toolbar
        // holding only a sidebar tracking separator does exactly that.
        let vc = MainViewController(store: store)
        w.contentViewController = vc
        w.styleMask.insert(.fullSizeContentView)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.setContentSize(defaultSize)
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
            w?.title = name      // hidden, but keeps Mission Control / Dock labels right
        }
    }

    // MARK: - presentation

    /// Bring the replacement forward. When `coveringPID` currently has a window on screen,
    /// the replacement is grown to cover it completely so nothing peeks out at the edges.
    func present(coveringPID pid: pid_t?) {
        guard !presented else {
            // Already open: raise and take focus, otherwise a second System Report click
            // leaves the window buried behind whatever the user was looking at.
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        presented = true
        Log.mark("present() begin")

        // Getting pixels on screen comes first. Everything that is merely tidy - activation
        // policy, Dock icon, coverage checks - happens after, because setActivationPolicy
        // and the window-list query are slow enough to matter on this path.
        // Never `.floating`, even briefly. A window whose first-ever ordering is at floating
        // level is not placed on screen by the window server for ~1.2 s - AppKit reports
        // isVisible == true throughout, CGWindowList says onscreen == no. Activation puts us
        // in front on its own; the raised level bought nothing and cost the first present.
        window.allowOffscreen = false        // normal constraining while it is a real window
        window.setFrameOrigin(pendingCoverageOrigin ?? centeredFrame().origin)
        window.makeKeyAndOrderFront(nil)
        Log.mark("present() window ordered front")

        NSApp.activate(ignoringOtherApps: true)
        Log.mark("present() activated")

        DispatchQueue.main.async { [weak self] in
            NSApp.setActivationPolicy(.regular)   // Dock icon + menu bar only while visible
            Log.mark("present() activation policy regular")
            self?.startCoverageWatch(pid: pid)
            self?.ensureOnScreen()
        }
    }

    /// Size the parked window to cover `pid` ahead of time, while it is still off-screen.
    /// Resizing allocates a new backing surface, which is the expensive half of presenting;
    /// doing it in advance leaves only an origin change on the critical path.
    func prepareCoverage(forPID pid: pid_t) {
        guard !presented, window != nil,
              let target = Coverage.onScreenFrame(pid: pid) else { return }
        let wanted = Coverage.frameCovering(target, preferred: centeredFrame())
        guard window.frame.size != wanted.size else { return }
        window.allowOffscreen = true
        window.setFrame(NSRect(origin: offscreen, size: wanted.size), display: true)
        pendingCoverageOrigin = wanted.origin
        Log.mark("pre-sized parked window to \(Int(wanted.width))x\(Int(wanted.height))")
    }

    private var pendingCoverageOrigin: NSPoint?

    /// System Report always opens on Hardware, whatever was selected last time.
    func presentSystemReport(coveringPID pid: pid_t) {
        store.selection = Selection.hardware
        present(coveringPID: pid)
    }

    /// System Settings navigated to Device Management. Unlike System Report, System Settings
    /// is left running - the user may want other panes - so the replacement must actually
    /// cover its window rather than relying on the target being gone.
    func presentDeviceManagement(coveringPID pid: pid_t) {
        Log.mark("presenting device management")
        store.expanded.insert("Management")      // before selection: a collapsed row can't be selected
        store.selection = Selection.deviceManagement
        store.loadDeviceManagement(force: true)
        Log.mark("sidebar selection -> \(store.selection?.title ?? "nil"), expanded=\(store.expanded.sorted())")

        if !presented { present(coveringPID: pid) }

        // present() only moves the origin, because on the System Report path the target is
        // already dead and speed matters more than size. Here the target is alive and
        // visible, so the frame has to actually cover it.
        // Union against the default frame, not the current one: unioning with the current
        // frame ratchets the window larger on every visit until it fills the screen.
        if let target = Coverage.onScreenFrame(pid: pid) {
            window.setFrame(Coverage.frameCovering(target, preferred: centeredFrame()),
                            display: true)
        }
        reassert(coveringPID: pid)
    }

    /// The target got a window back on screen after being hidden. Re-assert: cover it and
    /// come back to the front. Without this the user ends up looking at Apple's window
    /// sitting on top of the replacement.
    func reassert(coveringPID pid: pid_t) {
        guard presented else { return }
        Log.mark("reassert: frame \(NSStringFromRect(window.frame)) visible=\(window.isVisible) onScreen=\(window.screen != nil)")
        if let target = Coverage.onScreenFrame(pid: pid), !window.frame.contains(target) {
            window.setFrame(Coverage.frameCovering(target, preferred: window.frame), display: true)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var onScreenTimer: Timer?

    /// AppKit's `isVisible` is not the truth - it has reported true while the window server
    /// had no record of the window on screen (observed on the first present after launch,
    /// around the accessory->regular policy switch). Check the window list, which is what
    /// the user actually sees, and re-order until it agrees.
    private func ensureOnScreen() {
        onScreenTimer?.invalidate()
        let deadline = Date().addingTimeInterval(3)
        let me = getpid()
        var attempts = 0
        onScreenTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self, self.presented, Date() < deadline else { t.invalidate(); return }
            if Coverage.onScreenFrame(pid: me) != nil {
                if attempts > 0 { Log.mark("ensureOnScreen: on screen after \(attempts) re-order(s)") }
                t.invalidate()
                return
            }
            attempts += 1
            Log.mark("ensureOnScreen: window server has no on-screen window for us - re-ordering (#\(attempts))")
            self.window.orderFrontRegardless()
        }
    }

    /// The suppression should mean the target never composites. If it slips through anyway,
    /// grow to cover it rather than leaving a visible sliver.
    private func startCoverageWatch(pid: pid_t?) {
        coverageTimer?.invalidate()
        guard let pid else { return }
        let deadline = Date().addingTimeInterval(3)
        var previous: NSRect?
        coverageTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self, Date() < deadline else { t.invalidate(); return }
            guard let target = Coverage.onScreenFrame(pid: pid) else { previous = nil; return }
            // Only act on a target seen at the same place twice. During a pane change or a
            // Space slide the target reports transient positions, and chasing those grew
            // the window to full screen width.
            defer { previous = target }
            guard target == previous, !self.window.frame.contains(target) else { return }
            let grown = Coverage.frameCovering(target, preferred: self.centeredFrame())
            Log.mark("coverage watch: growing \(NSStringFromRect(self.window.frame)) -> \(NSStringFromRect(grown))")
            self.window.setFrame(grown, display: true)
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
        Log.mark("window closing -> idle")
        presented = false
        pendingCoverageOrigin = nil
        coverageTimer?.invalidate()
        coverageTimer = nil
        onScreenTimer?.invalidate()
        onScreenTimer = nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.setActivationPolicy(.accessory)
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
