import SwiftUI

/// Sidebar selection: either a group row ("Hardware") or a leaf ("USB").
/// Both map to a system_profiler data type, which is how Apple's own sidebar behaves.
struct Selection: Hashable {
    let dataType: String
    let title: String
}

struct RootView: View {
    @ObservedObject var store: SPReportStore
    // Set here rather than in .onAppear: onAppear does not fire while the window is parked
    // off-screen, which left the detail pane empty until first present and forced a full
    // SwiftUI render at exactly the moment that needs to be instant.
    @State private var selection: Selection? = Selection(dataType: "SPHardwareDataType",
                                                         title: "Hardware")
    @State private var expanded: Set<String> = ["Hardware"]

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
        List(selection: $selection) {
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
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .onChange(of: selection) { _, new in
            if let new { store.request(new.dataType) }
        }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(name) },
            set: { isOn in
                if isOn { expanded.insert(name) } else { expanded.remove(name) }
            }
        )
    }

    // MARK: - detail

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            Group {
                if let selection {
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
            Text(selection?.title ?? "")
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
