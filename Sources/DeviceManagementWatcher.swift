import AppKit
import ApplicationServices
import Darwin

/// Detects when System Settings is showing the Device Management pane.
///
/// Two signals, because neither is sufficient alone:
///
///  * `ProfilesSettingsExt.appex` exec (Interceptor kills it there). This is the only
///    signal that arrives BEFORE Apple's pane draws, so it is the only one that gives a
///    genuinely flash-free transition.
///  * The Accessibility title of System Settings' focused window. This changes only once
///    the pane has already drawn, so it is a fallback that costs a few visible frames.
///
/// Measured over 6 visits with a freshly launched System Settings: 4 via exec, 2 via title.
/// The extension usually dies and is relaunched per visit, but occasionally one survives
/// and is then reused, and every visit after that falls back to the title until something
/// clears it. Forcing the issue by reaping the extension while idle was tried and reverted
/// - see the note in tick().
///
/// Unlike System Report, the target is NOT terminated. Device Management is a pane inside
/// System Settings, which the user may still want for other panes; the replacement is
/// presented in front and System Settings is navigated back to General underneath it.
final class DeviceManagementWatcher {

    static let settingsBundleID = "com.apple.systempreferences"
    static let profilesExtExecutable =
        "/System/Library/ExtensionKit/Extensions/ProfilesSettingsExt.appex/Contents/MacOS/ProfilesSettingsExt"

    /// The General pane. Its toolbar carries no title, so the focused window's AX title
    /// reads "" while it is showing - which is also what resets `inPane`.
    private static let generalPaneURL =
        URL(string: "x-apple.systempreferences:com.apple.systempreferences.GeneralSettings")!

    /// Called on the main queue with System Settings' pid when the pane becomes visible.
    var onEnterPane: ((pid_t) -> Void)?

    /// Periodic, while System Settings has a window on screen. Lets the replacement size
    /// itself to cover that window before it is needed.
    var onSettingsVisible: ((pid_t) -> Void)?

    private var lastPrepare = Date.distantPast

    private let queue = DispatchQueue(label: "dm.watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastTitle: String?

    /// Most recently observed focused-window title of System Settings ("About" while the
    /// pane with the System Report button is showing). Read from any queue.
    var currentSettingsTitle: String? {
        queue.sync { lastTitle }
    }
    private var inPane = false

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var observedWindow: AXUIElement?

    // Apple localises the pane title; matched case-insensitively.
    private static let paneTitles: Set<String> = ["device management", "profiles"]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { [weak self] in self?.teardownObserver() }
    }

    // MARK: - signals

    /// Called by Interceptor when the extension process execs - the free first-visit signal.
    func noteExtensionLaunched() {
        queue.async { [weak self] in
            guard let self, let pid = self.settingsPID(), !self.inPane else { return }
            self.fire(pid: pid, reason: "extension exec")
        }
    }

    /// Navigate System Settings to General underneath the replacement, without activating
    /// it. Otherwise closing the replacement reveals Apple's Device Management pane sitting
    /// right there, which is exactly what this app exists to avoid.
    func sendSettingsToGeneral() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.open(DeviceManagementWatcher.generalPaneURL, configuration: cfg) { _, error in
            if let error { Log.mark("navigate settings to General failed: \(error.localizedDescription)") }
            else { Log.mark("settings navigated to General") }
        }
    }

    private func settingsPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == DeviceManagementWatcher.settingsBundleID }?
            .processIdentifier
    }

    // MARK: - polling fallback

    private func tick() {
        guard DeviceManagementWatcher.isTrusted else { return }
        guard let pid = settingsPID() else {
            inPane = false
            if observedPID != 0 { DispatchQueue.main.async { [weak self] in self?.teardownObserver() } }
            return
        }
        if pid != observedPID {
            DispatchQueue.main.async { [weak self] in self?.installObserver(pid: pid) }
        }
        if Date().timeIntervalSince(lastPrepare) > 1 {
            lastPrepare = Date()
            DispatchQueue.main.async { [weak self] in self?.onSettingsVisible?(pid) }
        }
        evaluate(pid: pid, reason: "poll")
    }

    // NOTE: proactively reaping the idle extension was tried and reverted. It does force an
    // exec on every visit, but killing the extension repeatedly trips ExtensionKit's
    // relaunch backoff: System Settings then cannot open the pane at all — clicking Device
    // Management did nothing, with no exec, no title change and no window. Killing it once
    // per visit (in Interceptor) stays within what ExtensionKit tolerates.

    /// Runs on `queue`. Reads the focused window title and fires on entering the pane.
    private func evaluate(pid: pid_t, reason: String) {
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { return }
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return
        }
        let title = (titleRef as? String) ?? ""

        // Logged on change so the real pane titles can be confirmed on this OS version
        // rather than assumed.
        if title != lastTitle {
            Log.mark("System Settings focused window title: \"\(title)\" (\(reason))")
            lastTitle = title
        }

        // NOTE: the sidebar's selected row was tried as an earlier trigger, on the theory
        // that selection changes on click while the title only changes once the pane has
        // drawn. Measured: the selection never updated away from "General" at all, so it
        // carries no signal. Removed rather than left walking the tree every 50 ms.
        let isPane = DeviceManagementWatcher.paneTitles.contains(title.lowercased())
        if isPane && !inPane {
            fire(pid: pid, reason: "AX title (\(reason))")
        } else if !isPane {
            inPane = false
        }
    }

    /// Runs on `queue`.
    private func fire(pid: pid_t, reason: String) {
        // Same escape hatch as System Report: hold Option to get Apple's own pane.
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) {
            Log.mark("device management: Option held, not intercepting")
            return
        }
        inPane = true
        Log.mark("device management: entered pane via \(reason)")
        DispatchQueue.main.async { [weak self] in self?.onEnterPane?(pid) }
    }

    // MARK: - AXObserver (main thread)

    private func installObserver(pid: pid_t) {
        guard pid != observedPID else { return }
        teardownObserver()

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<DeviceManagementWatcher>.fromOpaque(refcon).takeUnretainedValue()
            me.queue.async { [weak me] in
                guard let me, let pid = me.settingsPID() else { return }
                me.evaluate(pid: pid, reason: "AX \(notification as String)")
                // Focus moved to another window: follow it for title changes.
                if (notification as String) == kAXFocusedWindowChangedNotification {
                    DispatchQueue.main.async { me.observeFocusedWindowTitle(pid: pid) }
                }
            }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else {
            Log.mark("AXObserverCreate failed for System Settings pid \(pid)")
            return
        }

        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification,
                     kAXWindowCreatedNotification,
                     kAXTitleChangedNotification] {
            AXObserverAddNotification(obs, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        observer = obs
        observedPID = pid
        observeFocusedWindowTitle(pid: pid)
        Log.mark("AXObserver installed for System Settings pid \(pid)")
    }

    /// Title-changed is delivered reliably only when registered on the window element
    /// itself, so it is (re)attached to whichever window currently has focus.
    private func observeFocusedWindowTitle(pid: pid_t) {
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = observedWindow {
            AXObserverRemoveNotification(obs, old, kAXTitleChangedNotification as CFString)
        }
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else { observedWindow = nil; return }
        let window = windowRef as! AXUIElement
        AXObserverAddNotification(obs, window, kAXTitleChangedNotification as CFString, refcon)
        observedWindow = window
    }

    private func teardownObserver() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedWindow = nil
        observedPID = 0
    }
}
