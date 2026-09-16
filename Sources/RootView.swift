import SwiftUI

/// Sidebar selection: either a group row ("Hardware") or a leaf ("USB").
/// Both map to a system_profiler data type, which is how Apple's own sidebar behaves.
struct Selection: Hashable {
    let dataType: String
    let title: String

    static let hardware = Selection(dataType: "SPHardwareDataType", title: "Hardware")

    /// Not a system_profiler type - rendered by DeviceManagementPane.
    static let deviceManagement = Selection(dataType: "NSIDeviceManagement",
                                            title: "Device Management")
}

struct RootView: View {
    @ObservedObject var store: SPReportStore

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle(store.modelName)
    }

    // MARK: - sidebar

    private var sidebar: some View {
        List(selection: $store.selection) {
            ForEach(store.groups) { group in
                DisclosureGroup(isExpanded: binding(for: group.name)) {
                    ForEach(group.items) { item in
                        Text(item.name)
                            .tag(Selection(dataType: item.id, title: item.name))
                    }
                } label: {
                    Text(group.name)
                        .tag(Selection(dataType: group.id, title: group.name))
                }
            }
            DisclosureGroup(isExpanded: binding(for: "Management")) {
                Text(Selection.deviceManagement.title)
                    .tag(Selection.deviceManagement)
            } label: {
                Text("Management")
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .onChange(of: store.selection) { _, new in
            guard let new else { return }
            if new == Selection.deviceManagement {
                store.loadDeviceManagement()
            } else {
                store.request(new.dataType)
            }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { store.expanded.contains(name) },
            set: { isOn in
                if isOn { store.expanded.insert(name) } else { store.expanded.remove(name) }
            }
        )
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                if store.selection == Selection.deviceManagement {
                    DeviceManagementPane(info: store.deviceManagement)
                } else if let selection = store.selection {
                    ReportView(state: store.state(for: selection.dataType))
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .foregroundStyle(.secondary)
            Text(store.serialNumber.isEmpty ? store.modelName : store.serialNumber)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(store.selection?.title ?? "")
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

// MARK: - report rendering

struct ReportView: View {
    let state: SPReportState

    var body: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text("Gathering information…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .empty(let message):
            Text(message)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let nodes):
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(nodes) { node in
                        NodeView(node: node, depth: 0)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct NodeView: View {
    let node: SPNode
    let depth: Int

    var body: some View {
        if node.isSection {
            VStack(alignment: .leading, spacing: 8) {
                Text(node.label + ":")
                    .font(.system(size: 13, weight: .bold))
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(node.children) { child in
                        NodeView(node: child, depth: depth + 1)
                    }
                }
                .padding(.leading, depth == 0 ? 12 : 16)
            }
            .padding(.top, depth == 0 ? 0 : 6)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(node.label + ":")
                    .frame(width: 280, alignment: .trailing)
                Text(node.value ?? "")
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
        }
    }
}

// MARK: - device management

struct DeviceManagementPane: View {
    let info: DeviceManagementInfo?

    var body: some View {
        if let info {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(dotColor(info))
                            .frame(width: 10, height: 10)
                        Text(info.headline)
                            .font(.system(size: 20, weight: .semibold))
                    }

                    DMSection(title: "This Mac", rows: info.thisMac)
                    DMSection(title: "Management", rows: info.management)
                    DMSection(title: "Configuration Profiles", rows: info.profiles)

                    Text("Profile contents and device-scope details require administrator "
                         + "privileges and are not shown.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading management state…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dotColor(_ info: DeviceManagementInfo) -> Color {
        guard info.determined else { return .secondary }
        return info.managed ? .orange : .green
    }
}

struct DMSection: View {
    let title: String
    let rows: [DMRow]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                                .frame(width: 300, alignment: .leading)
                            Text(row.value).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
