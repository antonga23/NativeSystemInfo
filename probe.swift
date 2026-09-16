import AppKit
import CoreGraphics

let bundleID = "com.apple.SystemProfiler"
let appURL = URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app")
let doHide   = CommandLine.arguments.contains("--hide")
let preWarm  = CommandLine.arguments.contains("--prewarm")
let label    = CommandLine.arguments.last ?? "run"

let t0 = CFAbsoluteTimeGetCurrent()
func ms() -> Double { (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
var log: [(String, Double)] = []
let lk = NSLock()
func mark(_ s: String) { lk.lock(); let t = ms(); log.append((s, t)); lk.unlock()
    FileHandle.standardError.write(String(format: "    [%7.1f ms] %@\n", t, s).data(using: .utf8)!) }

// --- clean slate: no existing instance ---
for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == bundleID { a.forceTerminate() }
Thread.sleep(forTimeInterval: 1.5)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// --- our replacement window, pre-rendered OFF-SCREEN when --prewarm ---
let off = NSRect(x: -12000, y: -12000, width: 1000, height: 680)
let real = NSRect(x: 300, y: 200, width: 1000, height: 680)
let w = NSWindow(contentRect: off, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                 backing: .buffered, defer: false)
w.title = "System Information"
let v = NSView(frame: NSRect(origin: .zero, size: real.size))
v.wantsLayer = true
v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
w.contentView = v
if preWarm { w.orderFrontRegardless(); mark("our window pre-rendered off-screen") }

// --- watch for Apple's window actually compositing on screen ---
var appleVisibleAt: Double? = nil
var targetPID: pid_t = 0
let poll = DispatchQueue(label: "poll")
poll.async {
    while CFAbsoluteTimeGetCurrent() - t0 < 8 {
        if targetPID != 0, appleVisibleAt == nil,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for win in list {
                guard let o = win[kCGWindowOwnerPID as String] as? pid_t, o == targetPID,
                      let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                      let a = win[kCGWindowAlpha as String] as? Double, a > 0.05,
                      let b = win[kCGWindowBounds as String] as? [String: Any],
                      let h = b["Height"] as? Double, h > 120 else { continue }
                appleVisibleAt = ms(); break
            }
        }
        usleep(3000)   // 3ms
    }
}

let disco = DispatchQueue(label: "disco")
disco.async {
    while CFAbsoluteTimeGetCurrent() - t0 < 8 {
        if targetPID == 0 {
            for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == bundleID {
                targetPID = a.processIdentifier
                mark("pid discovered by poll (\(a.processIdentifier))")
                if preWarm {
                    DispatchQueue.main.async {
                        w.setFrameOrigin(real.origin); w.level = .floating
                        NSRunningApplication.current.activate(options: [.activateAllWindows])
                        mark("OUR WINDOW ON SCREEN + front")
                    }
                }
                if doHide {
                    DispatchQueue(label: "hider").async {
                        var n = 0
                        while CFAbsoluteTimeGetCurrent() - t0 < 8 {
                            n += 1
                            if a.hide() { mark("hide() SUCCEEDED after \(n) attempts (finishedLaunching=\(a.isFinishedLaunching))"); 
                                // keep enforcing: app may unhide itself when it opens its window
                                for _ in 0..<400 { usleep(5000); if !a.isHidden { _ = a.hide() } }
                                return }
                            usleep(2000)
                        }
                        mark("hide() NEVER succeeded")
                    }
                }
                break
            }
        }
        usleep(2000)
    }
}

let nc = NSWorkspace.shared.notificationCenter
nc.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          a.bundleIdentifier == bundleID else { return }
    mark("willLaunch fired")
}
nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
    guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          a.bundleIdentifier == bundleID else { return }
    targetPID = a.processIdentifier
    mark("didLaunch fired (pid \(a.processIdentifier))")

    if preWarm {                       // just move it on-screen: one window-server op
        w.setFrameOrigin(real.origin)
        w.level = .floating
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        mark("OUR WINDOW ON SCREEN + front")
    }
    if doHide {
        let ok = a.hide()
        mark("hide() called -> \(ok)")
    }
}

mark("requesting launch")
let cfg = NSWorkspace.OpenConfiguration()
cfg.activates = true
NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { ra, err in
    if let e = err { mark("launch ERROR: \(e.localizedDescription)") }
    if let ra = ra {
        mark("launch callback -> pid \(ra.processIdentifier)")
        if targetPID == 0 {
            targetPID = ra.processIdentifier
            mark("pid from callback")
            if preWarm {
                DispatchQueue.main.async {
                    w.setFrameOrigin(real.origin); w.level = .floating
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                    mark("OUR WINDOW ON SCREEN + front")
                }
            }
            if doHide { DispatchQueue.main.async { mark("hide() -> \(ra.hide())") } }
        }
    } else { mark("launch callback -> nil app") }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
    if let a = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
        mark("target alive=true finishedLaunching=\(a.isFinishedLaunching) hidden=\(a.isHidden) active=\(a.isActive)")
    } else { mark("target NOT RUNNING at end (it exited or never started)") }
    mark("--- end ---")
    print("\n===== \(label)  (prewarm=\(preWarm) hide=\(doHide)) =====")
    for (s, t) in log { print(String(format: "  %7.1f ms  %@", t, s)) }
    if let v = appleVisibleAt { print(String(format: "  %7.1f ms  APPLE WINDOW VISIBLE ON SCREEN", v)) }
    else { print("           APPLE WINDOW NEVER APPEARED ON SCREEN") }
    for a in NSWorkspace.shared.runningApplications where a.bundleIdentifier == bundleID { a.forceTerminate() }
    exit(0)
}
app.run()
