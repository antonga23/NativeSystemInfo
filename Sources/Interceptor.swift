import AppKit
import Darwin

/// Watches for Apple's System Information launching and suppresses it.
///
/// Detection reads the **process table**, not `NSWorkspace.runningApplications`.
/// Measured on a cold launch (macOS 26.5.2):
///
///     trigger                 +0 ms
///     Apple's window visible  +763 ms
///     listed in runningApplications  +1072 ms   <- too late, by 300 ms
///
/// `runningApplications` only reflects LaunchServices registration, which on a cold launch
/// lands *after* the window is already on screen. The earlier ~40 ms figure came from
/// relaunching an already-warm app and did not generalise. `proc_listallpids` sees the
/// process at exec, which is early enough to act.
///
/// Requires no TCC permission.
final class Interceptor {

    static let targetExecutable =
        "/System/Applications/Utilities/System Information.app/Contents/MacOS/System Information"

    /// Apple menu > About This Mac. This launcher (`com.apple.AboutThisMacLauncher`) tells
    /// `com.apple.systemprofiler` to `showAboutThisMac`, so the About panel is drawn by the
    /// very binary this class intercepts. Without special-casing it, opening About This Mac
    /// triggers the replacement, which is not what that menu item means.
    static let aboutLauncherExecutable =
        "/System/Library/CoreServices/Applications/About This Mac.app/Contents/MacOS/About This Mac"

    /// The About panel is ~280pt wide; the System Report window is ~900pt+. Used to tell
    /// which window a surviving About-mode process has opened.
    static let reportWindowMinWidth: CGFloat = 600

    /// Called on the main queue with the pid of the launching target.
    var onTrigger: ((pid_t) -> Void)?

    /// Decides whether a System Information launch is the System Report button. Called on
    /// the main queue. System Report is clicked with System Settings frontmost on its About
    /// pane; Apple menu > About This Mac is clicked from whatever app owns the menu bar. The
    /// launch itself carries no intent (identical arguments), so this context is the signal.
    var shouldIntercept: (() -> Bool)?

    /// Called on the main queue when the target managed to put a window back on screen,
    /// so the replacement can re-assert itself in front.
    var onTargetResurfaced: ((pid_t) -> Void)?

    /// Called when System Settings' Device Management pane extension execs. Free signal,
    /// but it only fires on the pane's first visit per Settings session - the extension
    /// process persists afterwards. See DeviceManagementWatcher.
    var onProfilesExtensionLaunched: (() -> Void)?

    private let pollQueue = DispatchQueue(label: "interceptor.poll", qos: .userInitiated)
    private let killQueue = DispatchQueue(label: "interceptor.kill", attributes: .concurrent)
    private var timer: DispatchSourceTimer?
    private var known = Set<pid_t>()
    private var primed = false

    /// Pids seen as `xpcproxy` (or with no readable path yet), mapped to the time we stop
    /// re-checking them. LaunchServices starts an app as /usr/libexec/xpcproxy which then
    /// execs into the real binary *keeping the same pid* - so a pid is only "new" while it
    /// is still xpcproxy, and checking its path once misses the app entirely.
    private var pending: [pid_t: Date] = [:]
    private static let proxyPath = "/usr/libexec/xpcproxy"

    /// Set when the About This Mac launcher execs. A System Information launch inside this
    /// window belongs to the Apple menu and is left alone.
    private var aboutGraceUntil = Date.distantPast

    func start() {
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - process table

    // Reused across ticks: this runs every 8 ms on a serial queue, so reallocating a
    // 32 KB buffer each time would be pure churn.
    //
    // Note proc_listallpids(nil, 0) does NOT return a required count - it returns 0, which
    // silently disabled detection entirely when used as a sizing call. Allocate up front.
    private var pidBuffer = [pid_t](repeating: 0, count: 8192)

    private func allPIDs() -> [pid_t] {
        let byteSize = Int32(pidBuffer.count * MemoryLayout<pid_t>.size)
        let count = proc_listallpids(&pidBuffer, byteSize)
        guard count > 0 else { return [] }
        return Array(pidBuffer.prefix(Int(count)))
    }

    // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not exposed to Swift.
    private static let pathMax = 4096

    private func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Interceptor.pathMax)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    private func tick() {
        let current = allPIDs()
        let currentSet = Set(current)

        // First pass only records what is already running. An instance the user opened
        // before the agent started is left alone.
        guard primed else {
            known = currentSet
            primed = true
            Log.mark("interceptor primed with \(currentSet.count) pids")
            return
        }

        let new = currentSet.subtracting(known)
        known = currentSet

        // Re-check pids that were still xpcproxy when first seen; drop the dead and expired.
        let now = Date()
        for (pid, deadline) in pending {
            if !currentSet.contains(pid) || now > deadline { pending.removeValue(forKey: pid); continue }
            let path = executablePath(pid)
            if path == Interceptor.aboutLauncherExecutable {
                pending.removeValue(forKey: pid)
                noteAboutLauncher()
            } else if path == Interceptor.targetExecutable {
                pending.removeValue(forKey: pid)
                fire(pid)
            } else if path == DeviceManagementWatcher.profilesExtExecutable {
                pending.removeValue(forKey: pid)
                profilesExtensionLaunched(pid)
            } else if path != Interceptor.proxyPath && !path.isEmpty {
                pending.removeValue(forKey: pid)   // became something else entirely
            }
        }

        for pid in new {
            let path = executablePath(pid)
            if path == Interceptor.aboutLauncherExecutable {
                noteAboutLauncher()
            } else if path == Interceptor.targetExecutable {
                fire(pid)
            } else if path == DeviceManagementWatcher.profilesExtExecutable {
                profilesExtensionLaunched(pid)
            } else if path == Interceptor.proxyPath || path.isEmpty {
                pending[pid] = now.addingTimeInterval(3)
            }
        }
    }

    /// The Device Management pane is rendered by this extension process. Killing it at exec
    /// does two things: the pane can never draw (the same guarantee System Report has), and
    /// because the extension is then dead, System Settings must relaunch it on every visit -
    /// which turns the otherwise first-visit-only exec signal into one that fires every time.
    /// Verified: Settings relaunches it cleanly and stays on the pane's host window.
    private func profilesExtensionLaunched(_ pid: pid_t) {
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { return }
        let rc = kill(pid, SIGKILL)
        Log.mark("profiles extension exec pid \(pid) - SIGKILL rc \(rc)")
        DispatchQueue.main.async { [weak self] in self?.onProfilesExtensionLaunched?() }
    }

    /// Measured: the launcher execs ~17 ms after its pid appears (it starts as xpcproxy, so
    /// the pending re-check is what catches it), lives ~147 ms, and System Information execs
    /// ~143 ms after the launcher. The grace window comfortably covers that.
    private func noteAboutLauncher() {
        aboutGraceUntil = Date().addingTimeInterval(6)
        Log.mark("About This Mac launcher exec - System Information launches are the Apple menu's")
    }

    private func fire(_ pid: pid_t) {
        // Escape hatch: hold Option while clicking System Report for Apple's own UI.
        // CGEventSource is thread-safe; NSEvent.modifierFlags is main-thread only.
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { return }

        // Killing a launch that turns out to be About This Mac is not a one-off mistake: LS
        // treats the death as a crash and relaunches ~10 times, we re-present on each, and
        // afterwards LS stops honouring launches of the app entirely. Get this right first.
        var intercept = Date() >= aboutGraceUntil
        if intercept, let decide = shouldIntercept {
            DispatchQueue.main.sync { intercept = decide() }
        }
        if !intercept {
            Log.mark("target pid \(pid) not launched from the About pane - leaving it alone")
            watchAboutModeProcess(pid)
            return
        }

        Log.mark("detected target pid \(pid) at exec")
        DispatchQueue.main.async { [weak self] in self?.onTrigger?(pid) }
        suppress(pid)
    }

    /// An About-This-Mac instance is allowed to live, which leaves System Information
    /// running. "System Report" from that flow then opens a *new window in the existing
    /// process* - no exec, so exec detection cannot see it, and Apple's report window ends
    /// up on top of the replacement.
    ///
    /// So: watch this process. If it opens a report-sized window, intercept it. Once its
    /// About panel goes away, kill the process so the invariant "System Information is not
    /// running" is restored and the next System Report click is a clean exec again.
    private func watchAboutModeProcess(_ pid: pid_t) {
        killQueue.async { [weak self] in
            let deadline = Date().addingTimeInterval(300)
            var sawPanel = false
            while Date() < deadline {
                guard self != nil, kill(pid, 0) == 0 else { return }   // process gone

                if let frame = Coverage.onScreenFrame(pid: pid) {
                    sawPanel = true
                    if frame.width >= Interceptor.reportWindowMinWidth {
                        Log.mark("About-mode pid \(pid) opened a report window (\(Int(frame.width))pt) - intercepting")
                        DispatchQueue.main.async { [weak self] in self?.onTrigger?(pid) }
                        self?.suppress(pid)
                        return
                    }
                } else if sawPanel {
                    Log.mark("About This Mac panel closed - terminating pid \(pid) to restore clean interception")
                    kill(pid, SIGKILL)
                    return
                }
                usleep(30_000)
            }
        }
    }

    // MARK: - suppression

    /// Terminating is what makes this deterministic. `hide()` was measured leaving the
    /// target's window on screen for 457 ms even with a 2 ms retry loop, and `isHidden`
    /// has been seen reporting `true` while a window was genuinely visible. A dead process
    /// cannot render.
    private func suppress(_ pid: pid_t) {
        killQueue.async { [weak self] in
            let rc = kill(pid, SIGKILL)
            Log.mark("SIGKILL \(pid) -> rc \(rc)")

            // The user may click again, and LaunchServices may retry the launch. Keep the
            // window off screen for a short period after the trigger.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if Coverage.onScreenFrame(pid: pid) != nil {
                    Log.mark("target \(pid) surfaced a window - killing again")
                    kill(pid, SIGKILL)
                    DispatchQueue.main.async { self?.onTargetResurfaced?(pid) }
                }
                usleep(2_000)
            }
        }
    }
}
