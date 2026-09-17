import Foundation

struct DMRow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
    var ok: Bool? = nil        // nil = informational, no status dot
}

struct DeviceManagementInfo {
    var managed = false
    var determined = false
    var headline = "Checking…"
    var management: [DMRow] = []
    var profiles: [DMRow] = []
    var thisMac: [DMRow] = []
    /// True when the pane is showing a scripted demo state rather than this machine's.
    var isDemo = false
}

/// Which management state the Device Management pane shows.
///
/// This Mac is MDM-enrolled, so the unmanaged screen cannot be produced from real data
/// here; `demoUnmanaged` renders it from fixed values so both screens can be captured for
/// UI/UX demos. Hardware facts (model, chip, memory, serial) stay real in demo mode -
/// they are not management claims.
enum DMMode: String {
    case demoUnmanaged = "unmanaged"
    case real

    /// Default is the unmanaged demo screen. Override, highest precedence first:
    ///   NSI_DM_MODE=real|managed|unmanaged            (env; `launchctl setenv` for the agent)
    ///   defaults write com.alatha.NativeSystemInfo DeviceManagementMode real
    ///
    /// "managed" is accepted as a spelling of `real`, because on this Mac the real state
    /// is managed - but it selects the machine's actual state, it does not fake one.
    static func current() -> DMMode {
        let raw = (ProcessInfo.processInfo.environment["NSI_DM_MODE"]
                   ?? UserDefaults.standard.string(forKey: "DeviceManagementMode")
                   ?? demoUnmanaged.rawValue).lowercased()
        if raw == "managed" { return .real }
        return DMMode(rawValue: raw) ?? .demoUnmanaged
    }

    var isDemo: Bool { self == .demoUnmanaged }
}

/// Reports management state exactly as found. No friendlier version of the truth.
enum DeviceManagement {

    static func collect() -> DeviceManagementInfo {
        let mode = DMMode.current()
        Log.mark("device management mode: \(mode.rawValue)")
        var info = DeviceManagementInfo()
        info.isDemo = mode.isDemo

        // --- this Mac ---
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let mem = sysctlInt("hw.memsize") ?? 0
        let model = runTool("/usr/sbin/system_profiler", ["SPHardwareDataType"])
        let modelName = SPReport.firstValue("Model Name", in: SPReport.parse(model)) ?? "Mac"
        let serial = SPReport.firstValue("Serial Number (system)", in: SPReport.parse(model)) ?? ""

        // Apple reports binary GB: 17,179,869,184 bytes is "16 GB", not ByteCountFormatter's
        // decimal "17.18 GB" (which the en_ZA locale also rendered as "17,18 GB").
        let memText = mem > 0 ? "\(mem / (1024 * 1024 * 1024)) GB" : ""
        info.thisMac = [
            DMRow(label: "Model", value: modelName),
            DMRow(label: "Chip", value: chip),
            DMRow(label: "Memory", value: memText.isEmpty ? "Unknown" : memText),
            DMRow(label: "Serial Number", value: serial.isEmpty ? "Unavailable" : serial)
        ]

        // Demo screen: fixed values, so the unmanaged layout can be captured on a machine
        // that is in fact enrolled. Everything below this point reads the real state.
        if mode.isDemo {
            info.determined = true
            info.managed = false
            info.headline = "This Mac is not managed"
            info.management = [DMRow(label: "Status", value: "Not managed", ok: true)]
            info.profiles = [
                DMRow(label: "Device Profiles", value: "None"),
                DMRow(label: "User Profiles", value: "None"),
                DMRow(label: "Managed Preference Domains", value: "0")
            ]
            return info
        }

        // --- enrollment ---
        let enrollment = runTool("/usr/bin/profiles", ["status", "-type", "enrollment"])
        var dep = false
        var server = ""
        var enrolledLine = ""
        for line in enrollment.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Enrolled via DEP:") { dep = t.lowercased().contains("yes") }
            if t.hasPrefix("MDM enrollment:") {
                enrolledLine = String(t.dropFirst("MDM enrollment:".count)).trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("MDM server:") {
                server = String(t.dropFirst("MDM server:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        if enrollment.isEmpty {
            info.determined = false
            info.headline = "Management status could not be determined"
            info.management = [DMRow(label: "Status", value: "Unavailable")]
        } else {
            info.determined = true
            info.managed = !enrolledLine.lowercased().hasPrefix("no")
            if info.managed {
                info.headline = "This Mac is managed"
                info.management = [
                    DMRow(label: "Status", value: "Managed", ok: true),
                    DMRow(label: "Enrollment", value: enrolledLine),
                    DMRow(label: "Enrolled via Automated Device Enrollment", value: dep ? "Yes" : "No")
                ]
                if !server.isEmpty {
                    info.management.append(DMRow(label: "Management Server", value: host(server)))
                }
            } else {
                info.headline = "This Mac is not managed"
                info.management = [DMRow(label: "Status", value: "Not managed", ok: true)]
            }
        }

        // --- profiles ---
        // profiles(1) unprivileged reports USER scope only: it says "no configuration
        // profiles" on a machine with many device-scope profiles. The device-scope marker
        // file is the honest signal; contents genuinely require elevation.
        let fm = FileManager.default
        let deviceInstalled = fm.fileExists(atPath: "/var/db/ConfigurationProfiles/Settings/.profilesAreInstalled")
        let userList = runTool("/usr/bin/profiles", ["list", "-type", "configuration"]).lowercased()
        let noUserProfiles = userList.contains("there are no configuration profiles")

        info.profiles = [
            DMRow(label: "Device Profiles",
                  value: deviceInstalled ? "Installed — contents require administrator privileges" : "None"),
            DMRow(label: "User Profiles", value: noUserProfiles ? "None" : "Installed")
        ]

        if let entries = try? fm.contentsOfDirectory(atPath: "/Library/Managed Preferences") {
            let domains = entries.filter { $0.hasSuffix(".plist") }.sorted()
            info.profiles.append(DMRow(label: "Managed Preference Domains", value: "\(domains.count)"))
            for d in domains {
                info.profiles.append(DMRow(label: "    " + d.replacingOccurrences(of: ".plist", with: ""),
                                           value: ""))
            }
        }

        return info
    }

    private static func host(_ s: String) -> String { URL(string: s)?.host ?? s }
}
