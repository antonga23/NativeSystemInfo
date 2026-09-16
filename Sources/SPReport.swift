import Foundation

/// One node of a system_profiler report: either a labelled value or a section with children.
final class SPNode: Identifiable {
    let id = UUID()
    let label: String
    let value: String?
    var children: [SPNode] = []

    init(label: String, value: String?) {
        self.label = label
        self.value = value
    }

    var isSection: Bool { value == nil }
}

enum SPReportState {
    case idle
    case loading
    case loaded([SPNode])
    case empty(String)
}

/// Runs `system_profiler <type>` and parses its indented text output.
///
/// The text output is used rather than `-json` deliberately: it carries the same human
/// labels Apple's own UI shows ("Model Name", "Total Number of Cores"), whereas the JSON
/// keys are internal identifiers (`machine_name`, `number_processors`). Matching the
/// native labels is the point here.
enum SPReport {

    static func load(dataType: String) -> [SPNode] {
        let text = runTool("/usr/sbin/system_profiler", ["-detailLevel", "full", dataType])
        return parse(text)
    }

    static func parse(_ text: String) -> [SPNode] {
        var roots: [SPNode] = []
        // stack of (indent, node); node == nil means "append to roots"
        var stack: [(indent: Int, node: SPNode)] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let indent = rawLine.prefix(while: { $0 == " " }).count

            // Drop the top-level type banner ("Hardware:", "USB:") - the sidebar already
            // names it, exactly as Apple's UI does.
            if indent == 0 { continue }

            var label = trimmed
            var value: String?
            if let range = trimmed.range(of: ": ") {
                label = String(trimmed[trimmed.startIndex..<range.lowerBound])
                value = String(trimmed[range.upperBound...])
            } else if trimmed.hasSuffix(":") {
                label = String(trimmed.dropLast())
            }

            let node = SPNode(label: label, value: value)

            while let top = stack.last, top.indent >= indent { stack.removeLast() }

            if let parent = stack.last {
                parent.node.children.append(node)
            } else {
                roots.append(node)
            }

            if node.isSection { stack.append((indent, node)) }
        }
        return roots
    }

    /// Flat label/value lookup across a parsed report, for headline values.
    static func firstValue(_ label: String, in nodes: [SPNode]) -> String? {
        for node in nodes {
            if node.label == label, let v = node.value { return v }
            if let found = firstValue(label, in: node.children) { return found }
        }
        return nil
    }
}

// MARK: - catalog

struct SPItem: Identifiable, Hashable {
    let id: String       // system_profiler data type
    let name: String     // Apple's display name
}

struct SPGroup: Identifiable, Hashable {
    let id: String       // data type shown when the group row itself is selected
    let name: String
    var items: [SPItem]
}

enum SPCatalog {

    /// Mirrors the grouping, naming and order of Apple's System Information sidebar.
    static let all: [SPGroup] = [
        SPGroup(id: "SPHardwareDataType", name: "Hardware", items: [
            SPItem(id: "SPParallelATADataType",   name: "ATA"),
            SPItem(id: "SPSecureElementDataType", name: "Apple Pay"),
            SPItem(id: "SPAudioDataType",         name: "Audio"),
            SPItem(id: "SPBluetoothDataType",     name: "Bluetooth"),
            SPItem(id: "SPCameraDataType",        name: "Camera"),
            SPItem(id: "SPCardReaderDataType",    name: "Card Reader"),
            SPItem(id: "SPiBridgeDataType",       name: "Controller"),
            SPItem(id: "SPDiagnosticsDataType",   name: "Diagnostics"),
            SPItem(id: "SPDiscBurningDataType",   name: "Disc Burning"),
            SPItem(id: "SPEthernetDataType",      name: "Ethernet"),
            SPItem(id: "SPFibreChannelDataType",  name: "Fibre Channel"),
            SPItem(id: "SPDisplaysDataType",      name: "Graphics/Displays"),
            SPItem(id: "SPMemoryDataType",        name: "Memory"),
            SPItem(id: "SPNVMeDataType",          name: "NVMExpress"),
            SPItem(id: "SPPCIDataType",           name: "PCI"),
            SPItem(id: "SPParallelSCSIDataType",  name: "Parallel SCSI"),
            SPItem(id: "SPPowerDataType",         name: "Power"),
            SPItem(id: "SPPrintersDataType",      name: "Printers"),
            SPItem(id: "SPSASDataType",           name: "SAS"),
            SPItem(id: "SPSerialATADataType",     name: "SATA"),
            SPItem(id: "SPSPIDataType",           name: "SPI"),
            SPItem(id: "SPStorageDataType",       name: "Storage"),
            SPItem(id: "SPThunderboltDataType",   name: "Thunderbolt/USB4"),
            SPItem(id: "SPUSBHostDataType",       name: "USB")
        ]),
        SPGroup(id: "SPNetworkDataType", name: "Network", items: [
            SPItem(id: "SPFirewallDataType",       name: "Firewall"),
            SPItem(id: "SPNetworkLocationDataType", name: "Locations"),
            SPItem(id: "SPNetworkVolumeDataType",  name: "Volumes"),
            SPItem(id: "SPAirPortDataType",        name: "Wi-Fi")
        ]),
        SPGroup(id: "SPSoftwareDataType", name: "Software", items: [
            SPItem(id: "SPUniversalAccessDataType", name: "Accessibility"),
            SPItem(id: "SPApplicationsDataType",    name: "Applications"),
            SPItem(id: "SPDeveloperToolsDataType",  name: "Developer"),
            SPItem(id: "SPDisabledSoftwareDataType", name: "Disabled Software"),
            SPItem(id: "SPExtensionsDataType",      name: "Extensions"),
            SPItem(id: "SPFontsDataType",           name: "Fonts"),
            SPItem(id: "SPFrameworksDataType",      name: "Frameworks"),
            SPItem(id: "SPInstallHistoryDataType",  name: "Installations"),
            SPItem(id: "SPInternationalDataType",   name: "Language & Region"),
            SPItem(id: "SPLegacySoftwareDataType",  name: "Legacy Software"),
            SPItem(id: "SPLogsDataType",            name: "Log Reports"),
            SPItem(id: "SPManagedClientDataType",   name: "Managed Client"),
            SPItem(id: "SPPrefPaneDataType",        name: "Preference Panes"),
            SPItem(id: "SPPrintersSoftwareDataType", name: "Printer Software"),
            SPItem(id: "SPConfigurationProfileDataType", name: "Profiles"),
            SPItem(id: "SPRawCameraDataType",       name: "Raw Support"),
            SPItem(id: "SPSmartCardsDataType",      name: "SmartCards"),
            SPItem(id: "SPStartupItemDataType",     name: "Startup Items"),
            SPItem(id: "SPSyncServicesDataType",    name: "Sync Services")
        ])
    ]

    /// Only the panes this machine actually reports, so nothing in the sidebar dead-ends.
    static func available() -> [SPGroup] {
        let listed = Set(runTool("/usr/sbin/system_profiler", ["-listDataTypes"])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("SP") })
        guard !listed.isEmpty else { return all }
        return all.compactMap { group in
            var g = group
            g.items = group.items.filter { listed.contains($0.id) }
            return listed.contains(group.id) || !g.items.isEmpty ? g : nil
        }
    }
}

// MARK: - store

/// Loads reports on demand and caches them. Some panes (Applications, Fonts) take many
/// seconds; Apple's own UI spins on those too.
final class SPReportStore: ObservableObject {
    @Published private(set) var states: [String: SPReportState] = [:]
    @Published var groups: [SPGroup] = SPCatalog.all
    @Published var modelName: String = sysctlString("hw.model") ?? "Mac"
    @Published var serialNumber: String = ""

    /// Owned by the store rather than the view so the interceptor can drive it - selecting
    /// Device Management when System Settings navigates there.
    @Published var selection: Selection? = Selection.hardware
    @Published var deviceManagement: DeviceManagementInfo?

    private var inFlight = Set<String>()
    private let queue = DispatchQueue(label: "sp.report", qos: .userInitiated, attributes: .concurrent)

    init() {
        queue.async { [weak self] in
            let groups = SPCatalog.available()
            DispatchQueue.main.async { self?.groups = groups }
        }
        request("SPHardwareDataType")
    }

    func state(for dataType: String) -> SPReportState { states[dataType] ?? .idle }

    func loadDeviceManagement(force: Bool = false) {
        if deviceManagement != nil && !force { return }
        queue.async { [weak self] in
            let info = DeviceManagement.collect()
            DispatchQueue.main.async { self?.deviceManagement = info }
        }
    }

    func request(_ dataType: String) {
        guard states[dataType] == nil, !inFlight.contains(dataType) else { return }
        inFlight.insert(dataType)
        states[dataType] = .loading

        queue.async { [weak self] in
            let nodes = SPReport.load(dataType: dataType)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(dataType)
                self.states[dataType] = nodes.isEmpty
                    ? .empty("No information found.")
                    : .loaded(nodes)

                if dataType == "SPHardwareDataType" {
                    if let name = SPReport.firstValue("Model Name", in: nodes) { self.modelName = name }
                    if let serial = SPReport.firstValue("Serial Number (system)", in: nodes) {
                        self.serialNumber = serial
                    }
                }
            }
        }
    }
}
