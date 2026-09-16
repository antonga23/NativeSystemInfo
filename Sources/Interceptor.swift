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

    /// Called on the main queue with the pid of the launching target.
    var onTrigger: ((pid_t) -> Void)?

    /// Called on the main queue when the target managed to put a window back on screen,
    /// so the replacement can re-assert itself in front.
    var onTargetResurfaced: ((pid_t) -> Void)?

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
            if path == Interceptor.targetExecutable {
                pending.removeValue(forKey: pid)
                fire(pid)
            } else if path != Interceptor.proxyPath && !path.isEmpty {
                pending.removeValue(forKey: pid)   // became something else entirely
            }
        }

        for pid in new {
            let path = executablePath(pid)
            if path == Interceptor.targetExecutable {
                fire(pid)
            } else if path == Interceptor.proxyPath || path.isEmpty {
                pending[pid] = now.addingTimeInterval(3)
            }
        }
    }

    private func fire(_ pid: pid_t) {
        // Escape hatch: hold Option while clicking System Report for Apple's own UI.
        // CGEventSource is thread-safe; NSEvent.modifierFlags is main-thread only.
        if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate) { return }

        Log.mark("detected target pid \(pid) at exec")
        DispatchQueue.main.async { [weak self] in self?.onTrigger?(pid) }
        suppress(pid)
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
