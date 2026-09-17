import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = ReplacementWindowController()
    private let interceptor = Interceptor()
    private let dmWatcher = DeviceManagementWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar - ever
        buildMenu()

        // Capture/demo aid: force an appearance without changing the user's system setting.
        if let want = ProcessInfo.processInfo.environment["NSI_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: want.lowercased() == "dark" ? .darkAqua : .aqua)
            Log.mark("appearance forced to \(want)")
        }

        controller.prewarm()

        // A Space switch during present means the window is on the wrong desktop.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in Log.mark("ACTIVE SPACE CHANGED") }

        interceptor.onTrigger = { [weak controller] pid in
            controller?.presentSystemReport(coveringPID: pid)
        }
        interceptor.shouldIntercept = { [weak dmWatcher] in
            // The System Report button lives in System Settings' About pane, so all three
            // must hold. Frontmost alone is not enough: the Apple menu belongs to whatever
            // app is frontmost, so About This Mac chosen while Settings is frontmost looked
            // identical - and a wrong kill costs a ~10x LaunchServices relaunch loop.
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    == DeviceManagementWatcher.settingsBundleID else {
                Log.mark("decision: Settings not frontmost -> not System Report"); return false
            }
            guard dmWatcher?.currentSettingsTitle == "About" else {
                Log.mark("decision: Settings pane is \"\(dmWatcher?.currentSettingsTitle ?? "nil")\", not About -> not System Report")
                return false
            }
            // The Apple menu drops down from the top-left corner; the mouse is still there
            // when the launch lands (~150 ms after the click). The System Report button is
            // never in that region.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first {
                let fromTop = screen.frame.maxY - mouse.y
                if mouse.x < 340 && fromTop < 520 {
                    Log.mark("decision: mouse at top-left (\(Int(mouse.x)), \(Int(fromTop)) from top) -> Apple menu, not System Report")
                    return false
                }
            }
            Log.mark("decision: System Report")
            return true
        }
        interceptor.onTargetResurfaced = { [weak controller] pid in
            controller?.reassert(coveringPID: pid)
        }
        interceptor.onProfilesExtensionLaunched = { [weak dmWatcher] in
            dmWatcher?.noteExtensionLaunched()
        }
        interceptor.start()

        dmWatcher.onEnterPane = { [weak controller, weak dmWatcher] pid in
            controller?.presentDeviceManagement(coveringPID: pid)
            // Once covered, move Settings off the pane so closing the replacement does not
            // reveal Apple's Device Management sitting underneath.
            dmWatcher?.sendSettingsToGeneral()
        }
        dmWatcher.onSettingsVisible = { [weak controller] pid in
            controller?.prepareCoverage(forPID: pid)
        }
        dmWatcher.start()

        // Accessibility is only needed for Device Management: the pane's extension process
        // persists across navigation, so its exec only signals the first visit. Everything
        // on the System Report path works without any permission.
        if !DeviceManagementWatcher.isTrusted {
            Log.mark("accessibility not granted - device management limited to first visit")
            if ProcessInfo.processInfo.environment["NSI_NO_AX_PROMPT"] == nil {
                DeviceManagementWatcher.requestTrust()
            }
        } else {
            Log.mark("accessibility granted")
        }

        // Launched by hand rather than by an interception - show the window straight away.
        // NSI_SHOW_ON_LAUNCH=dm opens on Device Management, for recording that pane.
        if let show = ProcessInfo.processInfo.environment["NSI_SHOW_ON_LAUNCH"] {
            if show.lowercased() == "dm" {
                controller.presentDeviceManagement(coveringPID: 0)
            } else if show.hasPrefix("SP") {
                controller.presentPane(dataType: show)   // capture aid, e.g. NSI_SHOW_ON_LAUNCH=SPFontsDataType
            } else {
                controller.present(coveringPID: nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Cmd-Q closes the window and returns to idle rather than killing the agent, so the
    /// pre-warmed window survives for the next System Report click.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.closeForQuit()
        return .terminateCancel
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About System Information", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide System Information",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit System Information",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Never drawn under .accessory, but the key equivalents still fire. Without an Edit
        // menu Cmd-A and Cmd-C are dead on the report text, which is selectable.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
