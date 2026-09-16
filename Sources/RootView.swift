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
