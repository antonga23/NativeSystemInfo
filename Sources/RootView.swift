import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
            // An unmanaged Mac does not get the managed tables with empty values: Apple's
            // pane is a different layout entirely - an account row and an (empty) profiles
            // list with add/remove controls. Matching that structure, not just the values.
            if info.determined && !info.managed {
                UnmanagedPane()
            } else {
                managedBody(info)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading management state…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func managedBody(_ info: DeviceManagementInfo) -> some View {
        Group {
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

                    // Only meaningful when there is something withheld: on an unmanaged Mac
                    // there are no profiles to require privileges for.
                    if info.managed {
                        Text("Profile contents and device-scope details require administrator "
                             + "privileges and are not shown.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func dotColor(_ info: DeviceManagementInfo) -> Color {
        guard info.determined else { return .secondary }
        return info.managed ? .orange : .green
    }
}

/// A profile the demo is pretending was added. Nothing is installed: picking a file only
/// reads its display name so the list has something plausible to show.
struct DemoProfile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let detail: String
}

/// Mirrors Apple's Device Management pane on an unmanaged Mac: an account row, then a
/// profiles list with an add/remove footer. No hardware table — Apple does not show one
/// here, and there is no management state to report.
struct UnmanagedPane: View {
    private let corner: CGFloat = 10
    private var card: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.18) }

    @State private var profiles: [DemoProfile] = []
    @State private var selection: DemoProfile.ID?

    var body: some View {
        VStack(spacing: 14) {
            accountRow
            profilesList
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountRow: some View {
        HStack(spacing: 11) {
            Image(systemName: "person.text.rectangle.fill")
                .resizable().scaledToFit()
                .frame(width: 19, height: 19)
                // Fixed white, not a background-role semantic colour: the tile stays
                // mid-grey in both appearances (systemGray 0.557 light / 0.596 dark), so a
                // colour that inverts paints a near-black badge in dark mode.
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color(nsColor: .systemGray),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Work or School Account")
                .font(.system(size: 13))
            Spacer(minLength: 12)
            // Non-functional: enrolment is Apple's flow, not something this app performs.
            Button("Sign In…") {}
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private var profilesList: some View {
        VStack(spacing: 0) {
            if profiles.isEmpty {
                Spacer(minLength: 0)
                Text("No profiles installed")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(profiles) { profile in
                            profileRow(profile)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 0) {
                footerButton("plus", enabled: true) { addProfile() }
                Divider().frame(height: 14)
                footerButton("minus", enabled: selection != nil) { removeSelected() }
                Spacer()
            }
            .frame(height: 26)
            // The native footer strip is tinted slightly against the card body. Quaternary
            // label is black-alpha in light and white-alpha in dark, so this darkens and
            // lightens in the right direction automatically.
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        // background(_:in:) clips only its own fill, so without this the strip's square
        // corners escape the card's radius at the bottom edge.
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private func profileRow(_ profile: DemoProfile) -> some View {
        let isSelected = selection == profile.id
        return HStack(spacing: 9) {
            Image(systemName: "gearshape.fill")
                .resizable().scaledToFit()
                .frame(width: 15, height: 15)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 13))
                Text(profile.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = profile.id }
    }

    /// Demo only. Opens a picker and reads the chosen file's display name so the list has
    /// something plausible to show. Nothing is installed, enrolled, uploaded or written -
    /// the "profiles" live in this view's state and vanish when the window closes.
    private func addProfile() {
        let panel = NSOpenPanel()
        panel.title = "Add Configuration Profile"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "mobileconfig") ?? .data, .data]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Read the display name out of a real .mobileconfig if that is what was picked.
        var name = url.deletingPathExtension().lastPathComponent
        var detail = "1 setting"
        if let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            if let display = plist["PayloadDisplayName"] as? String, !display.isEmpty { name = display }
            if let org = plist["PayloadOrganization"] as? String, !org.isEmpty { detail = org }
            else if let content = plist["PayloadContent"] as? [Any] {
                detail = content.count == 1 ? "1 setting" : "\(content.count) settings"
            }
        }

        let profile = DemoProfile(name: name, detail: detail)
        profiles.append(profile)
        selection = profile.id
    }

    private func removeSelected() {
        guard let id = selection else { return }
        profiles.removeAll { $0.id == id }
        selection = nil
    }

    private func footerButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .regular))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        // secondaryLabel is far too dark for a disabled control (measured 126 on this card
        // where AppKit's own disabled footer buttons land near 199); disabledControlText is
        // the matching role. An explicit style also suppresses SwiftUI's own attenuation,
        // so the disabled value has to be stated rather than inherited.
        .foregroundStyle(enabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
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
