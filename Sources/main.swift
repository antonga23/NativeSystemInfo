import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let controller = ReplacementWindowController()
    private let interceptor = Interceptor()
    private let dmWatcher = DeviceManagementWatcher()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar while idle
        buildMenu()

        controller.prewarm()

        interceptor.onTrigger = { [weak controller] pid in
            controller?.present(coveringPID: pid)
        }
        interceptor.onTargetResurfaced = { [weak controller] pid in
            controller?.reassert(coveringPID: pid)
        }
        interceptor.onProfilesExtensionLaunched = { [weak dmWatcher] in
            dmWatcher?.noteExtensionLaunched()
        }
        interceptor.start()

        dmWatcher.onEnterPane = { [weak controller] pid in
            controller?.presentDeviceManagement(coveringPID: pid)
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
        if ProcessInfo.processInfo.environment["NSI_SHOW_ON_LAUNCH"] != nil {
            controller.present(coveringPID: nil)
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
