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
}

/// Reports management state exactly as found. No friendlier version of the truth.
enum DeviceManagement {

    static func collect() -> DeviceManagementInfo {
        var info = DeviceManagementInfo()

        // --- this Mac ---
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let mem = sysctlInt("hw.memsize") ?? 0
        let model = runTool("/usr/sbin/system_profiler", ["SPHardwareDataType"])
        let modelName = SPReport.firstValue("Model Name", in: SPReport.parse(model)) ?? "Mac"
        let serial = SPReport.firstValue("Serial Number (system)", in: SPReport.parse(model)) ?? ""

        var memText = ""
        if mem > 0 {
            let f = ByteCountFormatter()
            f.countStyle = .file
            f.allowedUnits = [.useGB]
            memText = f.string(fromByteCount: mem)
        }
        info.thisMac = [
            DMRow(label: "Model", value: modelName),
            DMRow(label: "Chip", value: chip),
            DMRow(label: "Memory", value: memText.isEmpty ? "Unknown" : memText),
            DMRow(label: "Serial Number", value: serial.isEmpty ? "Unavailable" : serial)
        ]

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
