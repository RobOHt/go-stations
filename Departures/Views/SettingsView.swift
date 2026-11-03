import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let network = RailNetwork.shared

    var body: some View {
        NavigationStack {
            Form {
                stationsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var stationsSection: some View {
        Section {
            NavigationLink {
                StationPicker(title: "Home station", selection: settings.homeCode, color: RoleColor.home) { settings.setHome($0) }
            } label: {
                LabeledContent {
                    Text(name(for: settings.homeCode))
                } label: {
                    Label {
                        Text("Home")
                    } icon: {
                        Image(systemName: "house.fill").foregroundStyle(RoleColor.home)
                    }
                }
            }
            NavigationLink {
                StationPicker(title: "Work station", selection: settings.workCode, color: RoleColor.work) { settings.setWork($0) }
            } label: {
                LabeledContent {
                    Text(name(for: settings.workCode))
                } label: {
                    Label {
                        Text("Work")
                    } icon: {
                        Image(systemName: "briefcase.fill").foregroundStyle(RoleColor.work)
                    }
                }
            }
        } header: {
            Text("Your stations")
        } footer: {
            Text("When you open the app it shows the board for the station you're at, or whichever of these is closer to you. Synced with iCloud.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Network data", value: network.feedVersion.isEmpty ? "Bundled" : String(network.feedVersion.prefix(8)))
            LabeledContent("Stations", value: "\(network.stations.count)")
        } header: {
            Text("About")
        } footer: {
            Text("Contains information licensed under the Open Government Licence – Ontario (Metrolinx). Not affiliated with or endorsed by Metrolinx or GO Transit. Live data comes from Metrolinx Open Data through the GO Stations server. Free, open source, no ads, no tracking.")
        }
    }

    // MARK: Helpers

    private func name(for code: String?) -> String {
        guard let code else { return "Not set" }
        return network.station(code)?.name ?? code
    }
}

struct StationPicker: View {
    let title: String
    let selection: String?
    /// Blue for home, brown for work.
    var color: Color = .accentColor
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let network = RailNetwork.shared

    private var filtered: [Station] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return network.stations }
        return network.stations.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.code.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        List {
            if selection != nil, query.isEmpty {
                Button(role: .destructive) {
                    onPick(nil)
                    dismiss()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
            }
            ForEach(filtered) { station in
                Button {
                    onPick(station.code)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Text(station.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: 3) {
                            ForEach(station.lineCodes, id: \.self) { LineBadge(code: $0) }
                        }
                        if station.code == selection {
                            Image(systemName: "checkmark")
                                .fontWeight(.semibold)
                                .foregroundStyle(color)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station")
    }
}
