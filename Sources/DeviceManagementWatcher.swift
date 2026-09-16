import AppKit
import ApplicationServices

/// Detects when System Settings is showing the Device Management pane.
///
/// Two signals, because neither is sufficient alone:
///
///  * `ProfilesSettingsExt.appex` runs as its own process, so its exec is a free,
///    permission-less signal - but it is spawned once and then **persists** across
///    navigation (verified: same pid after leaving and returning), so it only catches
///    the first visit of a System Settings session.
///  * The Accessibility title of System Settings' focused window tracks the current pane.
///    That covers every subsequent visit, and needs the Accessibility permission.
///
/// Unlike System Report, the target is NOT terminated here. Device Management is a pane
/// inside System Settings, which the user may still want for other panes; the replacement
/// is presented in front and sized to cover it.
final class DeviceManagementWatcher {

    static let settingsBundleID = "com.apple.systempreferences"
    static let profilesExtExecutable =
        "/System/Library/ExtensionKit/Extensions/ProfilesSettingsExt.appex/Contents/MacOS/ProfilesSettingsExt"

    /// Called on the main queue with System Settings' pid when the pane becomes visible.
    var onEnterPane: ((pid_t) -> Void)?

    private let queue = DispatchQueue(label: "dm.watch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastTitle = ""
    private var inPane = false

    // Apple localises the pane title; matched case-insensitively against the current
    // locale's rendering as well as the English name.
    private static let paneTitles: Set<String> = ["device management", "profiles"]

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Called by Interceptor when the extension process execs - the free first-visit signal.
    func noteExtensionLaunched() {
        guard let pid = settingsPID() else { return }
        guard !inPane else { return }
        inPane = true
        Log.mark("device management: extension exec signal")
        DispatchQueue.main.async { [weak self] in self?.onEnterPane?(pid) }
    }

    private func settingsPID() -> pid_t? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == DeviceManagementWatcher.settingsBundleID }?
            .processIdentifier
    }

    private func tick() {
        guard DeviceManagementWatcher.isTrusted else { return }
        guard let pid = settingsPID() else {
            inPane = false
            return
        }

        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else {
            return
        }
        let window = windowRef as! AXUIElement

        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else {
            return
        }

        // Logged on change so the real pane titles can be confirmed on this OS version
        // rather than assumed.
        if title != lastTitle {
            Log.mark("System Settings focused window title: \"\(title)\"")
            lastTitle = title
        }

        let isPane = DeviceManagementWatcher.paneTitles.contains(title.lowercased())
        if isPane && !inPane {
            inPane = true
            Log.mark("device management: entered pane via AX title")
            DispatchQueue.main.async { [weak self] in self?.onEnterPane?(pid) }
        } else if !isPane {
            inPane = false
        }
    }
}
